// server/src/admin/auth.js
//
// 管理面板的账号与会话。
//
// 设计要点（和旧版最大的区别）：
//   1. **账号存数据库**，不存 .env。第一次访问时表是空的，页面会让人
//      自己建第一个管理员（admin 组）；之后只能由已有管理员加人。
//      这样「面板口令」不再是一个全服共用的字符串，每个人有自己的身份，
//      封谁、踢谁、谁建的号都说得清楚。
//   2. 登录态是 HMAC 签名 cookie，签名密钥里混了该账号的 password_hash，
//      所以改密码 = 该账号所有旧 cookie 立刻失效（不需要 sessions 表）。
//   3. 登录失败限流，且失败信息统一 —— 不区分「用户名不存在」与「密码错」。
//   4. 第一次建号的接口只在 admin_users 为空时可用，且用 MySQL 命名锁
//      串行化：两个请求同时到达时，只有一个能建成号。

import { Router } from 'express';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { config } from '../config.js';
import { execute, pool, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { burnPasswordTime, hashPassword, verifyPassword } from '../lib/auth.js';
import {
  createAdminSession,
  newAdminSecret,
  parseAdminSession,
  validateAdminPassword,
  validateAdminUsername,
  verifyAdminSession,
} from '../lib/admin_session.js';
import { updateEnvFile } from '../lib/envfile.js';
import { renderAdminPage } from './ui.js';

export const COOKIE_NAME = 'll_admin';
export const ROLE_ADMIN = 'admin';

const ENV_PATH = join(config.root, '.env');
/** 建号串行化用的命名锁：MySQL 的连接级锁，断开自动释放 */
const SETUP_LOCK = 'lemonlite_admin_setup';

// ================================================================ 基础

export function parseCookies(header) {
  const out = new Map();
  for (const part of String(header || '').split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    out.set(part.slice(0, eq).trim(), decodeURIComponent(part.slice(eq + 1).trim()));
  }
  return out;
}

/** 版本号只用于顶栏展示；直接 `node src/server.js` 启动时没有 npm_* 变量，
 *  所以从 package.json 读一次（读失败就显示 dev，不影响任何功能）。 */
let cachedVersion = null;
export function panelVersion() {
  if (cachedVersion) return cachedVersion;
  try {
    const pkg = JSON.parse(readFileSync(join(config.root, 'package.json'), 'utf8'));
    cachedVersion = String(pkg.version || 'dev');
  } catch {
    cachedVersion = 'dev';
  }
  return cachedVersion;
}

/** 管理账号总数：0 = 还没建过号，这就是「首次初始化」的唯一判据 */
export async function adminCount() {
  const row = await queryOne('SELECT COUNT(*) AS n FROM admin_users');
  return Number(row?.n ?? 0);
}

/**
 * 确保有签名密钥。没有就生成一个并写回 .env。
 *
 * 写不进去（只读文件系统）也不致命：内存里用着，重启后所有人重新登录。
 * 但不能**静默**失败 —— 那是「今天登录明天又要登录」这种玄学问题的来源。
 */
export async function ensureAdminSecret() {
  if (config.admin.secret) return config.admin.secret;
  const secret = newAdminSecret();
  config.admin.secret = secret;
  try {
    updateEnvFile(ENV_PATH, { ADMIN_SECRET: secret });
    console.log('\x1b[32m✓\x1b[0m 已生成管理面板签名密钥 ADMIN_SECRET（已写入 .env）');
  } catch (e) {
    console.warn(`! ADMIN_SECRET 写不进 .env（${e.message}）`);
    console.warn('  本次进程内有效，重启后所有管理员需要重新登录');
  }
  return secret;
}

/** 给已登录的管理员换一个新 cookie */
async function issueCookie(res, admin) {
  const secret = await ensureAdminSecret();
  const token = createAdminSession({
    id: Number(admin.id),
    passwordHash: admin.password_hash,
    secret,
    ttlMs: config.admin.sessionTtlMs,
  });
  res.cookie(COOKIE_NAME, token, {
    httpOnly: true,
    sameSite: 'strict',
    path: '/admin',
    maxAge: config.admin.sessionTtlMs,
    // 面板通常跑在内网 HTTP 上，这里不强制 secure（否则本地没法用）
  });
}

/** 从请求里认出当前管理员；认不出来返回 null（不抛错） */
export async function currentAdmin(req) {
  if (!config.admin.secret) return null;
  const raw = parseCookies(req.get('cookie')).get(COOKIE_NAME);
  const parsed = parseAdminSession(raw);
  if (!parsed) return null;
  const row = await queryOne(
    'SELECT id, username, role, status, password_hash, last_login_at FROM admin_users WHERE id = ?',
    [parsed.id],
  );
  if (!row || row.status !== 'active') return null;
  const valid = verifyAdminSession(parsed, {
    secret: config.admin.secret,
    passwordHash: row.password_hash,
  });
  if (!valid) return null;
  return {
    id: Number(row.id),
    username: row.username,
    role: row.role,
    lastLoginAt: row.last_login_at,
  };
}

/**
 * 守卫：没登录就 401（接口）或渲染登录页（页面）。
 *
 * 挂在子路由之前，所以后面的每个接口都默认「已登录」，
 * 不用每个 handler 再写一遍 if (!req.admin)。
 */
export const requireAdmin = wrap(async (req, res, next) => {
  const admin = await currentAdmin(req);
  if (!admin) {
    if (req.path.startsWith('/api/')) {
      res.status(401).json({ ok: false, error: { code: 'unauthorized', message: '请先登录' } });
      return;
    }
    res.type('html').send(renderAdminPage({ version: panelVersion() }));
    return;
  }
  req.admin = admin;
  next();
});

/** 只有 admin 组能管理「管理员账号」本身（将来加只读组时这条会真正生效） */
function requireAdminRole(req) {
  if (req.admin?.role !== ROLE_ADMIN) {
    throw ApiError.forbidden('forbidden', '只有 admin 组可以管理管理员账号');
  }
}

// ================================================================ 限流

const WINDOW_MS = 10 * 60 * 1000;
const MAX_TRIES = 10;
const loginAttempts = new Map();
const setupAttempts = new Map();

function tooManyAttempts(store, ip, max = MAX_TRIES) {
  const now = Date.now();
  const entry = store.get(ip);
  if (!entry || now > entry.resetAt) {
    store.set(ip, { count: 1, resetAt: now + WINDOW_MS });
    return false;
  }
  entry.count += 1;
  return entry.count > max;
}

function clientIp(req) {
  return String(req.ip || 'unknown').slice(0, 45);
}

// ================================================================ 公开路由

export const adminAuthRouter = Router();

/** 页面状态：没建号 → setup；建了号没登录 → login；登录了 → panel */
adminAuthRouter.get(
  '/api/session',
  wrap(async (req, res) => {
    const total = await adminCount();
    if (total === 0) {
      return sendOk(res, {
        setup: true,
        setupTokenRequired: Boolean(config.admin.setupToken),
        user: null,
      });
    }
    const user = await currentAdmin(req);
    sendOk(res, { setup: false, user });
  }),
);

adminAuthRouter.post(
  '/api/setup',
  wrap(async (req, res) => {
    const ip = clientIp(req);
    if (tooManyAttempts(setupAttempts, ip, 20)) {
      throw new ApiError(429, 'too_many_attempts', '尝试次数过多，请 10 分钟后再试');
    }
    if ((await adminCount()) > 0) {
      throw ApiError.conflict('already_initialized', '管理员账号已经存在，请直接登录');
    }
    if (config.admin.setupToken) {
      const given = String(req.body?.setupToken ?? '');
      const expected = String(config.admin.setupToken);
      // 长度不同直接失败；长度相同再逐字符比（这里用简单循环，避免引入依赖）
      let diff = given.length === expected.length ? 0 : 1;
      for (let i = 0; i < expected.length && i < given.length; i += 1) {
        diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
      }
      if (diff !== 0) throw ApiError.forbidden('bad_setup_token', '初始化口令不正确');
    }

    const username = String(req.body?.username ?? '').trim();
    const usernameError = validateAdminUsername(username);
    if (usernameError) throw ApiError.badRequest('bad_username', usernameError);
    const password = String(req.body?.password ?? '');
    const passwordError = validateAdminPassword(password);
    if (passwordError) throw ApiError.badRequest('weak_password', passwordError);

    // 先拿锁再查一次：两个请求同时到达时，后到的那个看到 count > 0 会退出。
    //
    // 锁必须是**同一条数据库连接**上的命名锁（GET_LOCK 是连接级的）：
    // 用连接池的 query() 拿锁、再用另一个连接释放，锁根本放不掉，
    // 会一直挂到那条连接被回收为止。所以这里独占一条连接做完整个建号流程。
    const hash = await hashPassword(password);
    const conn = await pool.getConnection();
    try {
      const [lockRows] = await conn.query('SELECT GET_LOCK(?, 5) AS ok', [SETUP_LOCK]);
      if (Number(lockRows?.[0]?.ok) !== 1) {
        throw new ApiError(503, 'busy', '初始化被占用，请稍后再试');
      }
      const [countRows] = await conn.query('SELECT COUNT(*) AS n FROM admin_users');
      if (Number(countRows?.[0]?.n ?? 0) > 0) {
        throw ApiError.conflict('already_initialized', '管理员账号已经存在，请直接登录');
      }
      const [result] = await conn.query(
        `INSERT INTO admin_users (username, password_hash, role, created_ip, last_login_at)
         VALUES (?, ?, ?, ?, NOW(3))`,
        [username, hash, ROLE_ADMIN, ip],
      );
      const [rows] = await conn.query('SELECT * FROM admin_users WHERE id = ?', [result.insertId]);
      const row = rows[0];
      await issueCookie(res, row);
      sendOk(res, { user: { id: Number(row.id), username: row.username, role: row.role } });
    } finally {
      // 释放锁 + 还连接到池：两步都要做，顺序不能反
      await conn.query('SELECT RELEASE_LOCK(?) AS ok', [SETUP_LOCK]).catch(() => {});
      conn.release();
    }
  }),
);

adminAuthRouter.post(
  '/api/login',
  wrap(async (req, res) => {
    const ip = clientIp(req);
    if (tooManyAttempts(loginAttempts, ip)) {
      throw new ApiError(429, 'too_many_attempts', '尝试次数过多，请 10 分钟后再试');
    }
    const username = String(req.body?.username ?? '').trim();
    const password = String(req.body?.password ?? '');

    const row = username
      ? await queryOne('SELECT * FROM admin_users WHERE username = ? LIMIT 1', [username])
      : null;
    // 用户不存在也跑一次 bcrypt：否则「响应快 = 用户名不存在」就是枚举信道
    const ok = row
      ? await verifyPassword(password, row.password_hash)
      : ((await burnPasswordTime(password)), false);
    if (!row || !ok) {
      throw new ApiError(401, 'bad_credentials', '用户名或密码不正确');
    }
    if (row.status !== 'active') {
      throw ApiError.forbidden('account_disabled', '这个管理员账号已被停用');
    }

    await execute('UPDATE admin_users SET last_login_at = NOW(3) WHERE id = ?', [row.id]);
    await issueCookie(res, row);
    sendOk(res, {
      user: { id: Number(row.id), username: row.username, role: row.role },
    });
  }),
);

adminAuthRouter.post('/api/logout', (req, res) => {
  res.clearCookie(COOKIE_NAME, { path: '/admin' });
  sendOk(res, { loggedOut: true });
});

// ================================================================ 管理员管理（需登录）

export const adminAccountsRouter = Router();

function adminIdParam(req) {
  const id = Number.parseInt(String(req.params.id ?? ''), 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw ApiError.badRequest('bad_id', '管理账号 id 不合法');
  }
  return id;
}

/** 除了自己以外，还有几个可用（active）的管理员 */
async function otherActiveAdmins(id) {
  const row = await queryOne(
    "SELECT COUNT(*) AS n FROM admin_users WHERE id <> ? AND status = 'active'",
    [id],
  );
  return Number(row?.n ?? 0);
}

adminAccountsRouter.get(
  '/api/me',
  (req, res) => sendOk(res, { user: req.admin }),
);

adminAccountsRouter.post(
  '/api/me/password',
  wrap(async (req, res) => {
    const row = await queryOne('SELECT * FROM admin_users WHERE id = ?', [req.admin.id]);
    if (!row) throw ApiError.unauthorized();
    const oldPassword = String(req.body?.oldPassword ?? '');
    if (!(await verifyPassword(oldPassword, row.password_hash))) {
      throw ApiError.badRequest('bad_password', '当前密码不正确');
    }
    const newPassword = String(req.body?.newPassword ?? '');
    const error = validateAdminPassword(newPassword);
    if (error) throw ApiError.badRequest('weak_password', error);
    if (newPassword === oldPassword) {
      throw ApiError.badRequest('same_password', '新密码不能和当前密码一样');
    }

    const hash = await hashPassword(newPassword);
    await execute('UPDATE admin_users SET password_hash = ? WHERE id = ?', [hash, row.id]);
    // 旧 cookie 的签名依赖旧 hash，已经自动失效；这里补发一个新的，
    // 免得「改完自己的密码立刻被踢出去」。
    await issueCookie(res, { id: row.id, password_hash: hash });
    sendOk(res, { updated: true });
  }),
);

adminAccountsRouter.get(
  '/api/admins',
  wrap(async (_req, res) => {
    const rows = await query(
      `SELECT id, username, role, status, created_at, created_ip, last_login_at
         FROM admin_users ORDER BY id ASC`,
    );
    sendOk(res, {
      admins: rows.map((r) => ({
        id: Number(r.id),
        username: r.username,
        role: r.role,
        status: r.status,
        createdAt: r.created_at,
        createdIp: r.created_ip,
        lastLoginAt: r.last_login_at,
      })),
    });
  }),
);

adminAccountsRouter.post(
  '/api/admins',
  wrap(async (req, res) => {
    requireAdminRole(req);
    const username = String(req.body?.username ?? '').trim();
    const usernameError = validateAdminUsername(username);
    if (usernameError) throw ApiError.badRequest('bad_username', usernameError);
    const password = String(req.body?.password ?? '');
    const passwordError = validateAdminPassword(password);
    if (passwordError) throw ApiError.badRequest('weak_password', passwordError);

    // 需求明确：只允许创建 admin 组。其它组先不接受，避免出现
    // 「界面能选但权限没实现」的半成品。
    const role = String(req.body?.role ?? ROLE_ADMIN).trim() || ROLE_ADMIN;
    if (role !== ROLE_ADMIN) {
      throw ApiError.badRequest('bad_role', '目前只支持 admin 组');
    }

    const exists = await queryOne('SELECT id FROM admin_users WHERE username = ? LIMIT 1', [
      username,
    ]);
    if (exists) throw ApiError.conflict('admin_exists', '这个用户名已经存在');

    const hash = await hashPassword(password);
    const result = await execute(
      'INSERT INTO admin_users (username, password_hash, role, created_ip) VALUES (?, ?, ?, ?)',
      [username, hash, role, clientIp(req)],
    );
    sendOk(res, {
      admin: {
        id: Number(result.insertId),
        username,
        role,
        status: 'active',
        createdBy: req.admin.username,
      },
    });
  }),
);

adminAccountsRouter.post(
  '/api/admins/:id/password',
  wrap(async (req, res) => {
    requireAdminRole(req);
    const id = adminIdParam(req);
    const target = await queryOne('SELECT id, username FROM admin_users WHERE id = ?', [id]);
    if (!target) throw ApiError.notFound('没有这个管理员');
    if (id === req.admin.id) {
      throw ApiError.badRequest('use_self_endpoint', '改自己的密码请用下方「修改我的密码」');
    }
    const password = String(req.body?.password ?? '');
    const error = validateAdminPassword(password);
    if (error) throw ApiError.badRequest('weak_password', error);

    const hash = await hashPassword(password);
    await execute('UPDATE admin_users SET password_hash = ? WHERE id = ?', [hash, id]);
    // 改密码会让这个账号所有旧 cookie 失效，等于把它的所有会话踢掉
    sendOk(res, { id, updated: true });
  }),
);

adminAccountsRouter.post(
  '/api/admins/:id/status',
  wrap(async (req, res) => {
    requireAdminRole(req);
    const id = adminIdParam(req);
    const status = String(req.body?.status ?? '').trim();
    if (!['active', 'disabled'].includes(status)) {
      throw ApiError.badRequest('bad_status', '状态只能是 active 或 disabled');
    }
    const target = await queryOne('SELECT id, username FROM admin_users WHERE id = ?', [id]);
    if (!target) throw ApiError.notFound('没有这个管理员');
    if (id === req.admin.id) {
      throw ApiError.badRequest('self_status', '不能停用自己');
    }
    if (status === 'disabled' && (await otherActiveAdmins(id)) === 0) {
      throw ApiError.badRequest('last_admin', '至少要保留一个可用的管理员');
    }

    await execute('UPDATE admin_users SET status = ? WHERE id = ?', [status, id]);
    sendOk(res, { id, status });
  }),
);

adminAccountsRouter.delete(
  '/api/admins/:id',
  wrap(async (req, res) => {
    requireAdminRole(req);
    const id = adminIdParam(req);
    const target = await queryOne('SELECT id, username FROM admin_users WHERE id = ?', [id]);
    if (!target) throw ApiError.notFound('没有这个管理员');
    if (id === req.admin.id) {
      throw ApiError.badRequest('self_delete', '不能删除自己');
    }
    if ((await otherActiveAdmins(id)) === 0) {
      throw ApiError.badRequest('last_admin', '至少要保留一个可用的管理员');
    }
    await execute('DELETE FROM admin_users WHERE id = ?', [id]);
    sendOk(res, { id, deleted: true, username: target.username });
  }),
);

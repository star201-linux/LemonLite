// server/src/routes/auth.js
//
// 账号系统：注册 / 登录 / 当前用户 / 改资料 / 改密码 / 会话管理。
//
// 需求里的字段：id（自增）、用户名（可改）、头像（可改）、邮箱、密码、
// 注册时间、注册 IP。登录数据单独一张表：token / 登录时间 / 设备 / 登录 IP。
//
// 几条刻意的安全取舍：
//   1. **登录失败不区分「用户不存在」与「密码错误」** —— 统一回
//      「用户名或密码不正确」，并且用户不存在时也跑一次 bcrypt，
//      让两种失败的耗时接近。区分开等于送了一个用户名枚举接口。
//   2. **密码永远不出现在任何响应里**，包括错误响应。
//   3. 改密码要先验证旧密码（防 token 被偷后直接改密码锁死账号），
//      改完**撤销该用户的其它所有会话** —— 改密码的语义就是「把我踢下线」。
//   4. 用户名/邮箱冲突回 409 而不是 500，客户端要能用 code 定位到具体输入框。

import { Router } from 'express';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import {
  burnPasswordTime,
  createSession,
  currentUserId,
  hashPassword,
  listSessions,
  requireAuth,
  revokeAllSessions,
  revokeSession,
  verifyPassword,
} from '../lib/auth.js';
import { config } from '../config.js';
import { absoluteAvatarUrl, avatarVersion } from '../lib/userdata.js';

export const authRouter = Router();

// ---------------------------------------------------------------- 校验工具

const USERNAME_MIN = 3;
const USERNAME_MAX = 32;
const PASSWORD_MIN = 8;
const PASSWORD_MAX = 128;

/**
 * 用户名规则：
 *   * 3~32 字符
 *   * 允许中文、字母、数字、下划线、连字符、点
 *   * 不允许纯数字（会和 id / 手机号混淆，也容易被扫号）
 *   * 前后空格会被 trim 掉
 */
function validateUsername(raw) {
  const name = String(raw ?? '').trim();
  if (name.length < USERNAME_MIN || name.length > USERNAME_MAX) {
    throw ApiError.badRequest(
      'invalid_username',
      `用户名需要 ${USERNAME_MIN}~${USERNAME_MAX} 个字符`,
    );
  }
  if (!/^[\p{L}\p{N}_.-]+$/u.test(name)) {
    throw ApiError.badRequest(
      'invalid_username',
      '用户名只能包含中文、字母、数字、下划线、连字符和点',
    );
  }
  if (/^\d+$/.test(name)) {
    throw ApiError.badRequest('invalid_username', '用户名不能是纯数字');
  }
  return name;
}

function validateEmail(raw) {
  const email = String(raw ?? '').trim().toLowerCase();
  // 宽松但足够：不追求 RFC 5322 全兼容（那种正则没人能维护），
  // 只保证「有本地部分、有 @、域名里有至少一个点」。
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
    throw ApiError.badRequest('invalid_email', '邮箱格式不正确');
  }
  if (email.length > 255) {
    throw ApiError.badRequest('invalid_email', '邮箱过长');
  }
  return email;
}

function validatePassword(raw) {
  const pw = String(raw ?? '');
  if (pw.length < PASSWORD_MIN) {
    throw ApiError.badRequest('weak_password', `密码至少 ${PASSWORD_MIN} 位`);
  }
  if (pw.length > PASSWORD_MAX) {
    // 上限是为了防止 bcrypt 被超长输入拖慢（DoS）
    throw ApiError.badRequest('invalid_password', '密码过长');
  }
  return pw;
}

/**
 * 取客户端真实 IP。
 *
 * Express 的 req.ip 已经处理了 trust proxy（见 server.js）。
 * 这里只做归一化：IPv4-mapped 的 `::ffff:1.2.3.4` 要去掉前缀，
 * 否则同一台机器会出现两种写法，统计时对不上。
 */
function clientIp(req) {
  let ip = req.ip || req.socket?.remoteAddress || '';
  if (ip.startsWith('::ffff:')) ip = ip.slice(7);
  if (ip === '::1') ip = '127.0.0.1';
  return ip.slice(0, 45);
}

/**
 * 取设备标识。
 *
 * 客户端在登录时上报 `device`（形如 "Xiaomi 14 · Android 15"）。
 * **不做严格校验** —— 它是给人看的，不是安全边界；伪造它最多让
 * 「登录设备列表」显示得不准，不影响鉴权。
 */
function deviceOf(req) {
  const fromBody = String(req.body?.device ?? '').trim();
  if (fromBody) return fromBody.slice(0, 128);
  const ua = String(req.get('user-agent') ?? '').trim();
  return ua.slice(0, 128);
}

/** 数据库行 → 对外用户对象。**永远**不包含 password_hash。 */
function toUserDto(req, row) {
  return {
    id: Number(row.id),
    username: row.username,
    email: row.email,
    // 头像地址由服务端拼：客户端不需要知道存储细节，
    // 也方便将来换成 CDN 域名。
    avatarUrl: absoluteAvatarUrl(req, row),
    // 版本戳（上传时间），客户端拿它做缓存键
    avatarVersion: avatarVersion(row),
    createdAt: row.created_at,
    createdIp: row.created_ip,
    updatedAt: row.updated_at,
  };
}

// ================================================================ 注册

/**
 * POST /api/auth/register
 * body: { username, email, password, device? }
 *
 * 成功后直接返回 token（不用再登录一次）。
 * 注册时记录 created_at（数据库默认值）与 created_ip（本请求的 IP）。
 */
authRouter.post(
  '/register',
  wrap(async (req, res) => {
    const username = validateUsername(req.body?.username);
    const email = validateEmail(req.body?.email);
    const password = validatePassword(req.body?.password);

    // 先查冲突：给出**具体**哪个字段冲突，用户才知道改哪里。
    // 并发下仍可能两个请求同时通过这一步，所以插入时要靠唯一索引兜底
    // （errorHandler 会把 ER_DUP_ENTRY 变成 409）。
    const byName = await queryOne(
      'SELECT id FROM users WHERE username = ? LIMIT 1',
      [username],
    );
    if (byName) throw ApiError.conflict('username_taken', '这个用户名已被占用');

    const byEmail = await queryOne(
      'SELECT id FROM users WHERE email = ? LIMIT 1',
      [email],
    );
    if (byEmail) throw ApiError.conflict('email_taken', '这个邮箱已注册过');

    const hash = await hashPassword(password);
    const ip = clientIp(req);
    const result = await execute(
      `INSERT INTO users (username, email, password_hash, created_ip)
       VALUES (?, ?, ?, ?)`,
      [username, email, hash, ip],
    );

    const row = await queryOne('SELECT * FROM users WHERE id = ?', [
      result.insertId,
    ]);
    if (!row) throw ApiError.unavailable('注册成功但读取用户失败，请重试');

    const { token, expiresAt } = await createSession(row.id, {
      ip,
      device: deviceOf(req),
    });

    sendOk(res, {
      token,
      expiresAt: expiresAt.toISOString(),
      user: toUserDto(req, row),
    });
  }),
);

// ================================================================ 登录

/**
 * POST /api/auth/login
 * body: { account, password, device? }
 *
 * account 可以是用户名**或**邮箱 —— 用户不该被要求记住
 * 「我当时注册用的是哪个」。
 *
 * 每次成功登录都会插入一行 login_sessions（含 IP / 设备 / 时间）。
 */
authRouter.post(
  '/login',
  wrap(async (req, res) => {
    const account = String(req.body?.account ?? req.body?.username ?? '').trim();
    const password = String(req.body?.password ?? '');
    if (!account || !password) {
      throw ApiError.badRequest('bad_request', '请输入账号和密码');
    }

    const row = await queryOne(
      `SELECT * FROM users
        WHERE email = ? OR username = ?
        LIMIT 1`,
      [account.toLowerCase(), account],
    );

    const failMsg = '用户名或密码不正确';
    if (!row) {
      // 仍然消耗一次 bcrypt 的时间，避免响应时间泄露「用户是否存在」
      await burnPasswordTime(password);
      throw new ApiError(401, 'invalid_credentials', failMsg);
    }
    if (row.status === 'disabled') {
      throw ApiError.forbidden('account_disabled', '这个账号已被停用');
    }

    const ok = await verifyPassword(password, row.password_hash);
    if (!ok) throw new ApiError(401, 'invalid_credentials', failMsg);

    // 会话数上限：超出时把最旧的撤销掉，而不是拒绝新登录
    // （拒绝新登录会让「手机丢了，我换新手机登录」变得不可能）
    const limit = config.auth.maxSessionsPerUser;
    if (limit > 0) {
      const active = await query(
        `SELECT token_hash FROM login_sessions
          WHERE user_id = ? AND revoked = 0 AND expires_at > UTC_TIMESTAMP(3)
          ORDER BY last_seen_at ASC`,
        [row.id],
      );
      if (active.length >= limit) {
        const excess = active.slice(0, active.length - limit + 1);
        for (const s of excess) await revokeSession(s.token_hash);
      }
    }

    const ip = clientIp(req);
    const { token, expiresAt } = await createSession(row.id, {
      ip,
      device: deviceOf(req),
    });

    sendOk(res, {
      token,
      expiresAt: expiresAt.toISOString(),
      user: toUserDto(req, row),
    });
  }),
);

// ================================================================ 当前用户

/** GET /api/auth/me —— 客户端启动时用它校验 token 是否还有效 */
authRouter.get(
  '/me',
  requireAuth,
  wrap(async (req, res) => {
    const id = currentUserId(req);
    const row = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.unauthorized('账号不存在或已注销');
    if (row.status === 'disabled') {
      throw ApiError.forbidden('account_disabled', '这个账号已被停用');
    }
    sendOk(res, toUserDto(req, row));
  }),
);

// ================================================================ 改资料

/**
 * PATCH /api/auth/me
 * body: { username?, email? }
 *
 * 只改传了的字段。头像走 /api/upload/avatar，不在这里改
 * （它是二进制上传，语义也不同）。
 */
authRouter.patch(
  '/me',
  requireAuth,
  wrap(async (req, res) => {
    const id = currentUserId(req);
    const sets = [];
    const params = [];

    if (req.body?.username !== undefined) {
      const username = validateUsername(req.body.username);
      const dup = await queryOne(
        'SELECT id FROM users WHERE username = ? AND id <> ? LIMIT 1',
        [username, id],
      );
      if (dup) throw ApiError.conflict('username_taken', '这个用户名已被占用');
      sets.push('username = ?');
      params.push(username);
    }

    if (req.body?.email !== undefined) {
      const email = validateEmail(req.body.email);
      const dup = await queryOne(
        'SELECT id FROM users WHERE email = ? AND id <> ? LIMIT 1',
        [email, id],
      );
      if (dup) throw ApiError.conflict('email_taken', '这个邮箱已注册过');
      sets.push('email = ?');
      params.push(email);
    }

    if (sets.length === 0) {
      throw ApiError.badRequest('no_changes', '没有要修改的字段');
    }

    params.push(id);
    await execute(`UPDATE users SET ${sets.join(', ')} WHERE id = ?`, params);

    const row = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.unauthorized('账号不存在');

    // token 里没有用户名，所以改名不需要重签 —— 客户端下次 /me 就拿到新的。
    sendOk(res, { user: toUserDto(req, row) });
  }),
);

// ================================================================ 改密码

/**
 * POST /api/auth/password
 * body: { oldPassword, newPassword }
 *
 * 要求旧密码：否则 token 被偷走的人能直接改密码把原主人锁在外面。
 * 改完**撤销其它所有会话**，但保留当前这一个 ——
 * 否则用户改完密码自己也被踢出去，体验很怪。
 */
authRouter.post(
  '/password',
  requireAuth,
  wrap(async (req, res) => {
    const id = currentUserId(req);
    const oldPassword = String(req.body?.oldPassword ?? '');
    const newPassword = validatePassword(req.body?.newPassword);

    const row = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.unauthorized('账号不存在');

    const ok = await verifyPassword(oldPassword, row.password_hash);
    if (!ok) throw ApiError.badRequest('wrong_password', '当前密码不正确');
    if (oldPassword === newPassword) {
      throw ApiError.badRequest('same_password', '新密码不能和当前密码相同');
    }

    const hash = await hashPassword(newPassword);
    await execute('UPDATE users SET password_hash = ? WHERE id = ?', [
      hash,
      id,
    ]);

    // 只保留当前会话，其它全部失效
    await revokeAllSessions(id, { except: req.auth.tokenHash });

    sendOk(res, { revokedOthers: true });
  }),
);

// ================================================================ 会话管理

/**
 * GET /api/auth/sessions
 *
 * 「我的登录设备」。返回 token 的**前 8 位**作为标识（不是完整 token，
 * 也不是哈希 —— 客户端只需要一个能用来「踢掉这一台」的句柄）。
 */
authRouter.get(
  '/sessions',
  requireAuth,
  wrap(async (req, res) => {
    const rows = await listSessions(currentUserId(req));
    sendOk(
      res,
      rows.map((r) => ({
        // 句柄：让客户端能指定撤销哪一个，但不足以还原出 token
        id: r.token_hash.slice(0, 16),
        current: r.token_hash === req.auth.tokenHash,
        createdAt: r.created_at,
        lastSeenAt: r.last_seen_at,
        expiresAt: r.expires_at,
        ip: r.login_ip,
        device: r.device,
      })),
    );
  }),
);

/**
 * DELETE /api/auth/sessions/:id
 *
 * 撤销别的设备。id 是上面返回的 16 位句柄。
 */
authRouter.delete(
  '/sessions/:id',
  requireAuth,
  wrap(async (req, res) => {
    const handle = String(req.params.id ?? '').trim();
    if (handle.length < 8) {
      throw ApiError.badRequest('bad_request', '会话标识不合法');
    }
    const userId = currentUserId(req);
    // 用 LIKE 'handle%' 前缀匹配主键：句柄不可能唯一确定一行吗？
    // 16 位十六进制 = 64 bit，碰撞概率可以忽略；但仍然加上 user_id 限制，
    // 确保用户只能撤销自己的会话。
    const result = await execute(
      `UPDATE login_sessions SET revoked = 1
        WHERE user_id = ? AND token_hash LIKE CONCAT(?, '%') AND revoked = 0`,
      [userId, handle],
    );
    if (result.affectedRows === 0) {
      throw ApiError.notFound('没有这个会话（可能已过期）');
    }
    sendOk(res, { revoked: result.affectedRows });
  }),
);

/**
 * POST /api/auth/logout
 *
 * 撤销当前会话。比纯客户端删 token 强的地方：
 * 就算有人拷走了 token，这一步之后它也没用了。
 */
authRouter.post(
  '/logout',
  requireAuth,
  wrap(async (req, res) => {
    await revokeSession(req.auth.tokenHash);
    sendOk(res, { loggedOut: true });
  }),
);

/**
 * POST /api/auth/logout-all
 *
 * 退出所有设备（含当前）。用于「我怀疑账号被盗」。
 */
authRouter.post(
  '/logout-all',
  requireAuth,
  wrap(async (req, res) => {
    await revokeAllSessions(currentUserId(req));
    sendOk(res, { loggedOutAll: true });
  }),
);

// ================================================================ 检查可用性

/**
 * GET /api/auth/check?username=xxx 或 ?email=xxx
 *
 * 注册页边输入边提示「这个用户名还能用吗」。
 *
 * 这**确实**是一个账号枚举接口（能问出某个用户名/邮箱是否已注册）。
 * 之所以还是提供：注册时必然要告诉用户冲突，否则他只能靠提交失败来试。
 * 缓解措施是它只回「是否可用」，不回任何用户信息，也不告诉你是谁占用了。
 */
authRouter.get(
  '/check',
  wrap(async (req, res) => {
    const username = String(req.query.username ?? '').trim();
    const email = String(req.query.email ?? '').trim().toLowerCase();
    if (!username && !email) {
      throw ApiError.badRequest('bad_request', '需要 username 或 email 参数');
    }

    const result = {};
    if (username) {
      const row = await queryOne(
        'SELECT id FROM users WHERE username = ? LIMIT 1',
        [username],
      );
      result.username = { value: username, available: !row };
    }
    if (email) {
      const row = await queryOne(
        'SELECT id FROM users WHERE email = ? LIMIT 1',
        [email],
      );
      result.email = { value: email, available: !row };
    }
    sendOk(res, result);
  }),
);

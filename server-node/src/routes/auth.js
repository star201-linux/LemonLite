
import { Router } from 'express';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import {
  burnPasswordTime,
  createSession,
  currentUserId,
  hashPassword,
  listSessionHistory,
  listSessions,
  requireAuth,
  revokeAllSessions,
  revokeSession,
  verifyPassword,
} from '../lib/auth.js';
import {
  cancelDeletion,
  deletionInfo,
  requestDeletion,
} from '../lib/account_deletion.js';
import { config } from '../config.js';
import { assertNotBanned } from '../lib/ban.js';
import {
  validateEmail,
  validatePassword,
  validateUsername,
} from '../lib/validate.js';
import { absoluteAvatarUrl, avatarVersion } from '../lib/userdata.js';
import { MailError, mailStatus, sendMail } from '../lib/mailer.js';
import { verificationMail } from '../lib/mail_templates.js';
import {
  PURPOSES,
  consumeCode,
  discardCode,
  issueCode,
  logDevCode,
  normalizeEmail,
} from '../lib/email_codes.js';

export const authRouter = Router();

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
    deletion: deletionInfo(row),
  };
}

/**
 * 邮箱打码：`alice@example.com` → `a***e@example.com`。
 *
 * 登录验证码是发给「账号绑定的邮箱」的，报给客户端时打个码 ——
 * 它只用来让人确认「发到的是我以为的那个邮箱」，不需要回显完整地址。
 */
function maskEmail(email) {
  const text = String(email ?? '');
  const at = text.indexOf('@');
  if (at <= 0) return '***';
  const name = text.slice(0, at);
  const domain = text.slice(at);
  if (name.length <= 2) return `${name[0]}***${domain}`;
  return `${name[0]}***${name.slice(-1)}${domain}`;
}

authRouter.get(
  '/config',
  wrap(async (_req, res) => {
    const mail = mailStatus();
    sendOk(res, {
      registerCode: config.auth.registerCode,
      loginCode: config.auth.loginCode,
      mailReady: mail.ready,
      mailDriver: mail.driver,
      // 客户端倒计时用这两个值，不写死
      codeCooldown: config.mail.codeCooldown,
      codeTtl: config.mail.codeTtl,
      // never = 永不过期（客户端可以据此不做任何「到期前刷新」的逻辑）
      tokenTtl: config.auth.sessionTtl,
      // 注销冷静期（天）。客户端的注销确认页要如实告诉用户「N 天后生效」，
      // 写死在客户端就会和服务端配置慢慢对不上。
      deleteDelayDays: config.account.deleteDelayDays,
    });
  }),
);

authRouter.post(
  '/email-code',
  wrap(async (req, res) => {
    const email = validateEmail(req.body?.email);
    const purpose = String(req.body?.purpose ?? 'register').trim().toLowerCase();
    if (!PURPOSES.includes(purpose)) {
      throw ApiError.badRequest('bad_request', '不支持的验证码用途');
    }
    if (purpose === 'register' && !config.auth.registerCode) {
      throw ApiError.badRequest('register_code_disabled', '这台服务器注册不需要验证码');
    }
    if (purpose === 'login') {
      throw ApiError.badRequest('bad_request', '登录验证码请用 /api/auth/login-code');
    }
    if (purpose === 'change_email') {
      // 换邮箱要发到**新**邮箱，且必须先验证当前密码，
      // 这两件事都只能在这个账号已登录的情况下做。
      throw ApiError.badRequest(
        'bad_request',
        '更换邮箱的验证码请用 /api/auth/change-email/code',
      );
    }

    const status = mailStatus();
    if (!status.ready) {
      // 部署方忘记配邮件时的报错必须足够具体，否则只能靠猜
      throw ApiError.unavailable(`服务端邮件通道未配置：${status.reason}`);
    }

    const exists = await queryOne('SELECT id FROM users WHERE email = ? LIMIT 1', [email]);
    if (exists) throw ApiError.conflict('email_taken', '这个邮箱已注册过');

    // 限流都在 issueCode 里：冷却、邮箱小时配额、IP 小时配额
    const { id, code } = await issueCode({
      email: normalizeEmail(email),
      purpose,
      ip: clientIp(req),
    });

    const template = verificationMail({
      code,
      ttlSeconds: config.mail.codeTtl,
      purpose,
    });

    try {
      await sendMail({ to: email, ...template });
    } catch (e) {
      // 信没发出去就把码删掉：否则用户会在冷却期里等一封永远不来的邮件
      await discardCode(id);
      const reason = e instanceof MailError ? e.message : String(e);
      console.error(`\x1b[31m[mail] 发送失败\x1b[0m ${email}：${reason}`);
      throw ApiError.unavailable(
        status.driver === 'smtp'
          ? '验证码邮件发送失败，请稍后再试（服务端 SMTP 配置可能有问题）'
          : '验证码邮件发送失败，请稍后再试',
      );
    }

    // 开发环境把码打一行到服务端日志；接口响应始终不含验证码
    logDevCode({ code, email, purpose });

    sendOk(res, {
      sent: true,
      email,
      // 客户端用它来跑倒计时，避免「客户端写死 60 秒、服务端却改了」
      cooldown: config.mail.codeCooldown,
      expiresIn: config.mail.codeTtl,
      driver: status.driver,
    });
  }),
);

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
    const code = String(req.body?.code ?? '').trim();
    // AUTH_REGISTER_CODE=off 时整段跳过（只适合内网/自测）
    if (config.auth.registerCode && !/^\d{4,8}$/.test(code)) {
      throw ApiError.badRequest('code_required', '请输入邮箱收到的验证码');
    }

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

    if (config.auth.registerCode) {
      await consumeCode({ email, purpose: 'register', code });
    }

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

authRouter.post(
  '/login-code',
  wrap(async (req, res) => {
    if (!config.auth.loginCode) {
      throw ApiError.badRequest('login_code_disabled', '这台服务器登录不需要验证码');
    }
    const account = String(req.body?.account ?? req.body?.username ?? '').trim();
    const password = String(req.body?.password ?? '');
    if (!account || !password) {
      throw ApiError.badRequest('bad_request', '请输入账号和密码');
    }

    const row = await queryOne(
      `SELECT * FROM users WHERE email = ? OR username = ? LIMIT 1`,
      [account.toLowerCase(), account],
    );
    const failMsg = '用户名或密码不正确';
    if (!row) {
      await burnPasswordTime(password);
      throw new ApiError(401, 'invalid_credentials', failMsg);
    }
    // 封禁：临时封禁到期后会在这里顺手解封（见 lib/ban.js）
    await assertNotBanned(row);
    const ok = await verifyPassword(password, row.password_hash);
    if (!ok) throw new ApiError(401, 'invalid_credentials', failMsg);

    const status = mailStatus();
    if (!status.ready) {
      throw ApiError.unavailable(`服务端邮件通道未配置：${status.reason}`);
    }

    // 限流与注册共用一套（同一张表、同一组配额）：区分用途只会让
    // 「注册 10 次 + 登录 10 次 = 20 封」这种绕过方式成立。
    const { id, code } = await issueCode({
      email: normalizeEmail(row.email),
      purpose: 'login',
      ip: clientIp(req),
    });

    const template = verificationMail({
      code,
      ttlSeconds: config.mail.codeTtl,
      purpose: 'login',
    });
    try {
      await sendMail({ to: row.email, ...template });
    } catch (e) {
      await discardCode(id);
      const reason = e instanceof MailError ? e.message : String(e);
      console.error(`\x1b[31m[mail] 登录验证码发送失败\x1b[0m ${row.email}：${reason}`);
      throw ApiError.unavailable('验证码邮件发送失败，请稍后再试');
    }

    logDevCode({ code, email: row.email, purpose: 'login' });

    sendOk(res, {
      sent: true,
      // 打码：只用于确认「发到的是我以为的那个邮箱」
      email: maskEmail(row.email),
      cooldown: config.mail.codeCooldown,
      expiresIn: config.mail.codeTtl,
      driver: status.driver,
    });
  }),
);

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
    // 封禁：临时封禁到期后会在这里顺手解封（见 lib/ban.js）
    await assertNotBanned(row);

    const ok = await verifyPassword(password, row.password_hash);
    if (!ok) throw new ApiError(401, 'invalid_credentials', failMsg);

    if (config.auth.loginCode) {
      const code = String(req.body?.code ?? '').trim();
      if (!code) {
        throw new ApiError(
          401,
          'code_required',
          '这台服务器登录需要邮箱验证码，请先获取',
        );
      }
      await consumeCode({ email: row.email, purpose: 'login', code });
    }

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
    // 封禁：临时封禁到期后会在这里顺手解封（见 lib/ban.js）
    await assertNotBanned(row);
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
      throw ApiError.badRequest(
        'email_locked',
        '邮箱已与账号绑定，请通过「更换邮箱」完成验证后修改',
      );
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

authRouter.post(
  '/change-email/code',
  requireAuth,
  wrap(async (req, res) => {
    const id = currentUserId(req);
    const password = String(req.body?.password ?? '');
    const email = validateEmail(req.body?.email);

    const row = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.unauthorized('账号不存在');
    if (!password) {
      throw ApiError.badRequest('password_required', '请输入当前密码');
    }
    const ok = await verifyPassword(password, row.password_hash);
    if (!ok) throw ApiError.badRequest('wrong_password', '当前密码不正确');

    if (normalizeEmail(row.email) === normalizeEmail(email)) {
      throw ApiError.badRequest('same_email', '新邮箱和当前邮箱相同');
    }
    const dup = await queryOne(
      'SELECT id FROM users WHERE email = ? AND id <> ? LIMIT 1',
      [email, id],
    );
    if (dup) throw ApiError.conflict('email_taken', '这个邮箱已被其他账号使用');

    const status = mailStatus();
    if (!status.ready) {
      throw ApiError.unavailable(`服务端邮件通道未配置：${status.reason}`);
    }

    const { id: codeId, code } = await issueCode({
      email: normalizeEmail(email),
      purpose: 'change_email',
      ip: clientIp(req),
    });

    const template = verificationMail({
      code,
      ttlSeconds: config.mail.codeTtl,
      purpose: 'change_email',
    });
    try {
      await sendMail({ to: email, ...template });
    } catch (e) {
      await discardCode(codeId);
      const reason = e instanceof MailError ? e.message : String(e);
      console.error(`\x1b[31m[mail] 换绑验证码发送失败\x1b[0m ${email}：${reason}`);
      throw ApiError.unavailable('验证码邮件发送失败，请稍后再试');
    }

    logDevCode({ code, email, purpose: 'change_email' });

    sendOk(res, {
      sent: true,
      // 打码：确认「发到的是我以为的那个新邮箱」
      email: maskEmail(email),
      cooldown: config.mail.codeCooldown,
      expiresIn: config.mail.codeTtl,
      driver: status.driver,
    });
  }),
);

authRouter.post(
  '/change-email',
  requireAuth,
  wrap(async (req, res) => {
    const id = currentUserId(req);
    const password = String(req.body?.password ?? '');
    const email = validateEmail(req.body?.email);
    const code = String(req.body?.code ?? '').trim();

    const row = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.unauthorized('账号不存在');
    if (!password) {
      throw ApiError.badRequest('password_required', '请输入当前密码');
    }
    const ok = await verifyPassword(password, row.password_hash);
    if (!ok) throw ApiError.badRequest('wrong_password', '当前密码不正确');

    if (normalizeEmail(row.email) === normalizeEmail(email)) {
      throw ApiError.badRequest('same_email', '新邮箱和当前邮箱相同');
    }
    const dup = await queryOne(
      'SELECT id FROM users WHERE email = ? AND id <> ? LIMIT 1',
      [email, id],
    );
    if (dup) throw ApiError.conflict('email_taken', '这个邮箱已被其他账号使用');

    if (!/^\d{4,8}$/.test(code)) {
      throw ApiError.badRequest('code_required', '请输入新邮箱收到的验证码');
    }
    // 所有校验都过了才核销 —— 让用户改个邮箱重试时不用重新收码
    await consumeCode({
      email: normalizeEmail(email),
      purpose: 'change_email',
      code,
    });

    await execute('UPDATE users SET email = ? WHERE id = ?', [email, id]);
    await revokeAllSessions(id, { except: req.auth.tokenHash });

    const fresh = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!fresh) throw ApiError.unauthorized('账号不存在');
    sendOk(res, { user: toUserDto(req, fresh), revokedOthers: true });
  }),
);

authRouter.post(
  '/delete',
  requireAuth,
  wrap(async (req, res) => {
    const id = currentUserId(req);
    const password = String(req.body?.password ?? '');
    const row = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.unauthorized('账号不存在');

    if (!password) {
      throw ApiError.badRequest('password_required', '请输入当前密码');
    }
    const ok = await verifyPassword(password, row.password_hash);
    if (!ok) throw ApiError.badRequest('wrong_password', '当前密码不正确');

    const result = await requestDeletion(id);
    if (result.immediate) {
      sendOk(res, { deleted: true, deletion: null });
      return;
    }

    await revokeAllSessions(id, { except: req.auth.tokenHash });
    sendOk(res, { deleted: false, deletion: result.deletion });
  }),
);

/** POST /api/auth/delete/cancel —— 冷静期内撤销注销申请 */
authRouter.post(
  '/delete/cancel',
  requireAuth,
  wrap(async (req, res) => {
    const id = currentUserId(req);
    await cancelDeletion(id);
    sendOk(res, { deletion: null });
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

authRouter.get(
  '/sessions/history',
  requireAuth,
  wrap(async (req, res) => {
    const rows = await listSessionHistory(currentUserId(req));
    const now = Date.now();
    sendOk(
      res,
      rows.map((r) => {
        const expires = new Date(
          `${String(r.expires_at).replace(' ', 'T')}Z`,
        ).getTime();
        const expired = Number.isFinite(expires) && expires <= now;
        return {
          id: r.token_hash.slice(0, 16),
          current: r.token_hash === req.auth.tokenHash,
          // active = 「这一条现在还能用」；客户端不需要自己再算一遍
          active: !r.revoked && !expired,
          revoked: Boolean(r.revoked),
          expired,
          createdAt: r.created_at,
          lastSeenAt: r.last_seen_at,
          expiresAt: r.expires_at,
          ip: r.login_ip,
          device: r.device,
        };
      }),
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

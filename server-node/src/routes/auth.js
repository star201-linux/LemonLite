// server/src/routes/auth.js
//
// 账号系统：邮箱验证码 / 注册 / 登录 / 当前用户 / 改资料 / 改密码 / 会话管理。
//
// 验证码有两个开关，都在服务端（客户端不写死，启动时读 /api/auth/config）：
//   AUTH_REGISTER_CODE  注册要不要验证码（默认 on）
//   AUTH_LOGIN_CODE     登录要不要再来一次验证码（默认 off）
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
//   5. **注册必须持有一个没过期的邮箱验证码**。没有这一步，任何人都能用
//      别人的邮箱注册（邮箱地址不是秘密），之后「用邮箱找回密码」
//      就变成了「谁都能接管这个账号」。验证码只在这里核销一次。

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
    // 注销冷静期状态：没申请过就是 null。
    // 放在 DTO 里而不是单开一个接口，是因为客户端在**登录**时就要知道
    // 「这个号已经被申请注销了，还剩 N 天」，好直接给出撤销入口。
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

// ================================================================ 服务端能力

/**
 * GET /api/auth/config
 *
 * 客户端据此决定界面：注册页要不要显示验证码输入框、登录页要不要
 * 先「获取验证码」。这些行为**必须**由服务端说了算 —— 否则会出现
 * 「客户端要验证码、服务端没开」这种永远登不进去的组合。
 *
 * 公开接口，不需要登录，也不泄露任何用户信息。
 */
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

// ================================================================ 邮箱验证码

/**
 * POST /api/auth/email-code
 * body: { email, purpose?: 'register' }
 *
 * 给注册页发一封带验证码的邮件。邮件通道由服务端配置决定（自建 SMTP /
 * Resend / SendGrid / 阿里云），客户端不需要也不应该知道用的是哪一种。
 *
 * 返回里**不含验证码**。开发时如果不想真发信，用 MAIL_DRIVER=console
 * （整封信打到日志里），或者打开 MAIL_DEV_ECHO_CODE 让服务端单独打一行验证码。
 * 两种方式都只在服务端日志里出现，**不会**通过接口返回给客户端。
 *
 * 这里有一个刻意的取舍：邮箱已注册时直接回 409 `email_taken`，
 * 而不是「假装发送成功」。这会泄露「这个邮箱注册过」，
 * 但注册接口本来就会告诉他们，遮着反而让用户对着一个永远收不到的信箱发呆。
 */
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
      // 登录验证码必须走 /api/auth/login-code：它要先核对密码，
      // 否则就成了「只要知道别人邮箱就能给他发信」的轰炸工具。
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

    // 核销验证码。放在最后一步（冲突都查完之后）：
    // 用户名撞车时不该把用户的验证码白白烧掉 —— 他改个名字还能用同一个码。
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

// ================================================================ 登录验证码

/**
 * POST /api/auth/login-code
 * body: { account, password }
 *
 * 开启「登录需要验证码」后，登录前先用这个接口拿一封验证码邮件。
 *
 * **必须先核对密码**才发信。否则它就是一个「知道邮箱即可轰炸对方邮箱」
 * 的接口 —— 而且还会被用来判断「哪些邮箱注册过这个站」。
 * 代价是用户要输两次密码，但客户端只需要在同一个表单里按一下「获取验证码」。
 *
 * 密码错时与 /login 一样统一回「用户名或密码不正确」，并同样消耗
 * 一次 bcrypt 的时间，避免这个接口变成更快的用户名枚举信道。
 */
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
    if (row.status === 'disabled') {
      throw ApiError.forbidden('account_disabled', '这个账号已被停用');
    }
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

    // ---- 二次验证（可选，由服务端配置决定）
    //
    // 顺序很重要：**先验密码，再验码**。反过来的话，攻击者不需要知道密码
    // 就能用「验证码对不对」来试探账号是否存在；而且用户输错密码时
    // 不该被白白烧掉一个验证码。
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
      // 邮箱是账号的根凭证（找回密码、登录验证码都靠它），
      // 所以它不能像用户名那样随手改 —— 必须走 POST /api/auth/change-email：
      // 验证当前密码 + 给**新**邮箱发一封验证码。
      // 这里明确拒绝，而不是悄悄忽略：客户端旧版本如果还在提交 email，
      // 静默忽略会让用户以为改成功了。
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

// ================================================================ 更换邮箱
//
// 邮箱和账号是**强绑定**的：它是登录凭据的一部分，也是找回密码的唯一入口。
// 所以它不能像用户名那样在「编辑资料」里随手改 —— 那样一个被偷走的 token
// 就能把账号的根换掉，原主人再也找不回来。
//
// 两步走：
//   1. POST /change-email/code  校验当前密码 → 给**新**邮箱发验证码
//   2. POST /change-email       密码 + 验证码 → 换绑，并踢掉其它设备

/**
 * POST /api/auth/change-email/code
 * body: { email, password }
 *
 * 为什么必须先验密码：这个接口会给任意邮箱发信。不验密码的话，
 * 任何拿到 token 的人都能拿它当「邮件轰炸机」，也能探测某个邮箱是否已注册。
 */
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

/**
 * POST /api/auth/change-email
 * body: { email, password, code }
 *
 * 密码**再验一次**：中间可能隔了几分钟（用户去收信），
 * 不能假设「拿到验证码请求时就一定还是本人」。
 *
 * 换绑成功踢掉其它设备：邮箱变了，说明账号的根换了，
 * 留在旧设备上的登录态应该重新确认一次身份。
 */
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

// ================================================================ 注销账号

/**
 * POST /api/auth/delete
 * body: { password }
 *
 * 申请注销。账号**不会立刻消失**：按面板设置的冷静期排期，
 * 到期由后台任务物理删除；期间用户仍可登录并撤销。
 *
 * 为什么要密码：注销是破坏性操作，光有 token 不够 ——
 * 手机被人顺手拿走、或者 token 被拷走，都不该能一键抹掉账号。
 */
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

    // 其它设备先踢掉：账号已经进入删除队列，没必要让它们继续挂着。
    // 当前会话保留 —— 客户端拿到响应后会自己退出登录，
    // 而如果它中途崩了，用户还能用这个 token 回来撤销。
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

/**
 * GET /api/auth/sessions/history
 *
 * 「登录设备」二级页的历史分区：返回**全部**会话记录（含已撤销、已过期），
 * 每条带 active / revoked / expired 三个标记，客户端据此分三组展示：
 *   当前设备 / 其它在线 / 历史登录
 *
 * 为什么不合并进 /sessions：那个接口的返回是「当前有效设备」，
 * 语义干净（撤销列表里只该出现能踢的设备）。历史记录是审计信息，
 * 混在一起会让「踢下线」的按钮出现在一堆已经失效的行上。
 */
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

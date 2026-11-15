// server/src/admin/users.js
//
// 面板的「用户」页：市场用户（users 表）的查看 / 改资料 / 头像 / 封禁 /
// 改密 / 踢下线 / 删除。
//
// 注意这里的「用户」是 App 里的普通用户，和 admin_users 是两回事。
//
// 两个原则：
//   1. 封禁、改密码都会**撤销该用户全部会话**：只改 status 只能拦下一次校验，
//      已经登录的设备还揣着 token 继续用。
//   2. 用户在面板里能改的东西（用户名 / 邮箱 / 头像）和客户端能改的**是同一套规则**
//      —— 校验函数从 lib/validate.js 来，头像走同一套魔数检查与落盘逻辑。
//      面板绕过规则的下场是「库里存着一个登录不上的账号」。

import { Router } from 'express';
import multer from 'multer';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { hashPassword, revokeAllSessions } from '../lib/auth.js';
import { cancelDeletion, deletionInfo, purgeUser } from '../lib/account_deletion.js';
import { banInfo, liftBan, parseBanDuration } from '../lib/ban.js';
import { toSqlTime } from '../lib/sql_time.js';
import { sniffImage } from '../lib/image.js';
import { validateEmail, validateUsername } from '../lib/validate.js';
import {
  absoluteAvatarUrl,
  avatarBytes,
  avatarVersion,
  deleteAvatar,
  saveAvatar,
  userDataMeta,
} from '../lib/userdata.js';
import { config } from '../config.js';

export const usersRouter = Router();

function userIdParam(req) {
  const id = Number.parseInt(String(req.params.id ?? ''), 10);
  if (!Number.isSafeInteger(id) || id <= 0) throw ApiError.badRequest('bad_id', '用户 id 不合法');
  return id;
}

/**
 * 头像上传接收器（内存里接，落盘前先验魔数）。
 *
 * 与 /api/upload/avatar 用同一个上限配置：面板不该拥有比客户端更大的口子。
 */
const avatarUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: config.userdata.maxAvatarBytes, files: 1, fields: 2 },
  fileFilter: (_req, file, cb) => {
    if (!/^image\/(png|jpe?g|webp)$/i.test(file.mimetype)) {
      return cb(ApiError.badRequest('bad_image_type', '只支持 PNG / JPEG / WebP 图片'));
    }
    return cb(null, true);
  },
});

function toAdminUser(req, row) {
  return {
    id: Number(row.id),
    username: row.username,
    email: row.email,
    status: row.status,
    createdAt: row.created_at,
    createdIp: row.created_ip,
    updatedAt: row.updated_at,
    avatarUrl: absoluteAvatarUrl(req, row),
    avatarVersion: avatarVersion(row),
    ban: banInfo(row),
    deletion: deletionInfo(row),
  };
}

usersRouter.get(
  '/api/users',
  wrap(async (req, res) => {
    const q = String(req.query.q ?? '').trim();
    const like = `%${q}%`;
    const rows = await query(
      `SELECT id, username, email, status, banned_until, ban_reason,
              created_at, created_ip, avatar_ver,
              deletion_requested_at, deletion_scheduled_at
         FROM users
        WHERE (? = '' OR username LIKE ? OR email LIKE ?)
        ORDER BY id DESC LIMIT 100`,
      [q, like, like],
    );
    sendOk(res, { users: rows.map((r) => toAdminUser(req, r)) });
  }),
);

/**
 * GET /api/users/:id
 *
 * 详情页要在一个屏幕里答完「这个人是谁、能不能登录、占多大空间」，
 * 所以这里顺带带上会话数、data.json 大小与头像大小 ——
 * 分别再去点三个接口对运维来说是没必要的往返。
 */
usersRouter.get(
  '/api/users/:id',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const row = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    const [sessions, dataMeta] = await Promise.all([
      queryOne(
        `SELECT
           SUM(CASE WHEN revoked = 0 AND expires_at > UTC_TIMESTAMP(3) THEN 1 ELSE 0 END) AS active,
           COUNT(*) AS total
         FROM login_sessions WHERE user_id = ?`,
        [id],
      ),
      userDataMeta(id).catch(() => ({ exists: false, bytes: 0, updatedAt: null })),
    ]);

    sendOk(res, {
      user: toAdminUser(req, row),
      sessions: {
        active: Number(sessions?.active ?? 0),
        total: Number(sessions?.total ?? 0),
      },
      userdata: {
        exists: !!dataMeta.exists,
        bytes: Number(dataMeta.bytes ?? 0),
        updatedAt: dataMeta.updatedAt ?? null,
      },
      avatarBytes: await avatarBytes(id).catch(() => 0),
    });
  }),
);

/**
 * PUT /api/users/:id
 * body: { username?, email? }
 *
 * 只改传了的字段。**邮箱在这里可以直接改**（客户端不行）：
 * 管理员代改是「用户写信来说邮箱填错了」这类场景，本来就绕过了本人验证；
 * 客户端那条路要密码 + 新邮箱验证码，两条路的信任前提不同。
 *
 * 改名不需要踢会话（token 里没有用户名）；改邮箱也不踢 ——
 * 用户下次打开 App 拉一次 /me 就拿到新邮箱，没必要把他踢出去。
 */
usersRouter.put(
  '/api/users/:id',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

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
      if (dup) throw ApiError.conflict('email_taken', '这个邮箱已被占用');
      sets.push('email = ?');
      params.push(email);
    }

    if (sets.length === 0) throw ApiError.badRequest('no_changes', '没有要修改的字段');

    params.push(id);
    await execute(`UPDATE users SET ${sets.join(', ')} WHERE id = ?`, params);

    const updated = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    sendOk(res, { user: toAdminUser(req, updated) });
  }),
);

/**
 * POST /api/users/:id/avatar  multipart，字段名 file
 *
 * 落盘逻辑与客户端上传完全一样（saveAvatar + 版本戳），
 * 区别只是 userId 来自 URL 而不是当前登录态。
 */
usersRouter.post(
  '/api/users/:id/avatar',
  avatarUpload.single('file'),
  wrap(async (req, res) => {
    const id = userIdParam(req);
    if (!req.file?.buffer?.length) {
      throw ApiError.badRequest('no_file', '没有收到文件（字段名应为 file）');
    }
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    const kind = sniffImage(req.file.buffer);
    if (!kind) {
      throw ApiError.badRequest('bad_image', '这个文件不是有效的 PNG / JPEG / WebP 图片');
    }

    const bytes = await saveAvatar(id, req.file.buffer);
    const version = String(Date.now());
    await execute('UPDATE users SET avatar_ver = ? WHERE id = ?', [version, id]);

    const updated = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    sendOk(res, {
      bytes,
      format: kind,
      user: toAdminUser(req, updated),
    });
  }),
);

usersRouter.delete(
  '/api/users/:id/avatar',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    await deleteAvatar(id);
    await execute("UPDATE users SET avatar_ver = '' WHERE id = ?", [id]);
    sendOk(res, { removed: true });
  }),
);

/**
 * POST /api/users/:id/ban
 * body: { durationDays, reason? }
 *
 * durationDays：正整数 = 天数，`-1` = 永久。
 * 封禁立刻撤销全部会话 —— 否则被踢的人手里那张 token 还能用到过期。
 */
usersRouter.post(
  '/api/users/:id/ban',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const row = await queryOne('SELECT id, username FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    const { until, days } = parseBanDuration(req.body?.durationDays);
    const reason = String(req.body?.reason ?? '').trim().slice(0, 255);

    await execute(
      `UPDATE users
          SET status = 'disabled', banned_until = ?, ban_reason = ?
        WHERE id = ?`,
      [until ? toSqlTime(until) : null, reason, id],
    );
    await revokeAllSessions(id);

    const updated = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    sendOk(res, { user: toAdminUser(req, updated), days });
  }),
);

usersRouter.post(
  '/api/users/:id/unban',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');
    await liftBan(id);
    const updated = await queryOne('SELECT * FROM users WHERE id = ?', [id]);
    sendOk(res, { user: toAdminUser(req, updated) });
  }),
);

/**
 * POST /api/users/:id/status
 * body: { status: 'active' | 'disabled' }
 *
 * 老的「封禁 / 解封」开关，保留给脚本与旧面板：
 *   disabled → 等价于**永久**封禁（banned_until = NULL）
 *   active   → 等价于解封（三个字段一起清）
 * 新面板走 /ban 与 /unban，能填时长和原因。
 */
usersRouter.post(
  '/api/users/:id/status',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const status = String(req.body?.status ?? '').trim();
    if (!['active', 'disabled'].includes(status)) {
      throw ApiError.badRequest('bad_status', '状态只能是 active 或 disabled');
    }
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    if (status === 'active') {
      await liftBan(id);
    } else {
      await execute(
        `UPDATE users
            SET status = 'disabled', banned_until = NULL, ban_reason = ?
          WHERE id = ?`,
        ['由管理面板停用', id],
      );
      // 封禁要立刻生效：光改 status 只是拦下一次校验，已经登录的设备还揣着 token
      await revokeAllSessions(id);
    }
    sendOk(res, { id, status });
  }),
);

usersRouter.post(
  '/api/users/:id/password',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const password = String(req.body?.password ?? '');
    if (password.length < 8) throw ApiError.badRequest('weak_password', '密码至少 8 位');
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    await execute('UPDATE users SET password_hash = ? WHERE id = ?', [
      await hashPassword(password),
      id,
    ]);
    // 改密码 = 把这个人从所有设备上踢下去（管理面板代改的场合尤其如此）
    await revokeAllSessions(id);
    sendOk(res, { id, updated: true });
  }),
);

/** 立即删除（跳过冷静期）：用户写信要求、或者这个号在发垃圾内容时用 */
usersRouter.post(
  '/api/users/:id/delete',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const row = await queryOne('SELECT id, username FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');
    // purgeUser 内部会先撤销全部会话，再删 userdata/<id>/，最后删行
    await purgeUser(id, { reason: `管理面板删除（${row.username}）` });
    sendOk(res, { id, deleted: true });
  }),
);

/** 撤销注销申请（用户反悔、或者误操作后由运营恢复） */
usersRouter.post(
  '/api/users/:id/restore',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');
    await cancelDeletion(id);
    sendOk(res, { id, deletion: null });
  }),
);

usersRouter.post(
  '/api/users/:id/logout',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    await revokeAllSessions(id);
    sendOk(res, { id, loggedOut: true });
  }),
);

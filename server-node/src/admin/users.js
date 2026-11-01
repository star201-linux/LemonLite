// server/src/admin/users.js
//
// 面板的「用户」页：市场用户（users 表）的封禁 / 改密 / 踢下线。
//
// 注意这里的「用户」是 App 里的普通用户，和 admin_users 是两回事。
// 封禁与改密码都会**撤销该用户全部会话**：只改 status 只能拦下一次校验，
// 已经登录的设备还揣着 token 继续用。

import { Router } from 'express';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { hashPassword, revokeAllSessions } from '../lib/auth.js';

export const usersRouter = Router();

function userIdParam(req) {
  const id = Number.parseInt(String(req.params.id ?? ''), 10);
  if (!Number.isSafeInteger(id) || id <= 0) throw ApiError.badRequest('bad_id', '用户 id 不合法');
  return id;
}

usersRouter.get(
  '/api/users',
  wrap(async (req, res) => {
    const q = String(req.query.q ?? '').trim();
    const like = `%${q}%`;
    const rows = await query(
      `SELECT id, username, email, status, created_at, created_ip
         FROM users
        WHERE (? = '' OR username LIKE ? OR email LIKE ?)
        ORDER BY id DESC LIMIT 100`,
      [q, like, like],
    );
    sendOk(res, {
      users: rows.map((r) => ({
        id: Number(r.id),
        username: r.username,
        email: r.email,
        status: r.status,
        createdAt: r.created_at,
        createdIp: r.created_ip,
      })),
    });
  }),
);

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

    await execute('UPDATE users SET status = ? WHERE id = ?', [status, id]);
    // 封禁要立刻生效：光改 status 只是拦下一次校验，已经登录的设备还揣着 token
    if (status === 'disabled') await revokeAllSessions(id);
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

usersRouter.post(
  '/api/users/:id/logout',
  wrap(async (req, res) => {
    const id = userIdParam(req);
    await revokeAllSessions(id);
    sendOk(res, { id, loggedOut: true });
  }),
);

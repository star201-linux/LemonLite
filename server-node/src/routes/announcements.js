// server/src/routes/announcements.js
//
// 站点公告（公开，不需要登录）。
//
//   GET /api/announcements?limit=20&offset=0   历史公告（按发布时间倒序）
//   GET /api/announcements/latest              最新一条（客户端启动时用）
//
// 为什么不需要登录：公告就是「贴在大门口的通知」——
// 未登录的用户更需要看到它（比如「服务维护中」「注册已关闭」）。
//
// **只返回 published_at <= 现在 的公告**。这一条让「定时发布」变成免费功能：
// 面板里把发布时间填成明天早上 9 点，到点客户端自然就能拉到，
// 不需要任何定时任务去「上架」它。
// 代价是「发布时间」必须可信 —— 面板允许改它（写错日期是常态）。

import { Router } from 'express';
import { query, queryOne } from '../db.js';
import { sendOk, wrap } from '../lib/http.js';
import { sqlToIso } from '../lib/sql_time.js';

export const announcementsRouter = Router();

const MAX_LIMIT = 50;

function toDto(row) {
  return {
    id: Number(row.id),
    title: row.title,
    content: row.content,
    // 1~4：打扰级别。客户端据此决定是红点、横幅还是弹窗（见 docs）。
    level: Number(row.level ?? 1),
    // ISO + Z：浏览器与 Dart 都能正确按 UTC 解析，再各自转本地时间
    publishedAt: sqlToIso(row.published_at),
  };
}

function pageSize(raw) {
  const n = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(n) || n <= 0) return 20;
  return Math.min(n, MAX_LIMIT);
}

function offsetOf(raw) {
  const n = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(n) || n < 0) return 0;
  return n;
}

/**
 * GET /api/announcements
 *
 * 分页用 offset 而不是游标：公告是**只增不改的短列表**，
 * 一年也就几十条，客户端一次性翻到底（limit 50）就结束了。
 * 游标分页在这里只会增加双方的复杂度。
 */
announcementsRouter.get(
  '/',
  wrap(async (req, res) => {
    const limit = pageSize(req.query.limit);
    const offset = offsetOf(req.query.offset);

    // 多取一条判断 hasMore，省掉一次 COUNT(*)
    const rows = await query(
      `SELECT id, title, content, level, published_at
         FROM announcements
        WHERE published_at <= UTC_TIMESTAMP(3)
        ORDER BY published_at DESC, id DESC
        LIMIT ? OFFSET ?`,
      [limit + 1, offset],
    );
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    sendOk(res, { announcements: page.map(toDto) }, { limit, offset, hasMore });
  }),
);

/**
 * GET /api/announcements/latest
 *
 * 客户端每次启动调用。没有公告时 `announcement: null` ——
 * 这是合法结果（新站还没有发过公告），不是 404。
 */
announcementsRouter.get(
  '/latest',
  wrap(async (_req, res) => {
    const row = await queryOne(
      `SELECT id, title, content, level, published_at
         FROM announcements
        WHERE published_at <= UTC_TIMESTAMP(3)
        ORDER BY published_at DESC, id DESC
        LIMIT 1`,
    );
    sendOk(res, { announcement: row ? toDto(row) : null });
  }),
);

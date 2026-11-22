
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

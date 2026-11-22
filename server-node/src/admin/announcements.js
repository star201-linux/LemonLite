
import { Router } from 'express';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { nowSql, sqlToIso, toSqlTime } from '../lib/sql_time.js';

export const announcementsRouter = Router();

const TITLE_MAX = 200;
const CONTENT_MAX = 20000;

/** 四个级别，含义见 docs/账号与站点设置.md */
export const LEVELS = [1, 2, 3, 4];

function toDto(row) {
  const publishedAt = sqlToIso(row.published_at);
  return {
    id: Number(row.id),
    title: row.title,
    content: row.content,
    level: Number(row.level ?? 1),
    publishedAt,
    createdAt: sqlToIso(row.created_at),
    updatedAt: sqlToIso(row.updated_at),
    // 未来时间 = 还没发布。面板据此显示「待发布」徽标，
    // 不用让前端自己去比时间（两端的时钟不一定一致）。
    pending: publishedAt ? new Date(publishedAt).getTime() > Date.now() : false,
  };
}

function idParam(req) {
  const id = Number.parseInt(String(req.params.id ?? ''), 10);
  if (!Number.isSafeInteger(id) || id <= 0) {
    throw ApiError.badRequest('bad_id', '公告 id 不合法');
  }
  return id;
}

function readTitle(raw) {
  const title = String(raw ?? '').trim();
  if (!title) throw ApiError.badRequest('bad_title', '标题不能为空');
  if (title.length > TITLE_MAX) {
    throw ApiError.badRequest('bad_title', `标题最多 ${TITLE_MAX} 个字符`);
  }
  return title;
}

function readContent(raw) {
  const content = String(raw ?? '').trim();
  if (!content) throw ApiError.badRequest('bad_content', '内容不能为空');
  if (content.length > CONTENT_MAX) {
    throw ApiError.badRequest('bad_content', `内容最多 ${CONTENT_MAX} 个字符`);
  }
  return content;
}

/**
 * 级别：1~4。
 *
 * 不接受「0 表示默认」这种写法 —— 面板的下拉永远有值，
 * 真收到 0 说明前端传错了，静默改成 1 会让「我明明选了弹窗，怎么没弹」
 * 变成一次纯靠运气的排查。
 */
function readLevel(raw, fallback = 1) {
  if (raw === undefined || raw === null || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || !LEVELS.includes(n)) {
    throw ApiError.badRequest('bad_level', '公告级别只能是 1、2、3、4');
  }
  return n;
}

/**
 * 发布时间：接受 ISO 字符串或 `YYYY-MM-DDTHH:mm` / `YYYY-MM-DD HH:mm`。
 *
 * 空值 = 现在（「马上发」是默认动作）。
 * 无效值直接报错，**不静默回退成现在** —— 那会让「填了 2027 年」变成
 * 「立刻发出去」，是最糟糕的失败方式。
 */
function readPublishedAt(raw) {
  if (raw === undefined || raw === null || String(raw).trim() === '') {
    return nowSql();
  }
  // `new Date('2026-11-15T09:30')` 按**服务器本地时区**解析 ——
  // 面板浏览器和服务端通常不同时区，所以前端已经把本地时间转成带 Z 的
  // ISO 再发上来；这里兼容一下没带时区的写法（当 UTC 处理），
  // 免得一个手写的 cURL 请求把公告发到 8 小时之后。
  const text = String(raw).trim().replace(' ', 'T');
  const hasZone = /(Z|[+-]\d{2}:?\d{2})$/i.test(text);
  const date = new Date(hasZone ? text : `${text}Z`);
  if (Number.isNaN(date.getTime())) {
    throw ApiError.badRequest('bad_time', '发布时间无法解析');
  }
  return toSqlTime(date);
}

announcementsRouter.get(
  '/api/announcements',
  wrap(async (_req, res) => {
    const rows = await query(
      `SELECT id, title, content, level, published_at, created_at, updated_at
         FROM announcements
        ORDER BY published_at DESC, id DESC
        LIMIT 200`,
    );
    sendOk(res, { announcements: rows.map(toDto) });
  }),
);

announcementsRouter.post(
  '/api/announcements',
  wrap(async (req, res) => {
    const title = readTitle(req.body?.title);
    const content = readContent(req.body?.content);
    const level = readLevel(req.body?.level, 1);
    const publishedAt = readPublishedAt(req.body?.publishedAt);

    const result = await execute(
      `INSERT INTO announcements (title, content, level, published_at)
       VALUES (?, ?, ?, ?)`,
      [title, content, level, publishedAt],
    );
    const row = await queryOne('SELECT * FROM announcements WHERE id = ?', [
      result.insertId,
    ]);
    sendOk(res, { announcement: toDto(row) });
  }),
);

announcementsRouter.put(
  '/api/announcements/:id',
  wrap(async (req, res) => {
    const id = idParam(req);
    const row = await queryOne('SELECT id FROM announcements WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这条公告');

    const sets = [];
    const params = [];
    if (req.body?.title !== undefined) {
      sets.push('title = ?');
      params.push(readTitle(req.body.title));
    }
    if (req.body?.content !== undefined) {
      sets.push('content = ?');
      params.push(readContent(req.body.content));
    }
    if (req.body?.level !== undefined) {
      sets.push('level = ?');
      params.push(readLevel(req.body.level));
    }
    if (req.body?.publishedAt !== undefined) {
      sets.push('published_at = ?');
      params.push(readPublishedAt(req.body.publishedAt));
    }
    if (sets.length === 0) throw ApiError.badRequest('no_changes', '没有要修改的字段');

    params.push(id);
    await execute(`UPDATE announcements SET ${sets.join(', ')} WHERE id = ?`, params);

    const updated = await queryOne('SELECT * FROM announcements WHERE id = ?', [id]);
    sendOk(res, { announcement: toDto(updated) });
  }),
);

announcementsRouter.delete(
  '/api/announcements/:id',
  wrap(async (req, res) => {
    const id = idParam(req);
    const row = await queryOne('SELECT id FROM announcements WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这条公告');
    await execute('DELETE FROM announcements WHERE id = ?', [id]);
    sendOk(res, { id, deleted: true });
  }),
);

/** 面板概览里显示「公告 12 条（3 条待发布）」用 */
export async function announcementStats() {
  const row = await queryOne(
    `SELECT COUNT(*) AS total,
            SUM(CASE WHEN published_at > UTC_TIMESTAMP(3) THEN 1 ELSE 0 END) AS pending,
            SUM(CASE WHEN level >= 3 THEN 1 ELSE 0 END) AS loud
       FROM announcements`,
  );
  return {
    total: Number(row?.total ?? 0),
    pending: Number(row?.pending ?? 0),
    // 会弹窗的条数（级别 3 / 4）。概览里单独提一句：
    // 「12 条公告」听起来无害，但其中 8 条每次启动都弹的话就是另一回事了。
    loud: Number(row?.loud ?? 0),
  };
}

// server/src/admin/announcements.js
//
// 面板的「公告」页：增删改查。
//
// 只要三样东西：标题、内容、发布时间。发布时间**可改** ——
// 运营最常见的两个动作是「写错日期了」和「这条提前发」，
// 若只能在创建时设一次，就得删了重建（id 会变，客户端已经显示过的记录就对不上了）。
//
// 与公开接口的区别：这里**不过滤** published_at，
// 未来时间的公告也要能看到并修改，否则「定时发布」的稿子在发出前就消失了。

import { Router } from 'express';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { nowSql, sqlToIso, toSqlTime } from '../lib/sql_time.js';

export const announcementsRouter = Router();

const TITLE_MAX = 200;
const CONTENT_MAX = 20000;

function toDto(row) {
  const publishedAt = sqlToIso(row.published_at);
  return {
    id: Number(row.id),
    title: row.title,
    content: row.content,
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
      `SELECT id, title, content, published_at, created_at, updated_at
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
    const publishedAt = readPublishedAt(req.body?.publishedAt);

    const result = await execute(
      `INSERT INTO announcements (title, content, published_at)
       VALUES (?, ?, ?)`,
      [title, content, publishedAt],
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
            SUM(CASE WHEN published_at > UTC_TIMESTAMP(3) THEN 1 ELSE 0 END) AS pending
       FROM announcements`,
  );
  return {
    total: Number(row?.total ?? 0),
    pending: Number(row?.pending ?? 0),
  };
}

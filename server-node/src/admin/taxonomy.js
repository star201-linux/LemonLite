// server/src/admin/taxonomy.js
//
// 分类与标签（面板里的「分类标签」页）。
//
// 几个刻意的规则：
//   * **分类自带 id**（VARCHAR），因为它出现在 URL 里（?category=tools）。
//     中文名转不出 id 时用随机 `cat_xxxxxxxx`，而不是把中文塞进 URL。
//   * 删除默认**拒绝**：分类/标签还在被应用使用时，先告诉你有几个应用在用，
//     确认后才带 ?force=1 再删。面板上一个误点就清空整类应用，代价太大。
//   * 标签的 slug 唯一，改名不影响 slug（旧的分享链接不会突然失效）。

import { Router } from 'express';
import { execute, query, queryOne, transaction } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { isValidId, randomId, slugify } from '../lib/slug.js';
import { intIn } from './shared.js';

export const taxonomyRouter = Router();

const MAX_CATEGORIES = 64;
const MAX_TAGS = 200;

// ================================================================ 查询

/**
 * 一个分类下有几个应用（不含已下架）。
 *
 * 要同时看两处：apps.category_id（主分类）与 app_categories（多分类）。
 * 只看其中一处，升级上来的数据或新写入的数据总有一边会漏。
 */
async function categoryAppCount(id) {
  const row = await queryOne(
    `SELECT COUNT(*) AS n FROM apps a
      WHERE a.deleted_at IS NULL
        AND (a.category_id = ?
             OR EXISTS (SELECT 1 FROM app_categories ac
                         WHERE ac.app_id = a.id AND ac.category_id = ?))`,
    [id, id],
  );
  return Number(row?.n ?? 0);
}

async function tagAppCount(id) {
  const row = await queryOne(
    `SELECT COUNT(*) AS n FROM app_tags at
       JOIN apps a ON a.id = at.app_id
      WHERE at.tag_id = ? AND a.deleted_at IS NULL`,
    [id],
  );
  return Number(row?.n ?? 0);
}

async function categoryExists(id) {
  const row = await queryOne('SELECT id FROM categories WHERE id = ? LIMIT 1', [id]);
  return Boolean(row);
}

async function categoryNameTaken(name, exceptId = null) {
  const row = await queryOne(
    'SELECT id FROM categories WHERE name = ? AND id <> ? LIMIT 1',
    [name, exceptId ?? ''],
  );
  return Boolean(row);
}

async function tagNameTaken(name, exceptId = 0) {
  const row = await queryOne(
    'SELECT id FROM tags WHERE name = ? AND id <> ? LIMIT 1',
    [name, exceptId],
  );
  return Boolean(row);
}

async function tagSlugTaken(slug, exceptId = 0) {
  const row = await queryOne(
    'SELECT id FROM tags WHERE slug = ? AND id <> ? LIMIT 1',
    [slug, exceptId],
  );
  return Boolean(row);
}

/** 分类 id：优先用名字的 ASCII slug，转不出来（中文等）就用随机 id */
async function nextCategoryId(name) {
  const slug = slugify(name);
  if (slug && isValidId(slug) && !(await categoryExists(slug))) return slug;
  for (let i = 0; i < 5; i += 1) {
    const id = randomId('cat');
    if (!(await categoryExists(id))) return id;
  }
  throw new ApiError(500, 'id_failed', '生成分类 id 失败，请重试');
}

async function nextTagSlug(name) {
  const slug = slugify(name);
  if (slug && isValidId(slug) && !(await tagSlugTaken(slug))) return slug;
  for (let i = 0; i < 5; i += 1) {
    const candidate = randomId('tag');
    if (!(await tagSlugTaken(candidate))) return candidate;
  }
  throw new ApiError(500, 'id_failed', '生成标签 slug 失败，请重试');
}

// ================================================================ 读取

/** 分类 + 标签 + 每个分类/标签下的应用数（面板下拉与列表都用这一份） */
taxonomyRouter.get(
  '/api/meta',
  wrap(async (_req, res) => {
    const categories = await query(
      `SELECT c.id, c.name, c.sort_order,
              (SELECT COUNT(*) FROM apps a
                WHERE a.deleted_at IS NULL
                  AND (a.category_id = c.id
                       OR EXISTS (SELECT 1 FROM app_categories ac
                                   WHERE ac.app_id = a.id AND ac.category_id = c.id)))
                AS app_count
         FROM categories c
        ORDER BY c.sort_order ASC, c.id ASC`,
    );
    const tags = await query(
      `SELECT t.id, t.name, t.slug,
              (SELECT COUNT(*) FROM app_tags at
                 JOIN apps a ON a.id = at.app_id
                WHERE at.tag_id = t.id AND a.deleted_at IS NULL) AS app_count
         FROM tags t
        ORDER BY t.name ASC`,
    );
    sendOk(res, {
      categories: categories.map((c) => ({
        id: c.id,
        name: c.name,
        sortOrder: Number(c.sort_order) || 0,
        appCount: Number(c.app_count) || 0,
      })),
      tags: tags.map((t) => ({
        id: Number(t.id),
        name: t.name,
        slug: t.slug,
        appCount: Number(t.app_count) || 0,
      })),
    });
  }),
);

// ================================================================ 分类

taxonomyRouter.post(
  '/api/categories',
  wrap(async (req, res) => {
    const body = req.body ?? {};
    const name = String(body.name ?? '').trim();
    if (!name) throw ApiError.badRequest('missing_name', '分类名不能为空');
    if (name.length > 64) throw ApiError.badRequest('bad_name', '分类名最多 64 个字符');

    const total = await queryOne('SELECT COUNT(*) AS n FROM categories');
    if (Number(total?.n ?? 0) >= MAX_CATEGORIES) {
      throw ApiError.badRequest('too_many', `分类最多 ${MAX_CATEGORIES} 个`);
    }
    if (await categoryNameTaken(name)) {
      throw ApiError.conflict('category_exists', '这个分类名已经存在');
    }

    let id = String(body.id ?? '').trim().toLowerCase();
    if (id) {
      if (!isValidId(id)) {
        throw ApiError.badRequest(
          'bad_id',
          '分类 id 只能用小写字母、数字、下划线、连字符，且以字母或数字开头',
        );
      }
      if (await categoryExists(id)) {
        throw ApiError.conflict('category_id_exists', '这个分类 id 已经被占用了');
      }
    } else {
      id = await nextCategoryId(name);
    }

    let sortOrder;
    if (body.sortOrder !== undefined) {
      sortOrder = intIn(body.sortOrder, 0, -100000, 100000);
    } else {
      const row = await queryOne('SELECT COALESCE(MAX(sort_order), 0) AS m FROM categories');
      sortOrder = Number(row?.m ?? 0) + 10;
    }

    await execute('INSERT INTO categories (id, name, sort_order) VALUES (?, ?, ?)', [
      id,
      name,
      sortOrder,
    ]);
    sendOk(res, { category: { id, name, sortOrder, appCount: 0 } });
  }),
);

/** 批量排序：面板上「上移/下移」直接提交整串 id，服务端按顺序重排 */
taxonomyRouter.put(
  '/api/categories/order',
  wrap(async (req, res) => {
    const ids = Array.isArray(req.body?.ids) ? req.body.ids.map((x) => String(x)) : null;
    if (!ids || ids.length === 0) {
      throw ApiError.badRequest('bad_order', '需要 ids 数组');
    }
    if (ids.length > MAX_CATEGORIES) {
      throw ApiError.badRequest('bad_order', '分类数量超出上限');
    }
    await transaction(async (conn) => {
      for (let i = 0; i < ids.length; i += 1) {
        await conn.query('UPDATE categories SET sort_order = ? WHERE id = ?', [i * 10, ids[i]]);
      }
    });
    sendOk(res, { ordered: ids.length });
  }),
);

taxonomyRouter.put(
  '/api/categories/:id',
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '');
    const current = await queryOne('SELECT id, name FROM categories WHERE id = ?', [id]);
    if (!current) throw ApiError.notFound('没有这个分类');

    const body = req.body ?? {};
    const name = body.name !== undefined ? String(body.name).trim() : current.name;
    if (!name) throw ApiError.badRequest('missing_name', '分类名不能为空');
    if (name.length > 64) throw ApiError.badRequest('bad_name', '分类名最多 64 个字符');
    if (name !== current.name && (await categoryNameTaken(name, id))) {
      throw ApiError.conflict('category_exists', '这个分类名已经存在');
    }

    if (body.sortOrder !== undefined) {
      await execute('UPDATE categories SET name = ?, sort_order = ? WHERE id = ?', [
        name,
        intIn(body.sortOrder, 0, -100000, 100000),
        id,
      ]);
    } else {
      await execute('UPDATE categories SET name = ? WHERE id = ?', [name, id]);
    }
    const row = await queryOne('SELECT id, name, sort_order FROM categories WHERE id = ?', [id]);
    sendOk(res, {
      category: { id: row.id, name: row.name, sortOrder: Number(row.sort_order) || 0 },
    });
  }),
);

taxonomyRouter.delete(
  '/api/categories/:id',
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '');
    if (!(await categoryExists(id))) throw ApiError.notFound('没有这个分类');

    const used = await categoryAppCount(id);
    if (used > 0 && req.query.force !== '1') {
      throw new ApiError(
        409,
        'category_in_use',
        `还有 ${used} 个应用挂在这个分类下。删除后它们会变成「未分类」，确认删除？`,
        { appCount: used },
      );
    }

    await transaction(async (conn) => {
      // 先给「主分类」是它的应用找个替补，避免删完直接变未分类
      const [apps] = await conn.query('SELECT id FROM apps WHERE category_id = ?', [id]);
      for (const app of apps) {
        const [others] = await conn.query(
          `SELECT category_id FROM app_categories
            WHERE app_id = ? AND category_id <> ? ORDER BY category_id LIMIT 1`,
          [app.id, id],
        );
        await conn.query('UPDATE apps SET category_id = ? WHERE id = ?', [
          others[0]?.category_id ?? null,
          app.id,
        ]);
      }
      // 关联表靠外键级联清理
      await conn.query('DELETE FROM categories WHERE id = ?', [id]);
    });
    sendOk(res, { id, deleted: true, appCount: used });
  }),
);

// ================================================================ 标签

taxonomyRouter.post(
  '/api/tags',
  wrap(async (req, res) => {
    const body = req.body ?? {};
    const name = String(body.name ?? '').trim();
    if (!name) throw ApiError.badRequest('missing_name', '标签名不能为空');
    if (name.length > 32) throw ApiError.badRequest('bad_name', '标签名最多 32 个字符');

    const total = await queryOne('SELECT COUNT(*) AS n FROM tags');
    if (Number(total?.n ?? 0) >= MAX_TAGS) {
      throw ApiError.badRequest('too_many', `标签最多 ${MAX_TAGS} 个`);
    }
    if (await tagNameTaken(name)) throw ApiError.conflict('tag_exists', '这个标签已经存在');

    let slug = String(body.slug ?? '').trim().toLowerCase();
    if (slug) {
      if (!isValidId(slug)) {
        throw ApiError.badRequest('bad_slug', '标签 slug 只能用小写字母、数字、下划线、连字符');
      }
      if (await tagSlugTaken(slug)) {
        throw ApiError.conflict('tag_slug_exists', '这个 slug 已经被占用了');
      }
    } else {
      slug = await nextTagSlug(name);
    }

    const result = await execute('INSERT INTO tags (name, slug) VALUES (?, ?)', [name, slug]);
    sendOk(res, { tag: { id: Number(result.insertId), name, slug, appCount: 0 } });
  }),
);

taxonomyRouter.put(
  '/api/tags/:id',
  wrap(async (req, res) => {
    const id = Number.parseInt(String(req.params.id ?? ''), 10);
    if (!Number.isSafeInteger(id) || id <= 0) throw ApiError.badRequest('bad_id', '标签 id 不合法');
    const current = await queryOne('SELECT id, name, slug FROM tags WHERE id = ?', [id]);
    if (!current) throw ApiError.notFound('没有这个标签');

    const body = req.body ?? {};
    const name = body.name !== undefined ? String(body.name).trim() : current.name;
    if (!name) throw ApiError.badRequest('missing_name', '标签名不能为空');
    if (name.length > 32) throw ApiError.badRequest('bad_name', '标签名最多 32 个字符');
    if (name !== current.name && (await tagNameTaken(name, id))) {
      throw ApiError.conflict('tag_exists', '这个标签已经存在');
    }

    await execute('UPDATE tags SET name = ? WHERE id = ?', [name, id]);
    sendOk(res, { tag: { id, name, slug: current.slug } });
  }),
);

taxonomyRouter.delete(
  '/api/tags/:id',
  wrap(async (req, res) => {
    const id = Number.parseInt(String(req.params.id ?? ''), 10);
    if (!Number.isSafeInteger(id) || id <= 0) throw ApiError.badRequest('bad_id', '标签 id 不合法');
    const current = await queryOne('SELECT id FROM tags WHERE id = ?', [id]);
    if (!current) throw ApiError.notFound('没有这个标签');

    const used = await tagAppCount(id);
    if (used > 0 && req.query.force !== '1') {
      throw new ApiError(
        409,
        'tag_in_use',
        `还有 ${used} 个应用带着这个标签。删除后标签会从这些应用上移除，确认删除？`,
        { appCount: used },
      );
    }
    await execute('DELETE FROM tags WHERE id = ?', [id]);
    sendOk(res, { id, deleted: true, appCount: used });
  }),
);

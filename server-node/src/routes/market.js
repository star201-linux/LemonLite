// server/src/routes/market.js
//
// 市场接口：两个。
//
//   GET /api/market/feed     主页推荐（按更新时间倒序，游标分页）
//   GET /api/market/search   搜索（关键词 + 标签筛选，返回命中的标签）
//
// 为什么拆成两个而不是一个 /apps?q=：
//   * 主页要的是「稳定、可无限下拉」的流，排序规则固定，适合游标分页；
//   * 搜索要的是「相关度 + 标签聚合」，还可能换排序，适合另一种分页方式。
//   合成一个接口的结果是两组语义相反的参数挤在同一个签名里，
//   客户端每次调用都要想「我现在是哪一种」。
//
// 分页为什么用**游标**而不是 offset：
//   应用列表会随时更新。offset 分页时，如果第 1 页之后有新应用插到最前面，
//   第 2 页会把第 1 页的最后几条**重复**返回一次（用户看到重复卡片）。
//   游标（上一页最后一条的 updated_at + id）不会出现这个问题。
//   代价是「不能跳到第 N 页」—— 但无限下拉本来就不需要跳页。

import { Router } from 'express';
import { query } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { config } from '../config.js';

export const marketRouter = Router();

/** 把一页条数夹到合法范围 */
function pageSize(raw) {
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n <= 0) return config.market.defaultPageSize;
  return Math.min(n, config.market.maxPageSize);
}

/** JSON 列在 mysql2 里可能已经是数组，也可能是字符串 */
function jsonArray(value) {
  if (Array.isArray(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    try {
      const parsed = JSON.parse(value);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }
  return [];
}

/**
 * 把 GROUP_CONCAT 出来的 `id\u0001name\u0002id\u0001name` 还原成
 * `[{id, name}]`。用两个不可见控制字符做分隔，应用名里不会出现它们。
 */
function parseCategoryPairs(value) {
  if (!value) return [];
  return String(value)
    .split('\u0002')
    .filter(Boolean)
    .map((pair) => {
      const [id, ...rest] = pair.split('\u0001');
      return { id, name: rest.join('\u0001') };
    })
    .filter((item) => item.id);
}

/**
 * 数据库行 → 客户端 AppItem 的字段名。
 *
 * 为什么要在服务端做这个映射而不是直接返回列名：
 * 客户端的数据模型（AppItem）是围绕 index.json 的字段设计的，
 * 保持字段名一致，客户端就不用为「服务端版本」再写一套解析。
 */
function toAppDto(row, origin = '') {
  // 包地址补成绝对地址：客户端要直接拿它去下载，没有 base 可拼。
  //
  // 两种情况：
  //   * 库里存的是完整 http(s) 地址（包放在 CDN / 别的机器上）→ 原样给它；
  //   * 存的是 packages/<appId>/<version>.zip 这种本机相对路径 → 走下载接口
  //     `/api/market/<appId>/package?version=<v>`。
  //     以前这里拼的是 `${origin}/packages/...`，但服务端**并没有**静态托管
  //     那个目录，结果就是「列表能看、一点开就 404」。走接口还能顺带得到
  //     ETag / Cache-Control，客户端也能复用缓存。
  const pkgUrl = row.package_url
    ? /^https?:\/\//i.test(row.package_url)
      ? row.package_url
      : `${origin}/api/market/${encodeURIComponent(row.id)}/package` +
        `?version=${encodeURIComponent(row.version)}`
    : '';

  // 多分类：category 仍是「主分类」（客户端详情页只认一个字段），
  // categories 是完整的归类列表。没有主分类时用列表第一个兜底 ——
  // 删掉主分类时外键会把它置空，这时列表里还有别的分类。
  const categories = parseCategoryPairs(row.category_pairs);
  const primaryCategoryId = row.category_id || categories[0]?.id || '';

  return {
    id: row.id,
    name: row.name,
    description: row.description,
    category: primaryCategoryId,
    categoryName:
      row.category_name ||
      categories.find((c) => c.id === primaryCategoryId)?.name ||
      '',
    categories,
    // version 是**包的版本**：客户端拿它跟本地已装的版本比，决定要不要升级
    version: row.version,
    author: row.author,

    // ---- 小程序包（0.6 起客户端只认这个，不再用远程网页）----
    // packageUrl 为空表示这个条目还没上架包，客户端显示「暂不可用」
    packageUrl: pkgUrl,
    packageEntry: row.package_entry || 'index.html',
    packageSha256: row.package_sha256 ?? '',
    packageBytes: Number(row.package_bytes) || 0,

    icon: row.icon ?? '',
    homepage: row.homepage ?? '',
    // size 是包体积（客户端详情页显示「安装包 2.3 MB」）
    size: Number(row.package_bytes) || Number(row.size_bytes) || 0,
    screenshots: jsonArray(row.screenshots),
    permissions: jsonArray(row.permissions),
    updatedAt: row.updated_at,
    publishedAt: row.published_at,
    // 标签以数组返回：客户端卡片上要显示，搜索时也用它做筛选项
    tags: row.tag_names ? String(row.tag_names).split('\u0001').filter(Boolean) : [],
  };
}

/** 请求的服务根地址（用于把相对包路径补成绝对） */
function originOf(req) {
  const proto = req.get('x-forwarded-proto') || req.protocol || 'http';
  const host = req.get('x-forwarded-host') || req.get('host');
  return host ? `${proto}://${host}` : '';
}

/**
 * 游标编解码。
 *
 * 格式 `<sort_weight>_<updated_at>_<id>` 的 base64url。
 * 用 base64 而不是明文，是为了让客户端**不要**尝试理解它 ——
 * 它是不透明令牌，将来改排序规则时不需要改客户端。
 */
function encodeCursor(row) {
  const raw = `${row.sort_weight}|${row.updated_at}|${row.id}`;
  return Buffer.from(raw, 'utf8').toString('base64url');
}

function decodeCursor(cursor) {
  if (!cursor) return null;
  try {
    const raw = Buffer.from(cursor, 'base64url').toString('utf8');
    const parts = raw.split('|');
    if (parts.length !== 3) throw new Error('bad parts');
    const [weightStr, updatedAt, id] = parts;
    const weight = Number.parseInt(weightStr, 10);
    if (!Number.isFinite(weight) || !id) throw new Error('bad weight');
    return { weight, updatedAt, id };
  } catch {
    // 游标坏了不该 500：当作「从第一页开始」，用户最多多点一次刷新
    return null;
  }
}

// ================================================================ 1. 主页推荐

/**
 * GET /api/market/feed?limit=20&cursor=xxx&category=tools
 *
 * 返回：
 * {
 *   ok: true,
 *   data: { apps: [...], categories: [...] },
 *   meta: { nextCursor: "..." | null, hasMore: bool, limit: n }
 * }
 *
 * 排序：sort_weight DESC, updated_at DESC, id ASC
 *   「按更新时间返回」是需求原话；sort_weight 是给运营留的人工置顶位，
 *   默认 0，所以默认行为就是纯按更新时间。
 *   加上 id 是为了**稳定**：updated_at 相同（同一次批量导入）时，
 *   没有第三个字段的话 MySQL 每次返回的顺序可能不一样，游标就会漏条目。
 */
marketRouter.get(
  '/feed',
  wrap(async (req, res) => {
    const limit = pageSize(req.query.limit);
    const cursor = decodeCursor(req.query.cursor);
    const category = String(req.query.category || '').trim();

    const where = ['a.deleted_at IS NULL'];
    const params = [];

    if (category && category !== 'all') {
      // 多分类：主分类命中，或者关联表里任意一个分类命中，都算这个应用
      where.push(
        `(a.category_id = ? OR EXISTS (
            SELECT 1 FROM app_categories ac
             WHERE ac.app_id = a.id AND ac.category_id = ?
         ))`,
      );
      params.push(category, category);
    }

    if (cursor) {
      // 游标条件必须与 ORDER BY **严格对应**，否则会漏/重。
      // 三元组比较：(w, t, id) < (w0, t0, id0) 的展开写法。
      where.push(
        `(
           a.sort_weight < ?
           OR (a.sort_weight = ? AND a.updated_at < ?)
           OR (a.sort_weight = ? AND a.updated_at = ? AND a.id > ?)
         )`,
      );
      params.push(
        cursor.weight,
        cursor.weight,
        cursor.updatedAt,
        cursor.weight,
        cursor.updatedAt,
        cursor.id,
      );
    }

    // 多取一条用来判断 hasMore，少一次 COUNT 查询
    const rows = await query(
      `SELECT a.*, c.name AS category_name,
              GROUP_CONCAT(DISTINCT t.name ORDER BY t.name SEPARATOR '\u0001') AS tag_names,
              (SELECT GROUP_CONCAT(CONCAT(c2.id, '\u0001', c2.name)
                                   ORDER BY c2.sort_order, c2.id SEPARATOR '\u0002')
                 FROM app_categories ac JOIN categories c2 ON c2.id = ac.category_id
                WHERE ac.app_id = a.id) AS category_pairs
         FROM apps a
         LEFT JOIN categories c ON c.id = a.category_id
         LEFT JOIN app_tags at ON at.app_id = a.id
         LEFT JOIN tags t ON t.id = at.tag_id
        WHERE ${where.join(' AND ')}
        GROUP BY a.id
        ORDER BY a.sort_weight DESC, a.updated_at DESC, a.id ASC
        LIMIT ?`,
      [...params, limit + 1],
    );

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    const last = page[page.length - 1];

    // 分类列表只在第一页返回（下拉刷新时不需要重复传，省流量）
    let categories = [];
    if (!cursor) {
      // 计数同时看主分类与关联表：只 join 其中一个，多分类的计数就会偏小
      categories = await query(
        `SELECT c.id, c.name,
                (SELECT COUNT(*) FROM apps a
                  WHERE a.deleted_at IS NULL
                    AND (a.category_id = c.id
                         OR EXISTS (SELECT 1 FROM app_categories ac
                                     WHERE ac.app_id = a.id AND ac.category_id = c.id)))
                  AS app_count
           FROM categories c
          ORDER BY c.sort_order ASC, c.id ASC`,
      );
    }

    sendOk(
      res,
      { apps: page.map((r) => toAppDto(r, originOf(req))), categories },
      {
        hasMore,
        nextCursor: hasMore && last ? encodeCursor(last) : null,
        limit,
        sort: 'updated_at_desc',
      },
    );
  }),
);

// ================================================================ 2. 搜索

/**
 * GET /api/market/search?q=记事&tag=效率&limit=20&offset=0
 *
 * 返回：
 * {
 *   ok: true,
 *   data: {
 *     apps: [...],
 *     // 命中的标签（用于搜索页上方的筛选 chip）
 *     tags: [{ name, slug, count }],
 *     total: n
 *   },
 *   meta: { limit, offset, hasMore }
 * }
 *
 * 为什么搜索用 offset 而不是游标：
 *   搜索结果的数量级小（几十到几百条），offset 的性能问题不存在；
 *   而用户会想「跳到第 2 页看看」—— 游标做不到。这是一个刻意的例外。
 *
 * 为什么返回 tags：
 *   需求原文「把应用加一个标签，搜索时返回标签」。
 *   返回**命中结果里实际出现过的**标签（不是全量标签表），
 *   这样 chip 上不会出现「点了没结果」的标签。
 */
marketRouter.get(
  '/search',
  wrap(async (req, res) => {
    const limit = pageSize(req.query.limit);
    const offsetRaw = Number.parseInt(req.query.offset, 10);
    const offset = Number.isFinite(offsetRaw) && offsetRaw > 0 ? offsetRaw : 0;
    const keyword = String(req.query.q || '').trim();
    const tagSlug = String(req.query.tag || '').trim();
    const category = String(req.query.category || '').trim();

    const where = ['a.deleted_at IS NULL'];
    const params = [];

    if (keyword) {
      // 关键词匹配：名称 / 简介 / 作者 / 标签名。
      // 用 LIKE 而不是全文索引：中文分词需要 ngram parser，
      // 而这里的量级（几百条）LIKE 完全够用，且部署时零配置。
      // 真要上十万条再换 FULLTEXT + ngram。
      const like = `%${keyword}%`;
      where.push(
        `(a.name LIKE ? OR a.description LIKE ? OR a.author LIKE ?
          OR EXISTS (
            SELECT 1 FROM app_tags at2
              JOIN tags t2 ON t2.id = at2.tag_id
             WHERE at2.app_id = a.id AND t2.name LIKE ?
          ))`,
      );
      params.push(like, like, like, like);
    }

    if (tagSlug) {
      where.push(
        `EXISTS (
           SELECT 1 FROM app_tags at3
             JOIN tags t3 ON t3.id = at3.tag_id
            WHERE at3.app_id = a.id AND (t3.slug = ? OR t3.name = ?)
         )`,
      );
      params.push(tagSlug, tagSlug);
    }

    if (category && category !== 'all') {
      // 多分类：主分类命中，或者关联表里任意一个分类命中，都算这个应用
      where.push(
        `(a.category_id = ? OR EXISTS (
            SELECT 1 FROM app_categories ac
             WHERE ac.app_id = a.id AND ac.category_id = ?
         ))`,
      );
      params.push(category, category);
    }

    const whereSql = where.join(' AND ');

    // 总数：用于「共 N 个结果」与 hasMore
    const countRow = await query(
      `SELECT COUNT(*) AS n FROM apps a WHERE ${whereSql}`,
      params,
    );
    const total = Number(countRow[0]?.n) || 0;

    // 搜索结果里，关键词完全等于名称的排最前（最符合直觉的「精确优先」）
    const orderExtra = keyword ? 'CASE WHEN a.name = ? THEN 0 ELSE 1 END, ' : '';
    const orderParams = keyword ? [keyword] : [];

    const rows = await query(
      `SELECT a.*, c.name AS category_name,
              GROUP_CONCAT(DISTINCT t.name ORDER BY t.name SEPARATOR '\u0001') AS tag_names,
              (SELECT GROUP_CONCAT(CONCAT(c2.id, '\u0001', c2.name)
                                   ORDER BY c2.sort_order, c2.id SEPARATOR '\u0002')
                 FROM app_categories ac JOIN categories c2 ON c2.id = ac.category_id
                WHERE ac.app_id = a.id) AS category_pairs
         FROM apps a
         LEFT JOIN categories c ON c.id = a.category_id
         LEFT JOIN app_tags at ON at.app_id = a.id
         LEFT JOIN tags t ON t.id = at.tag_id
        WHERE ${whereSql}
        GROUP BY a.id
        ORDER BY ${orderExtra}a.sort_weight DESC, a.updated_at DESC, a.id ASC
        LIMIT ? OFFSET ?`,
      [...orderParams, ...params, limit, offset],
    );

    // 命中结果里的标签聚合：只统计这一批结果？
    // 不 —— 统计**全部命中结果**。否则用户翻到第 2 页时 chip 会变，
    // 人会觉得界面在乱跳。
    const tagRows = await query(
      `SELECT t.name, t.slug, COUNT(DISTINCT a.id) AS count
         FROM apps a
         JOIN app_tags at ON at.app_id = a.id
         JOIN tags t ON t.id = at.tag_id
        WHERE ${whereSql}
        GROUP BY t.id, t.name, t.slug
        ORDER BY count DESC, t.name ASC`,
      params,
    );

    sendOk(
      res,
      {
        apps: rows.map((r) => toAppDto(r, originOf(req))),
        tags: tagRows.map((r) => ({
          name: r.name,
          slug: r.slug,
          count: Number(r.count) || 0,
        })),
        total,
        // 回显查询条件，方便客户端做「这次结果对应哪个关键词」的判断，
        // 避免快速输入时旧响应覆盖新响应
        query: { q: keyword, tag: tagSlug, category },
      },
      { limit, offset, hasMore: offset + rows.length < total },
    );
  }),
);

/**
 * GET /api/market/app/:id
 *
 * 单个应用详情。列表里已经带了完整字段，但详情页可能被直接打开
 * （例如从分享链接），所以要有这个接口。
 */
marketRouter.get(
  '/app/:id',
  wrap(async (req, res) => {
    const id = String(req.params.id || '').trim();
    if (!id) throw ApiError.badRequest('bad_request', '缺少应用 id');

    const rows = await query(
      `SELECT a.*, c.name AS category_name,
              GROUP_CONCAT(DISTINCT t.name ORDER BY t.name SEPARATOR '\u0001') AS tag_names,
              (SELECT GROUP_CONCAT(CONCAT(c2.id, '\u0001', c2.name)
                                   ORDER BY c2.sort_order, c2.id SEPARATOR '\u0002')
                 FROM app_categories ac JOIN categories c2 ON c2.id = ac.category_id
                WHERE ac.app_id = a.id) AS category_pairs
         FROM apps a
         LEFT JOIN categories c ON c.id = a.category_id
         LEFT JOIN app_tags at ON at.app_id = a.id
         LEFT JOIN tags t ON t.id = at.tag_id
        WHERE a.id = ? AND a.deleted_at IS NULL
        GROUP BY a.id`,
      [id],
    );
    if (rows.length === 0) throw ApiError.notFound('没有这个应用');

    sendOk(res, toAppDto(rows[0], originOf(req)));
  }),
);

/**
 * GET /api/market/tags
 *
 * 全量标签 + 每个标签下的应用数。搜索页初始状态用到。
 */
marketRouter.get(
  '/tags',
  wrap(async (_req, res) => {
    const rows = await query(
      `SELECT t.name, t.slug, COUNT(DISTINCT a.id) AS count
         FROM tags t
         LEFT JOIN app_tags at ON at.tag_id = t.id
         LEFT JOIN apps a ON a.id = at.app_id AND a.deleted_at IS NULL
        GROUP BY t.id, t.name, t.slug
        HAVING count > 0
        ORDER BY count DESC, t.name ASC`,
    );
    sendOk(
      res,
      rows.map((r) => ({ name: r.name, slug: r.slug, count: Number(r.count) || 0 })),
    );
  }),
);

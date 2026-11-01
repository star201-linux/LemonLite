// server/src/admin/apps.js
//
// 面板的「应用」页：增删改、上下架、传包。
//
// 和旧版最大的区别是**多分类**：
//   apps.category_id 保留为「主分类」（客户端详情页只认一个），
//   app_categories 才是完整的归类关系。写入时两处一起改，读取时
//   以关联表为准、主分类做兜底 —— 只维护一处的话，升级上来的数据
//   或者旧客户端读到的分类总有一边是错的。

import { Router } from 'express';
import multer from 'multer';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { listPackages, removePackage, storePackage } from '../lib/package_store.js';
import { APP_ID_RE, VERSION_RE, intIn, parseCategoryPairs, parseJsonArray } from './shared.js';

export const appsRouter = Router();

/** 上传 zip 用内存存储：小程序包上限 20MB，落盘前先在内存里校验魔数与哈希 */
const uploadZip = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 20 * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (!/\.zip$/i.test(file.originalname)) {
      return cb(ApiError.badRequest('bad_package', '小程序包必须是 .zip'));
    }
    return cb(null, true);
  },
});

const MAX_CATEGORIES_PER_APP = 8;

// ================================================================ 读

/** 应用行 → 面板对象。分类既有数组（完整）也保留主分类（兼容旧界面习惯）。 */
function appToDto(row) {
  const categories = parseCategoryPairs(row.category_pairs);
  const primaryId = row.category_id || categories[0]?.id || '';
  const primaryName =
    row.category_name || categories.find((c) => c.id === primaryId)?.name || '';
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    categoryId: primaryId,
    categoryName: primaryName,
    // 完整分类：编辑器用它回填多选框
    categories,
    categoryIds: categories.map((c) => c.id),
    version: row.version,
    author: row.author,
    packageUrl: row.package_url ?? '',
    packageEntry: row.package_entry ?? 'index.html',
    packageSha256: row.package_sha256 ?? '',
    packageBytes: Number(row.package_bytes) || 0,
    icon: row.icon ?? '',
    homepage: row.homepage ?? '',
    screenshots: parseJsonArray(row.screenshots),
    permissions: parseJsonArray(row.permissions),
    tagNames: row.tag_names ? String(row.tag_names).split(',') : [],
    sortWeight: Number(row.sort_weight) || 0,
    publishedAt: row.published_at,
    updatedAt: row.updated_at,
    deleted: Boolean(row.deleted_at),
    deletedAt: row.deleted_at ?? '',
  };
}

/** 分类名 + 标签名 + 多分类，一次查完。
 *  新建/保存后的响应必须和列表同一个口径，否则前端会以为没存上。 */
const APP_SELECT = `
  SELECT a.*, c.name AS category_name,
         (SELECT GROUP_CONCAT(t.name ORDER BY t.name)
            FROM app_tags at JOIN tags t ON t.id = at.tag_id
           WHERE at.app_id = a.id) AS tag_names,
         (SELECT GROUP_CONCAT(CONCAT(c2.id, '\u0001', c2.name)
                              ORDER BY c2.sort_order, c2.id SEPARATOR '\u0002')
            FROM app_categories ac JOIN categories c2 ON c2.id = ac.category_id
           WHERE ac.app_id = a.id) AS category_pairs
    FROM apps a
    LEFT JOIN categories c ON c.id = a.category_id`;

function fetchAppRow(id) {
  return queryOne(`${APP_SELECT} WHERE a.id = ?`, [id]);
}

// ================================================================ 写

/** 从请求体取应用字段（新建与编辑共用） */
function readAppFields(body, { creating }) {
  const id = String(body.id ?? '').trim();
  const name = String(body.name ?? '').trim();
  if (!name) throw ApiError.badRequest('missing_name', '应用名称不能为空');
  if (name.length > 128) throw ApiError.badRequest('bad_name', '应用名称最多 128 个字符');

  const version = String(body.version ?? '1.0.0').trim() || '1.0.0';
  if (!VERSION_RE.test(version)) {
    throw ApiError.badRequest('bad_version', '版本号只能包含字母、数字、点、加号和连字符');
  }

  const entry = String(body.packageEntry ?? 'index.html').trim() || 'index.html';
  if (entry.startsWith('/') || entry.includes('..')) {
    throw ApiError.badRequest('bad_entry', '入口必须是包内的相对路径');
  }

  if (creating && !APP_ID_RE.test(id)) {
    throw ApiError.badRequest(
      'bad_id',
      '应用 id 只能包含字母、数字、下划线、点和连字符，且以字母或数字开头',
    );
  }

  // 新字段 categoryIds 是数组；旧的 categoryId 仍接受（客户端/脚本兼容）
  const rawCategoryIds = Array.isArray(body.categoryIds)
    ? body.categoryIds
    : body.categoryId
      ? [body.categoryId]
      : [];
  const categoryIds = [];
  for (const raw of rawCategoryIds) {
    const cid = String(raw ?? '').trim();
    if (cid && !categoryIds.includes(cid)) categoryIds.push(cid);
  }
  if (categoryIds.length > MAX_CATEGORIES_PER_APP) {
    throw ApiError.badRequest('too_many_categories', `一个应用最多挂 ${MAX_CATEGORIES_PER_APP} 个分类`);
  }

  return {
    id,
    name,
    description: String(body.description ?? '').trim(),
    categoryIds,
    version,
    author: String(body.author ?? '').trim(),
    packageEntry: entry,
    icon: String(body.icon ?? '').trim(),
    homepage: String(body.homepage ?? '').trim(),
    screenshots: Array.isArray(body.screenshots)
      ? body.screenshots.map((x) => String(x).trim()).filter(Boolean).slice(0, 12)
      : [],
    permissions: Array.isArray(body.permissions)
      ? body.permissions.map((x) => String(x).trim()).filter(Boolean).slice(0, 32)
      : [],
    sortWeight: intIn(body.sortWeight, 0, -100000, 100000),
  };
}

/** 分类 id 必须都存在（不自动建分类：拼错一个字母就多一个分类，很难收拾） */
async function ensureCategoriesExist(ids) {
  if (!ids.length) return;
  const rows = await query(
    `SELECT id FROM categories WHERE id IN (${ids.map(() => '?').join(',')})`,
    ids,
  );
  const found = new Set(rows.map((r) => r.id));
  const missing = ids.filter((id) => !found.has(id));
  if (missing.length > 0) {
    throw ApiError.badRequest('bad_category', `分类不存在：${missing.join('、')}`);
  }
}

/** 重建 app ↔ category（同时维护 apps.category_id 这个「主分类」） */
async function replaceAppCategories(appId, categoryIds) {
  await execute('DELETE FROM app_categories WHERE app_id = ?', [appId]);
  for (const cid of categoryIds) {
    await execute('INSERT IGNORE INTO app_categories (app_id, category_id) VALUES (?, ?)', [
      appId,
      cid,
    ]);
  }
  await execute('UPDATE apps SET category_id = ? WHERE id = ?', [categoryIds[0] ?? null, appId]);
}

/** 重建 app ↔ tag（未知标签名直接忽略，不自动建标签） */
async function replaceAppTags(appId, tagNames) {
  await execute('DELETE FROM app_tags WHERE app_id = ?', [appId]);
  if (!tagNames?.length) return;
  const names = tagNames.map((x) => String(x).trim()).filter(Boolean);
  if (!names.length) return;
  const rows = await query(
    `SELECT id FROM tags WHERE name IN (${names.map(() => '?').join(',')})`,
    names,
  );
  for (const row of rows) {
    await execute('INSERT IGNORE INTO app_tags (app_id, tag_id) VALUES (?, ?)', [appId, row.id]);
  }
}

// ================================================================ 列表 / 新建 / 编辑

appsRouter.get(
  '/api/apps',
  wrap(async (req, res) => {
    const q = String(req.query.q ?? '').trim();
    const like = `%${q}%`;
    const rows = await query(
      `${APP_SELECT}
        WHERE (? = '' OR a.id LIKE ? OR a.name LIKE ?)
        ORDER BY a.sort_weight DESC, a.updated_at DESC
        LIMIT 200`,
      [q, like, like],
    );
    sendOk(res, { apps: rows.map(appToDto) });
  }),
);

appsRouter.post(
  '/api/apps',
  wrap(async (req, res) => {
    const fields = readAppFields(req.body ?? {}, { creating: true });
    const exists = await queryOne('SELECT id FROM apps WHERE id = ? LIMIT 1', [fields.id]);
    if (exists) throw ApiError.conflict('app_exists', '这个 id 已经被占用了');
    await ensureCategoriesExist(fields.categoryIds);

    await execute(
      `INSERT INTO apps
         (id, name, description, category_id, version, author,
          package_entry, icon, homepage, screenshots, permissions, sort_weight)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        fields.id,
        fields.name,
        fields.description,
        fields.categoryIds[0] ?? null,
        fields.version,
        fields.author,
        fields.packageEntry,
        fields.icon || null,
        fields.homepage || null,
        JSON.stringify(fields.screenshots),
        JSON.stringify(fields.permissions),
        fields.sortWeight,
      ],
    );
    await replaceAppCategories(fields.id, fields.categoryIds);
    await replaceAppTags(fields.id, req.body?.tagNames);

    sendOk(res, { app: appToDto(await fetchAppRow(fields.id)) });
  }),
);

appsRouter.put(
  '/api/apps/:id',
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const current = await queryOne('SELECT * FROM apps WHERE id = ?', [id]);
    if (!current) throw ApiError.notFound('没有这个应用');

    // 单独支持「上架 / 下架」：只传 deleted 时不动其它字段
    if (req.body?.deleted !== undefined && Object.keys(req.body).length === 1) {
      await execute('UPDATE apps SET deleted_at = ? WHERE id = ?', [
        req.body.deleted ? new Date() : null,
        id,
      ]);
      return sendOk(res, { app: appToDto(await fetchAppRow(id)) });
    }

    const fields = readAppFields({ ...req.body, id }, { creating: false });
    await ensureCategoriesExist(fields.categoryIds);

    await execute(
      `UPDATE apps SET
         name = ?, description = ?, category_id = ?, version = ?, author = ?,
         package_entry = ?, icon = ?, homepage = ?, screenshots = ?,
         permissions = ?, sort_weight = ?
       WHERE id = ?`,
      [
        fields.name,
        fields.description,
        fields.categoryIds[0] ?? null,
        fields.version,
        fields.author,
        fields.packageEntry,
        fields.icon || null,
        fields.homepage || null,
        JSON.stringify(fields.screenshots),
        JSON.stringify(fields.permissions),
        fields.sortWeight,
        id,
      ],
    );
    await replaceAppCategories(id, fields.categoryIds);
    if (req.body?.tagNames !== undefined) {
      await replaceAppTags(id, req.body.tagNames);
    }

    sendOk(res, { app: appToDto(await fetchAppRow(id)) });
  }),
);

appsRouter.delete(
  '/api/apps/:id',
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const row = await queryOne('SELECT id FROM apps WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个应用');
    // 软删除：市场不再返回它，但数据还在，误删可以改回来
    await execute('UPDATE apps SET deleted_at = NOW(3) WHERE id = ?', [id]);
    sendOk(res, { deleted: true, restorable: true });
  }),
);

// ================================================================ 安装包

appsRouter.post(
  '/api/apps/:id/package',
  uploadZip.single('file'),
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const version = String(req.body?.version ?? '').trim();
    const entry = String(req.body?.entry ?? 'index.html').trim() || 'index.html';

    const app = await queryOne('SELECT id, version FROM apps WHERE id = ?', [id]);
    if (!app) throw ApiError.notFound('没有这个应用');
    if (!req.file?.buffer?.length) {
      throw ApiError.badRequest('no_file', '没有收到文件（字段名应为 file）');
    }
    if (!VERSION_RE.test(version)) {
      throw ApiError.badRequest('bad_version', '版本号只能包含字母、数字、点、加号和连字符');
    }
    if (entry.startsWith('/') || entry.includes('..')) {
      throw ApiError.badRequest('bad_entry', '入口必须是包内的相对路径');
    }

    const stored = await storePackage({ appId: id, version, buffer: req.file.buffer });

    // 版本号、包地址、入口、哈希、大小必须一次性写入：
    // 「版本变了但包没变」会让客户端一直提示升级却升不上去。
    await execute(
      `UPDATE apps
          SET version = ?, package_url = ?, package_entry = ?,
              package_sha256 = ?, package_bytes = ?
        WHERE id = ?`,
      [version, stored.relUrl, entry, stored.sha256, stored.bytes, id],
    );

    sendOk(res, {
      appId: id,
      version,
      entry,
      sha256: stored.sha256,
      bytes: stored.bytes,
      previousVersion: app.version,
    });
  }),
);

appsRouter.get(
  '/api/apps/:id/packages',
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    sendOk(res, { packages: await listPackages(id) });
  }),
);

appsRouter.delete(
  '/api/apps/:id/package/:version',
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const version = String(req.params.version ?? '').trim();
    const removed = await removePackage(id, version);
    // 删掉的正是当前上架版本时，把 apps 里的包字段清空（否则市场会指向不存在的文件）
    const app = await queryOne('SELECT version FROM apps WHERE id = ?', [id]);
    if (app && app.version === version) {
      await execute(
        `UPDATE apps
            SET package_url = NULL, package_sha256 = NULL, package_bytes = 0
          WHERE id = ?`,
        [id],
      );
    }
    sendOk(res, { removed });
  }),
);

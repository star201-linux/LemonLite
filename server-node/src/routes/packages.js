// server/src/routes/packages.js
//
// 小程序包的托管：上传 / 下载 / 版本检查。
//
// 为什么包由服务端托管而不是让作者自己放 CDN：
//   * 客户端要校验 SHA-256 才能保证「下载的和上架的是同一份」，
//     哈希必须有一个可信来源（服务端）；
//   * 版本号与包必须是原子的一体 —— 「版本号是 1.2.0 但包是 1.1.0」
//     这种错配由服务端在一个事务里写，客户端无从出错。
//
// 目录布局：
//   packages/<appId>/<version>.zip
// 用「appId/版本号」而不是用一个随机文件名，是为了：
//   * 保留历史版本，客户端回滚/多设备版本不一致时还能下载对应版本；
//   * 清理时按版本比大小很直观。

import { Router } from 'express';
import multer from 'multer';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { config } from '../config.js';
import { execute, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { currentUserId, requireAuth } from '../lib/auth.js';

export const packageRouter = Router();

/** 包上限。小程序是 HTML/JS/CSS，20MB 已经很宽松。 */
const MAX_PACKAGE_BYTES = 20 * 1024 * 1024;

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_PACKAGE_BYTES, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (!/\.zip$/i.test(file.originalname)) {
      return cb(ApiError.badRequest('bad_package', '小程序包必须是 .zip'));
    }
    return cb(null, true);
  },
});

/** packages/ 根目录 */
function packagesRoot() {
  return resolve(config.root, 'packages');
}

/**
 * 某个包的落盘路径。
 *
 * **越界校验在这里**：appId 与 version 都来自请求参数/数据库，
 * 但它们会被拼进文件路径 —— 一个 `../` 就能写到目录外。
 * 除了字符白名单，最后还要确认解析后的绝对路径仍在 packages/ 下。
 */
function packagePath(appId, version) {
  if (!/^[\w.-]{1,64}$/.test(appId)) {
    throw ApiError.badRequest('bad_app_id', 'appId 只能包含字母、数字、下划线、点和连字符');
  }
  if (!/^[\w.+-]{1,32}$/.test(version)) {
    throw ApiError.badRequest('bad_version', '版本号只能包含字母、数字、点、加号和连字符');
  }
  const root = packagesRoot();
  const dir = join(root, appId);
  const file = join(dir, `${version}.zip`);
  if (!file.startsWith(root + sep)) {
    throw ApiError.badRequest('bad_path', '路径不合法');
  }
  return { dir, file };
}

// ================================================================ 上传

/**
 * POST /api/market/:appId/package
 * multipart：file（zip）、version、entry?、sha256?
 *
 * 需要登录（先用管理员账号）。**没有做角色系统** —— 这个服务端假设
 * 「部署者只给自己用」，要开放给第三方上架需要另加权限模型。
 *
 * 服务端自己算 SHA-256（不信客户端传的），并把 apps 表里的
 * package_url / package_entry / package_sha256 / package_bytes / version
 * 一次性写进去 —— 五件事必须原子，否则「版本号变了但包没变」这类错配
 * 会让客户端反复提示升级却升不上去。
 */
packageRouter.post(
  '/:appId/package',
  requireAuth,
  upload.single('file'),
  wrap(async (req, res) => {
    const appId = String(req.params.appId || '').trim();
    const version = String(req.body?.version || '').trim();
    const entry = String(req.body?.entry || 'index.html').trim() || 'index.html';

    if (!req.file?.buffer?.length) {
      throw ApiError.badRequest('no_file', '没有收到文件（字段名应为 file）');
    }
    if (!version) {
      throw ApiError.badRequest('bad_version', '缺少 version 字段');
    }
    // entry 必须是包内相对路径，不能是绝对路径或含 ..
    if (entry.startsWith('/') || entry.includes('..')) {
      throw ApiError.badRequest('bad_entry', 'entry 必须是包内的相对路径');
    }

    const app = await queryOne(
      'SELECT id, version FROM apps WHERE id = ? AND deleted_at IS NULL',
      [appId],
    );
    if (!app) throw ApiError.notFound('没有这个应用，请先在 apps 表里建条目');

    // zip 魔数：PK\x03\x04（空包是 PK\x05\x06）
    const buf = req.file.buffer;
    const isZip =
      buf.length >= 4 &&
      buf[0] === 0x50 &&
      buf[1] === 0x4b &&
      (buf[2] === 0x03 || buf[2] === 0x05) &&
      (buf[3] === 0x04 || buf[3] === 0x06);
    if (!isZip) {
      throw ApiError.badRequest('bad_package', '这个文件不是有效的 zip');
    }

    const sha256 = createHash('sha256').update(buf).digest('hex');

    // 落盘：写 tmp 再 rename（原子替换）
    const { dir, file } = packagePath(appId, version);
    await mkdir(dir, { recursive: true });
    const tmp = `${file}.tmp`;
    await writeFile(tmp, buf);
    await rename(tmp, file);

    // 相对路径入库，读取时按请求 origin 补成绝对地址
    const relUrl = `packages/${appId}/${version}.zip`;

    await execute(
      `UPDATE apps
          SET version = ?, package_url = ?, package_entry = ?,
              package_sha256 = ?, package_bytes = ?
        WHERE id = ?`,
      [version, relUrl, entry, sha256, buf.length, appId],
    );

    sendOk(res, {
      appId,
      version,
      entry,
      sha256,
      bytes: buf.length,
      // 客户端用它下载（绝对地址，带 origin）
      packageUrl: `${req.protocol}://${req.get('host')}/${relUrl}`,
      previousVersion: app.version,
    });
  }),
);

// ================================================================ 下载

/**
 * GET /api/market/:appId/package?version=1.2.0
 *
 * version 省略时给当前上架版本。带 ETag（内容哈希），客户端可以用
 * If-None-Match 复用本地缓存 —— 但**客户端不应该依赖这个**：
 * 真正的完整性保证是下载后自己算 SHA-256 并和 DTO 里的值比对。
 *
 * 不要求登录：包是公开内容（就像 APK 一样）。
 */
packageRouter.get(
  '/:appId/package',
  wrap(async (req, res) => {
    const appId = String(req.params.appId || '').trim();
    const wanted = String(req.query.version || '').trim();

    const app = await queryOne(
      `SELECT id, version, package_entry, package_sha256, package_bytes
         FROM apps WHERE id = ? AND deleted_at IS NULL`,
      [appId],
    );
    if (!app) throw ApiError.notFound('没有这个应用');

    const version = wanted || app.version;
    const { file } = packagePath(appId, version);
    if (!existsSync(file)) {
      throw ApiError.notFound(`没有 ${appId} 的 ${version} 版本包`);
    }

    const st = await stat(file);
    // 用库里的哈希做 ETag（比 mtime 稳：重建同一份包 mtime 会变但哈希不变）
    const etag = `"pkg-${app.package_sha256 || st.size}"`;
    if (req.get('if-none-match') === etag) return res.status(304).end();

    res.set('ETag', etag);
    res.set('Content-Type', 'application/zip');
    res.set('Content-Length', String(st.size));
    // 包是可以长期缓存的（版本号变了 URL 就变了）
    res.set('Cache-Control', 'public, max-age=86400');
    res.set('X-Package-Sha256', app.package_sha256 || '');
    res.set('X-Package-Entry', app.package_entry || 'index.html');

    res.end(await readFile(file));
  }),
);

// ================================================================ 版本检查

/**
 * POST /api/market/updates
 *
 * 注意：本 router 挂在 `/api/market` 下，所以这里的路径写 `/updates`，
 * 不是 `/market/updates` —— 写成后者会变成 /api/market/market/updates。
 * body: { installed: [{ id, version }] }
 *
 * 返回需要升级的条目。客户端在启动时（或用户下拉刷新时）调一次。
 *
 * 为什么是 POST 而不是 GET：要带的是一组「已装版本」，
 * 放查询串会很长（几十个应用就爆 URL 长度限制），也更容易被日志记下来。
 *
 * 返回 shape：
 *   { updates: [{ id, latestVersion, installedVersion, ...推送信息 }] }
 *
 * 只返回**确实需要更新**的：版本不同就算需要（不做「比较大小」）。
 * 理由：版本号没有强制语义（有人用 1.0.1，有人用 2026.10），
 * 猜「哪个更大」会出错；「不一致就更新」是唯一不会误判的规则。
 */
packageRouter.post(
  '/updates',
  wrap(async (req, res) => {
    const installed = Array.isArray(req.body?.installed) ? req.body.installed : [];
    if (installed.length === 0) return sendOk(res, { updates: [] });

    // 只取有包的条目
    const ids = installed
      .map((x) => String(x?.id ?? '').trim())
      .filter((id) => /^[\w.-]{1,64}$/.test(id));

    if (ids.length === 0) return sendOk(res, { updates: [] });

    const placeholders = ids.map(() => '?').join(',');
    const { query } = await import('../db.js');
    const rows = await query(
      `SELECT id, name, version, package_url, package_entry,
              package_sha256, package_bytes, updated_at
         FROM apps
        WHERE id IN (${placeholders}) AND deleted_at IS NULL
          AND package_url IS NOT NULL AND package_url <> ''`,
      ids,
    );

    const latest = new Map(rows.map((r) => [r.id, r]));
    const updates = [];

    for (const item of installed) {
      const id = String(item?.id ?? '').trim();
      const have = String(item?.version ?? '').trim();
      const row = latest.get(id);
      if (!row) continue;
      // 版本一致 → 不用更新。空版本（客户端记录丢了）也当作需要更新。
      if (have && have === row.version) continue;

      updates.push({
        id: row.id,
        name: row.name,
        installedVersion: have,
        latestVersion: row.version,
        packageUrl: `${req.protocol}://${req.get('host')}/${row.package_url}`,
        packageEntry: row.package_entry || 'index.html',
        packageSha256: row.package_sha256 || '',
        packageBytes: Number(row.package_bytes) || 0,
        updatedAt: row.updated_at,
      });
    }

    sendOk(res, { updates, checked: ids.length });
  }),
);

// ================================================================ 元信息

/**
 * GET /api/market/:appId/package/meta
 *
 * 只查「当前上架的是哪一版、多大、什么哈希」，不下载。
 * 客户端在决定要不要下载之前先问它，省一次大文件传输。
 */
packageRouter.get(
  '/:appId/package/meta',
  wrap(async (req, res) => {
    const appId = String(req.params.appId || '').trim();
    const row = await queryOne(
      `SELECT id, name, version, package_url, package_entry,
              package_sha256, package_bytes, updated_at
         FROM apps WHERE id = ? AND deleted_at IS NULL`,
      [appId],
    );
    if (!row) throw ApiError.notFound('没有这个应用');
    if (!row.package_url) {
      return sendOk(res, {
        id: row.id,
        version: row.version,
        hasPackage: false,
      });
    }
    sendOk(res, {
      id: row.id,
      name: row.name,
      version: row.version,
      hasPackage: true,
      packageUrl: `${req.protocol}://${req.get('host')}/${row.package_url}`,
      packageEntry: row.package_entry || 'index.html',
      packageSha256: row.package_sha256 || '',
      packageBytes: Number(row.package_bytes) || 0,
      updatedAt: row.updated_at,
    });
  }),
);

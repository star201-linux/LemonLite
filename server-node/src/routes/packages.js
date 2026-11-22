
import { Router } from 'express';
import multer from 'multer';
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import {
  absoluteAssetUrl,
  isZipBuffer,
  packageDownloadUrl,
  packagePath,
} from '../lib/package_store.js';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { requireAuth } from '../lib/auth.js';

export const packageRouter = Router();

/** 请求的服务根地址（把相对路径补成绝对地址用） */
function originOf(req) {
  const proto = req.get('x-forwarded-proto') || req.protocol || 'http';
  const host = req.get('x-forwarded-host') || req.get('host');
  return host ? `${proto}://${host}` : '';
}

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

    // zip 魔数校验（与 /admin 上传共用同一份实现）
    const buf = req.file.buffer;
    if (!isZipBuffer(buf)) {
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
      // 客户端用它下载：与本服务其它地方一致，走下载接口而不是假想的静态路径
      packageUrl:
        `${req.protocol}://${req.get('host')}/api/market/` +
        `${encodeURIComponent(appId)}/package?version=${encodeURIComponent(version)}`,
      previousVersion: app.version,
    });
  }),
);

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
    const rows = await query(
      `SELECT id, name, version, icon, package_url, package_entry,
              package_sha256, package_bytes, updated_at
         FROM apps
        WHERE id IN (${placeholders}) AND deleted_at IS NULL
          AND package_url IS NOT NULL AND package_url <> ''`,
      ids,
    );

    const latest = new Map(rows.map((r) => [r.id, r]));
    const updates = [];
    const origin = originOf(req);

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
        // 与 feed / detail 用同一个函数：地址算错的表现是「能提示更新、点了 404」
        packageUrl: packageDownloadUrl(row, origin),
        packageEntry: row.package_entry || 'index.html',
        packageSha256: row.package_sha256 || '',
        packageBytes: Number(row.package_bytes) || 0,
        icon: absoluteAssetUrl(row.icon, origin),
        updatedAt: row.updated_at,
      });
    }

    sendOk(res, { updates, checked: ids.length });
  }),
);

packageRouter.get(
  '/:appId/version',
  wrap(async (req, res) => {
    const appId = String(req.params.appId || '').trim();
    if (!appId) throw ApiError.badRequest('bad_request', '缺少应用 id');

    const row = await queryOne(
      `SELECT id, name, version, icon, package_url, package_entry,
              package_sha256, package_bytes, updated_at
         FROM apps WHERE id = ? AND deleted_at IS NULL`,
      [appId],
    );
    if (!row) throw ApiError.notFound('没有这个应用');

    const origin = originOf(req);
    const hasPackage = Boolean(row.package_url);
    sendOk(res, {
      id: row.id,
      name: row.name,
      version: row.version,
      icon: absoluteAssetUrl(row.icon, origin),
      hasPackage,
      packageUrl: hasPackage ? packageDownloadUrl(row, origin) : '',
      packageEntry: row.package_entry || 'index.html',
      packageSha256: row.package_sha256 || '',
      packageBytes: Number(row.package_bytes) || 0,
      updatedAt: row.updated_at,
    });
  }),
);

packageRouter.get(
  '/:appId/package/meta',
  wrap(async (req, res) => {
    const appId = String(req.params.appId || '').trim();
    const row = await queryOne(
      `SELECT id, name, version, icon, package_url, package_entry,
              package_sha256, package_bytes, updated_at
         FROM apps WHERE id = ? AND deleted_at IS NULL`,
      [appId],
    );
    if (!row) throw ApiError.notFound('没有这个应用');
    if (!row.package_url) {
      return sendOk(res, {
        id: row.id,
        version: row.version,
        icon: absoluteAssetUrl(row.icon, originOf(req)),
        hasPackage: false,
      });
    }
    sendOk(res, {
      id: row.id,
      name: row.name,
      version: row.version,
      icon: absoluteAssetUrl(row.icon, originOf(req)),
      hasPackage: true,
      // 与 feed / updates / version 用同一个函数，避免「meta 给的地址下载不了」
      packageUrl: packageDownloadUrl(row, originOf(req)),
      packageEntry: row.package_entry || 'index.html',
      packageSha256: row.package_sha256 || '',
      packageBytes: Number(row.package_bytes) || 0,
      updatedAt: row.updated_at,
    });
  }),
);

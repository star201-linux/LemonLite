// server/src/routes/upload.js
//
// 头像上传 / 下载 + 用户 JSON 数据（userdata/<id>/data.json）。
//
// 路由一览：
//   POST   /api/upload/avatar        上传头像（multipart，字段名 file）
//   GET    /api/upload/avatar/:id    下载某个用户的头像（PNG）
//   DELETE /api/upload/avatar        删除自己的头像
//
//   GET    /api/user/data            读自己的 data.json
//   PUT    /api/user/data            整体替换 data.json
//   PATCH  /api/user/data            浅合并 data.json
//   DELETE /api/user/data            清空 data.json
//
// 为什么头像下载**不要求登录**：
//   头像是「公开展示」的东西（小程序列表、评论里都会出现）。
//   要求登录的话，任何展示头像的地方都得先登录 —— 那不现实。
//   但 id 是自增的，所以它可被枚举 —— 这是已知取舍：图片本身不是秘密，
//   真正的隐私数据在 data.json 里（那个必须登录）。

import { Router } from 'express';
import multer from 'multer';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { queryOne, execute } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { currentUserId, requireAuth } from '../lib/auth.js';
import { config } from '../config.js';
import {
  avatarBytes,
  avatarPath,
  dataJsonPath,
  deleteAvatar,
  mergeUserData,
  readUserData,
  saveAvatar,
  userDataMeta,
  writeUserData,
} from '../lib/userdata.js';

export const uploadRouter = Router();

// ---------------------------------------------------------------- multer

/**
 * 头像上传接收器。
 *
 * 用 memoryStorage 而不是 diskStorage：我们要在落盘前校验魔数
 * （PNG/JPEG 文件头），而 diskStorage 会把文件先写到磁盘 ——
 * 恶意文件在被判断之前就已经落地了（虽然只在临时目录，但没必要）。
 * 2MB 的内存占用对头像完全可接受。
 */
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: config.userdata.maxAvatarBytes,
    files: 1,
    // 允许的字段数：只有一个 file，多余字段直接拒
    fields: 4,
  },
  fileFilter: (_req, file, cb) => {
    // 乐观过滤：先看声明的 MIME。真正的判断在下面用魔数做。
    if (!/^image\/(png|jpe?g|webp)$/i.test(file.mimetype)) {
      return cb(
        ApiError.badRequest(
          'bad_image_type',
          '只支持 PNG / JPEG / WebP 图片',
        ),
      );
    }
    return cb(null, true);
  },
});

/** 识别图片真实格式（看文件头，不看 Content-Type） */
function sniffImage(buffer) {
  if (!buffer || buffer.length < 12) return null;
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (
    buffer[0] === 0x89 &&
    buffer[1] === 0x50 &&
    buffer[2] === 0x4e &&
    buffer[3] === 0x47
  ) {
    return 'png';
  }
  // JPEG: FF D8 FF
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
    return 'jpeg';
  }
  // WebP: "RIFF" .... "WEBP"
  if (
    buffer.toString('ascii', 0, 4) === 'RIFF' &&
    buffer.toString('ascii', 8, 12) === 'WEBP'
  ) {
    return 'webp';
  }
  return null;
}

// ================================================================ 头像

/**
 * POST /api/upload/avatar
 * multipart/form-data，字段名 `file`
 *
 * 客户端流程：选图 → 裁剪 → 导出成 PNG → 传到这里。
 * 服务端只做「是不是图 / 多大 / 存下来」三件事，
 * **不做裁剪** —— 裁剪是交互，必须在客户端做。
 *
 * 落盘后把 users.avatar_ver 更新成时间戳，客户端据此判断要不要重新下载。
 */
uploadRouter.post(
  '/avatar',
  requireAuth,
  upload.single('file'),
  wrap(async (req, res) => {
    if (!req.file?.buffer?.length) {
      throw ApiError.badRequest('no_file', '没有收到文件（字段名应为 file）');
    }

    // 魔数校验：Content-Type 是客户端说的，文件头才是事实
    const kind = sniffImage(req.file.buffer);
    if (!kind) {
      throw ApiError.badRequest(
        'bad_image',
        '这个文件不是有效的 PNG / JPEG / WebP 图片',
      );
    }

    const userId = currentUserId(req);

    // 统一转存成 avatar.png 这个名字（需求原文）。
    // 注意：JPEG/WebP 的字节**原样**存进 avatar.png，不做转码 ——
    // 服务端转码要引 sharp（重依赖），而浏览器/客户端都能按内容识别格式，
    // 扩展名不影响解码。真要做转码应该是客户端导出 PNG 那一步。
    const bytes = await saveAvatar(userId, req.file.buffer);

    const version = String(Date.now());
    await execute('UPDATE users SET avatar_ver = ? WHERE id = ?', [
      version,
      userId,
    ]);

    const row = await queryOne('SELECT * FROM users WHERE id = ?', [userId]);

    sendOk(res, {
      bytes,
      format: kind,
      avatarVersion: version,
      // 直接给可直接下载的地址（带版本戳，绕开缓存）
      avatarUrl: `${req.protocol}://${req.get('host')}/api/upload/avatar/${userId}?v=${version}`,
      user: {
        id: Number(row.id),
        username: row.username,
        avatarVersion: version,
      },
    });
  }),
);

/**
 * GET /api/upload/avatar/:id
 *
 * 公开可访问（见文件头说明）。支持 ETag / 条件请求：
 * 客户端每次进设置页都会显示头像，走 304 就不必重传图片。
 */
uploadRouter.get(
  '/avatar/:id',
  wrap(async (req, res) => {
    const userId = Number.parseInt(req.params.id, 10);
    if (!Number.isInteger(userId) || userId <= 0) {
      throw ApiError.badRequest('bad_user_id', '用户 id 不合法');
    }

    const file = avatarPath(userId);
    if (!existsSync(file)) {
      throw ApiError.notFound('这个用户还没有上传头像');
    }

    const st = await stat(file);

    // 版本参数（?v=...）变了就当作新的 ETag，客户端会重新下载；
    // 没变则走 304。
    const etag = `"avatar-${userId}-${st.size}-${Math.floor(st.mtimeMs)}"`;
    res.set('ETag', etag);
    res.set('Cache-Control', 'public, max-age=60');

    if (req.get('if-none-match') === etag) {
      return res.status(304).end();
    }

    const buffer = await readFile(file);
    // 不写死 Content-Type：文件可能是 PNG/JPEG/WebP（见上传处的说明）。
    // 按魔数给准确的类型，浏览器才能正确显示。
    const kind = sniffImage(buffer) ?? 'png';
    const mime =
      kind === 'jpeg' ? 'image/jpeg' : kind === 'webp' ? 'image/webp' : 'image/png';
    res.set('Content-Type', mime);
    res.set('Content-Length', String(buffer.length));
    return res.end(buffer);
  }),
);

/**
 * DELETE /api/upload/avatar
 *
 * 删掉头像，回到「用户名首字」占位图。
 */
uploadRouter.delete(
  '/avatar',
  requireAuth,
  wrap(async (req, res) => {
    const userId = currentUserId(req);
    const removed = await deleteAvatar(userId);
    // 版本戳清空 —— 客户端据此知道「现在没有头像了」
    await execute("UPDATE users SET avatar_ver = '' WHERE id = ?", [userId]);
    sendOk(res, { removed });
  }),
);

/**
 * GET /api/upload/avatar
 *
 * 当前登录用户的头像元信息（不下载图片本身）。
 * 客户端「设置 → 账号」用它在决定要不要下载。
 */
uploadRouter.get(
  '/avatar',
  requireAuth,
  wrap(async (req, res) => {
    const userId = currentUserId(req);
    const row = await queryOne(
      'SELECT avatar_ver FROM users WHERE id = ?',
      [userId],
    );
    const bytes = await avatarBytes(userId);
    sendOk(res, {
      exists: bytes > 0,
      bytes,
      avatarVersion: row?.avatar_ver ?? '',
      avatarUrl: bytes
        ? `${req.protocol}://${req.get('host')}/api/upload/avatar/${userId}?v=${row?.avatar_ver ?? ''}`
        : '',
    });
  }),
);

// ================================================================ 用户 JSON
//
// ⚠ 这一段挂在 **另一个** router 上（`userDataRouter`，前缀 /api/user），
// 不是 uploadRouter。之前它们共用一个 router，结果 /api/user/data 被挂到了
// /api/upload 前缀下，客户端访问 /api/user/data 永远 404。
// 路由前缀与路径必须一起看 —— 这是把「上传」与「用户数据」混在一个文件里
// 唯一的真实风险，所以这一段用独立 router 显式隔离。

export const userDataRouter = Router();

/**
 * GET /api/user/data
 *
 * 读自己的 data.json。文件不存在时返回 `{ exists:false, data:{} }`，
 * **不是** 404 —— 第一次读是正常流程。
 */
userDataRouter.get(
  '/data',
  requireAuth,
  wrap(async (req, res) => {
    const userId = currentUserId(req);
    const { exists, data } = await readUserData(userId);
    const meta = await userDataMeta(userId);
    sendOk(res, { exists, data, ...meta });
  }),
);

/**
 * PUT /api/user/data
 * body: 任意 JSON 对象（整体替换）
 *
 * 用于「客户端把自己的完整状态推上去」。
 * 如果只是想改几个键，用 PATCH 更安全（不会因为漏字段把别的键清掉）。
 */
userDataRouter.put(
  '/data',
  requireAuth,
  wrap(async (req, res) => {
    const userId = currentUserId(req);
    const body = req.body;
    if (body === undefined || body === null) {
      throw ApiError.badRequest('bad_request', '请求体不能为空');
    }
    if (typeof body !== 'object' || Array.isArray(body)) {
      throw ApiError.badRequest('bad_request', '请求体必须是一个 JSON 对象');
    }
    const bytes = await writeUserData(userId, body);
    sendOk(res, { bytes, updatedAt: new Date().toISOString() });
  }),
);

/**
 * PATCH /api/user/data
 * body: 要合并的顶层键
 *
 * 浅合并：只覆盖传了的顶层键，其余保留。
 * 深合并留给客户端 —— 「数组要不要合并」「null 是删除还是置空」
 * 这些语义服务端猜不准，硬做反而会静默改坏数据。
 */
userDataRouter.patch(
  '/data',
  requireAuth,
  wrap(async (req, res) => {
    const userId = currentUserId(req);
    const { data, bytes } = await mergeUserData(userId, req.body);
    sendOk(res, { data, bytes, updatedAt: new Date().toISOString() });
  }),
);

/**
 * DELETE /api/user/data
 *
 * 清空 data.json（写回 `{}`，而不是删文件 —— 目录结构保持一致，
 * 也让「exists」这个字段继续有意义）。
 */
userDataRouter.delete(
  '/data',
  requireAuth,
  wrap(async (req, res) => {
    const userId = currentUserId(req);
    const bytes = await writeUserData(userId, {});
    sendOk(res, { cleared: true, bytes });
  }),
);

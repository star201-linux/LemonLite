// server/src/lib/userdata.js
//
// 用户私有数据的磁盘布局：
//
//   userdata/<id>/data.json    用户的一整块 JSON（任意结构，服务端不解释）
//   userdata/<id>/avatar.png   头像（固定文件名，覆盖式更新）
//
// 为什么放磁盘而不是 MySQL：
//   这两个东西都是「一整块不透明数据」。塞进数据库的话每次读写都是
//   「读一行 → 解析 JSON → 改 → 再序列化」，而磁盘上是原子的文件替换；
//   用户要备份/迁移时直接拷目录就行，不用 mysqldump 再解析。
//
// 为什么头像固定叫 avatar.png：
//   需求原文就是这个名字。固定文件名让「上传」变成「覆盖」，
//   不需要维护「当前是哪个文件」的记录；缓存失效用 users.avatar_ver
//   做版本戳（客户端拿它当缓存键）。

import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { config } from '../config.js';
import { ApiError } from './http.js';

/** userdata 根目录的绝对路径 */
export function userdataRoot() {
  return resolve(config.root, config.userdata.dir);
}

/**
 * 某个用户的目录。**会做越界校验**：
 * id 来自数据库（BIGINT），但这里仍然校验，因为这是唯一能防止
 * 「数据库被写坏 → 路径穿越」的地方。
 */
export function userDir(userId) {
  const n = Number(userId);
  if (!Number.isInteger(n) || n <= 0) {
    throw ApiError.badRequest('bad_user_id', '用户 id 不合法');
  }
  const root = userdataRoot();
  const dir = join(root, String(n));
  // 二次确认：解析后的路径必须真的在 root 底下
  if (dir !== join(root, String(n)) || !dir.startsWith(root + sep)) {
    throw ApiError.badRequest('bad_user_id', '用户 id 不合法');
  }
  return dir;
}

export function dataJsonPath(userId) {
  return join(userDir(userId), 'data.json');
}

export function avatarPath(userId) {
  return join(userDir(userId), 'avatar.png');
}

/** 确保用户目录存在（幂等） */
export async function ensureUserDir(userId) {
  const dir = userDir(userId);
  await mkdir(dir, { recursive: true });
  return dir;
}

// ---------------------------------------------------------------- data.json

/**
 * 读 data.json。
 *
 * 文件不存在 → 返回 `{}`（**不是** 404）。
 * 理由：客户端第一次读用户数据是正常流程，不该被当成错误；
 * 返回空对象让客户端拿到一个「可以往上写」的起点。
 */
export async function readUserData(userId) {
  const path = dataJsonPath(userId);
  if (!existsSync(path)) return { exists: false, data: {} };

  const raw = await readFile(path, 'utf8');
  if (raw.trim() === '') return { exists: true, data: {} };

  try {
    return { exists: true, data: JSON.parse(raw) };
  } catch (e) {
    // 文件坏了：不 500，也不静默返回空（那会让客户端以为数据没了然后覆盖掉）。
    // 返回 500 + 明确消息，让人知道该去修文件。
    throw new ApiError(
      500,
      'userdata_corrupted',
      '保存的用户数据损坏，请联系管理员',
      path,
    );
  }
}

/**
 * 写 data.json（整体替换）。
 *
 * 原子写：先写 `data.json.tmp` 再 rename。
 * 直接覆盖的话，写到一半断电/进程被杀会留下一个截断的 JSON ——
 * 那比「没更新成功」糟得多（下次读取直接解析失败）。
 * rename 在同一文件系统内是原子的，所以要么是旧内容，要么是新内容。
 */
export async function writeUserData(userId, data) {
  await ensureUserDir(userId);
  const path = dataJsonPath(userId);
  const tmp = `${path}.tmp`;

  const json = JSON.stringify(data, null, 2);
  const bytes = Buffer.byteLength(json, 'utf8');
  if (bytes > config.userdata.maxDataBytes) {
    throw ApiError.tooLarge(
      `数据过大（${(bytes / 1024 / 1024).toFixed(1)}MB），` +
        `上限 ${Math.round(config.userdata.maxDataBytes / 1024 / 1024)}MB`,
    );
  }

  await writeFile(tmp, json, 'utf8');
  await rename(tmp, path);
  return bytes;
}

/** 合并写入（浅合并：顶层 key 覆盖）。深合并留给客户端自己做，语义更清楚。 */
export async function mergeUserData(userId, patch) {
  if (patch === null || typeof patch !== 'object' || Array.isArray(patch)) {
    throw ApiError.badRequest('bad_request', '要合并的数据必须是一个 JSON 对象');
  }
  const { data } = await readUserData(userId);
  const merged = { ...data, ...patch };
  const bytes = await writeUserData(userId, merged);
  return { data: merged, bytes };
}

/** data.json 的元信息（不读内容） */
export async function userDataMeta(userId) {
  const path = dataJsonPath(userId);
  if (!existsSync(path)) return { exists: false, bytes: 0, updatedAt: null };
  const st = await stat(path);
  return {
    exists: true,
    bytes: st.size,
    updatedAt: st.mtime.toISOString(),
  };
}

// ---------------------------------------------------------------- avatar.png

/** 头像是否存在 */
export function avatarExists(userId) {
  return existsSync(avatarPath(userId));
}

/**
 * 保存头像。
 *
 * 用「写 tmp 再 rename」达到原子替换 —— 让客户端永远读不到半个 PNG。
 * 另外清掉 avatar_ver 之外的东西不做：目录里就这两个文件，不需要清理。
 */
export async function saveAvatar(userId, buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    throw ApiError.badRequest('bad_image', '图片内容为空');
  }
  if (buffer.length > config.userdata.maxAvatarBytes) {
    throw ApiError.tooLarge(
      `图片过大（${(buffer.length / 1024 / 1024).toFixed(1)}MB），` +
        `上限 ${Math.round(config.userdata.maxAvatarBytes / 1024 / 1024)}MB`,
    );
  }

  await ensureUserDir(userId);
  const path = avatarPath(userId);
  const tmp = `${path}.tmp`;
  await writeFile(tmp, buffer);
  await rename(tmp, path);
  return buffer.length;
}

/** 删除头像（回到用户名首字占位图） */
export async function deleteAvatar(userId) {
  const path = avatarPath(userId);
  if (!existsSync(path)) return false;
  await rm(path, { force: true });
  return true;
}

/** 头像文件大小（没有则 0） */
export async function avatarBytes(userId) {
  const path = avatarPath(userId);
  if (!existsSync(path)) return 0;
  const st = await stat(path);
  return st.size;
}

// ---------------------------------------------------------------- URL 拼装

/**
 * 头像的版本戳：users.avatar_ver 优先，没有文件时返回空串。
 *
 * 客户端拿它当缓存键：版本没变就不用重新下载。
 */
export function avatarVersion(user) {
  if (!user) return '';
  return String(user.avatar_ver ?? '');
}

/**
 * 拼出客户端可下载的绝对 URL。
 *
 * 为什么要「绝对」：客户端在 Android 上要直接拿这个 URL 去请求，
 * 相对路径它没有 base 可拼（它不是浏览器，没有当前页面的 origin）。
 *
 * 没有头像时返回空串 —— 客户端据此画占位图，而不是去请求一个 404。
 */
export function absoluteAvatarUrl(req, user) {
  if (!user) return '';
  if (!avatarVersion(user)) return '';

  // 优先用请求里的 Host（这样局域网 IP、域名、反代之后的域名都自然正确）
  const proto = req.get('x-forwarded-proto') || req.protocol || 'http';
  const host = req.get('x-forwarded-host') || req.get('host');
  if (!host) return '';
  return `${proto}://${host}/api/upload/avatar/${user.id}?v=${encodeURIComponent(avatarVersion(user))}`;
}

/**
 * 从 HTTP 请求拿到客户端认为的服务根地址。
 *
 * 用于把「userdata 里的相对引用」补成绝对 URL（目前只有头像用到）。
 */
export function requestOrigin(req) {
  const proto = req.get('x-forwarded-proto') || req.protocol || 'http';
  const host = req.get('x-forwarded-host') || req.get('host');
  return host ? `${proto}://${host}` : '';
}

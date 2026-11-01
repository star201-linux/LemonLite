// server/src/lib/package_store.js
//
// 小程序包的落盘与校验。上传（作者接口 /admin）与下载（客户端）共用这一份，
// 因为「路径怎么拼」和「越界怎么挡」必须只有一处实现 —— 两边各写一份，
// 迟早会出现「一个允许 version 带 `../`、另一个不允许」的洞。

import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readdir, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { config } from '../config.js';
import { ApiError } from './http.js';

/** packages/ 根目录 */
export function packagesRoot() {
  return resolve(config.root, 'packages');
}

/**
 * 某个包的落盘路径。
 *
 * **越界校验在这里**：appId 与 version 都来自请求参数/数据库，
 * 但它们会被拼进文件路径 —— 一个 `../` 就能写到目录外。
 * 除了字符白名单，最后还要确认解析后的绝对路径仍在 packages/ 下。
 */
export function packagePath(appId, version) {
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

/** zip 魔数：PK\x03\x04（正常包）/ PK\x05\x06（空包） */
export function isZipBuffer(buf) {
  return (
    Buffer.isBuffer(buf) &&
    buf.length >= 4 &&
    buf[0] === 0x50 &&
    buf[1] === 0x4b &&
    (buf[2] === 0x03 || buf[2] === 0x05) &&
    (buf[3] === 0x04 || buf[3] === 0x06)
  );
}

/**
 * 落盘一个包：校验 → 写临时文件 → 原子替换。
 * @returns {Promise<{sha256: string, bytes: number, relUrl: string, file: string}>}
 */
export async function storePackage({ appId, version, buffer }) {
  if (!isZipBuffer(buffer)) {
    throw ApiError.badRequest('bad_package', '这个文件不是有效的 zip');
  }
  const sha256 = createHash('sha256').update(buffer).digest('hex');
  const { dir, file } = packagePath(appId, version);
  await mkdir(dir, { recursive: true });
  const tmp = `${file}.tmp`;
  await writeFile(tmp, buffer);
  await rename(tmp, file);
  return {
    sha256,
    bytes: buffer.length,
    relUrl: `packages/${appId}/${version}.zip`,
    file,
  };
}

/** 删除某个版本的包文件（不存在也当成功） */
export async function removePackage(appId, version) {
  const { file } = packagePath(appId, version);
  if (!existsSync(file)) return false;
  await unlink(file);
  return true;
}

/** 列出某个应用本机已有的版本包（按文件名倒序，给管理面板看） */
export async function listPackages(appId) {
  const { dir } = packagePath(appId, '0.0.0');
  if (!existsSync(dir)) return [];
  const names = await readdir(dir);
  const out = [];
  for (const name of names) {
    if (!name.endsWith('.zip')) continue;
    const info = await stat(join(dir, name));
    out.push({ version: name.slice(0, -4), bytes: info.size, mtime: info.mtime });
  }
  return out.sort((a, b) => b.mtime - a.mtime);
}

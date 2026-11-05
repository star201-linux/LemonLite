// server/src/lib/icon_store.js
//
// 小程序图标的落盘。
//
// 为什么需要它：应用管理列表要显示每个小程序的图标，而图标是管理员在面板里
// 上传的一份图片。让它留在「图标 URL」这个字段里、由管理员自己找图床，
// 对一个自建的私有市场来说太别扭了 —— 换台服务器所有图标就全挂。
// 现在管理面板可以直接传一张图，服务端托管在 /icons/<appId>.<ext>。
//
// 与 packages/ 分开的理由：
//   * 包是「可执行内容」（要校验哈希、要解压），图标只是图片；
//   * 包按 appId/version 存多份，图标每个 appId 只有一张（覆盖式更新）；
//   * 清理策略完全不同（包可以留历史版本，图标永远只留最新的）。
//
// 目录：icons/<appId>.<png|jpg|webp|gif>
// 给客户端的地址是相对路径 `icons/<appId>.<ext>`：客户端会按服务器地址
// 解析成绝对 URL。存完整地址的话，换域名就全坏了。

import { existsSync } from 'node:fs';
import { mkdir, readdir, rename, unlink, writeFile } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { config } from '../config.js';
import { ApiError } from './http.js';

/** icons/ 根目录 */
export function iconsRoot() {
  return resolve(config.root, config.icons.dir);
}

/**
 * 从文件头判断图片格式。
 *
 * 不信客户端的 Content-Type / 扩展名：把一个 .html 改名成 .png 传上来，
 * 后续 <img src> 会把它当图片解码（失败），但如果哪天有人直接访问这个
 * URL，浏览器会按扩展名猜类型 —— 那几个字节的风险不值得留。
 *
 * @returns {{ext: string, mime: string} | null}
 */
export function detectImage(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return null;

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (
    buffer[0] === 0x89 &&
    buffer[1] === 0x50 &&
    buffer[2] === 0x4e &&
    buffer[3] === 0x47
  ) {
    return { ext: 'png', mime: 'image/png' };
  }
  // JPEG: FF D8 FF
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
    return { ext: 'jpg', mime: 'image/jpeg' };
  }
  // GIF: GIF87a / GIF89a
  if (buffer.subarray(0, 3).toString('ascii') === 'GIF') {
    return { ext: 'gif', mime: 'image/gif' };
  }
  // WebP: RIFF....WEBP
  if (
    buffer.subarray(0, 4).toString('ascii') === 'RIFF' &&
    buffer.subarray(8, 12).toString('ascii') === 'WEBP'
  ) {
    return { ext: 'webp', mime: 'image/webp' };
  }
  return null;
}

/** appId 会进文件名，必须挡住 `/` 与 `..` */
function safeAppId(appId) {
  const value = String(appId || '').trim();
  if (!/^[\w.-]{1,64}$/.test(value)) {
    throw ApiError.badRequest(
      'bad_app_id',
      'appId 只能包含字母、数字、下划线、点和连字符',
    );
  }
  return value;
}

/**
 * 保存一张图标，返回可入库的相对地址。
 *
 * 覆盖式：先写 `.tmp` 再 rename（原子替换），并删掉同 appId 的旧扩展名文件
 * （png 换 jpg 时旧文件要清掉，否则目录里会留两份、清理时也漏）。
 *
 * @returns {Promise<{relUrl: string, file: string, bytes: number, mime: string}>}
 */
export async function storeIcon({ appId, buffer }) {
  const id = safeAppId(appId);
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    throw ApiError.badRequest('no_file', '没有收到图片文件（字段名应为 file）');
  }
  if (buffer.length > config.icons.maxBytes) {
    throw ApiError.tooLarge(
      `图标太大（上限 ${Math.round(config.icons.maxBytes / 1024)} KB）`,
    );
  }

  const type = detectImage(buffer);
  if (!type) {
    throw ApiError.badRequest(
      'bad_image',
      '只支持 PNG / JPEG / WebP / GIF 图片',
    );
  }

  const root = iconsRoot();
  await mkdir(root, { recursive: true });
  const file = join(root, `${id}.${type.ext}`);
  if (!file.startsWith(root + sep)) {
    throw ApiError.badRequest('bad_path', '路径不合法');
  }

  const tmp = `${file}.tmp`;
  await writeFile(tmp, buffer);
  await rename(tmp, file);

  // 换格式时清掉旧扩展名（覆盖式存储，一个 appId 只应有一张图）
  for (const ext of ['png', 'jpg', 'jpeg', 'gif', 'webp']) {
    if (ext === type.ext) continue;
    const old = join(root, `${id}.${ext}`);
    if (existsSync(old)) {
      try {
        await unlink(old);
      } catch {
        // 删不掉旧文件不影响这次上传
      }
    }
  }

  return {
    relUrl: `icons/${id}.${type.ext}`,
    file,
    bytes: buffer.length,
    mime: type.mime,
  };
}

/** 删除某个应用的所有图标文件（不存在也算成功） */
export async function removeIcons(appId) {
  const id = safeAppId(appId);
  const root = iconsRoot();
  if (!existsSync(root)) return 0;
  let removed = 0;
  for (const name of await readdir(root)) {
    const [stem] = name.split('.');
    if (stem !== id) continue;
    try {
      await unlink(join(root, name));
      removed++;
    } catch {
      // 忽略：可能刚好被别的请求删掉
    }
  }
  return removed;
}

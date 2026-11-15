// server/src/lib/image.js
//
// 图片格式识别（看文件头，不信 Content-Type）。
//
// 为什么需要它：`Content-Type` 是客户端自己说的，随便改成 image/png 就能过。
// 真正能判断「这是不是一张图」的只有字节本身。
//
// 为什么只认这三种：客户端与面板都只允许传 PNG / JPEG / WebP ——
// GIF 没在客户端的选择器里，SVG 是「能执行脚本的 XML」，放进头像目录
// 等于给自己开一个存储型 XSS 的口子（浏览器直接打开图片地址就会执行）。

/** @returns {'png'|'jpeg'|'webp'|null} */
export function sniffImage(buffer) {
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

/** 格式 → MIME（下载时按它设 Content-Type） */
export function imageMime(kind) {
  if (kind === 'jpeg') return 'image/jpeg';
  if (kind === 'webp') return 'image/webp';
  return 'image/png';
}

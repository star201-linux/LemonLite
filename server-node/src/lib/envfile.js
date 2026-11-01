// server/src/lib/envfile.js
//
// 把「运行时改的配置」写回 .env。
//
// 为什么可以改 .env：管理面板想让部署方不改代码、不重启就能换邮件通道。
// 写回文件才是真正的持久化 —— 只改内存的话，下一次重启所有设置都回到旧值，
// 用户会以为「保存按钮没生效」。
//
// 写入策略：先读原文，**逐行替换**已存在的 KEY，文件末尾追加新 KEY。
// 不重排、不删注释 —— 这个文件是给人看的，顺序和注释都是信息。

import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';

/** 需要引号的值：空串、含空格/井号/引号/换行 */
function formatValue(value) {
  const text = String(value ?? '');
  if (text === '') return '';
  if (/[\s#"'\\]/.test(text) || text !== text.trim()) {
    return `"${text.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  }
  return text;
}

/**
 * 更新 .env 里的若干键（不存在则追加）。
 *
 * @param {string} path  .env 的绝对路径
 * @param {Record<string, string|number|boolean>} values
 * @returns {{updated: string[], added: string[]}}
 */
export function updateEnvFile(path, values) {
  const existed = existsSync(path);
  const existing = existed ? readFileSync(path, 'utf8') : '';
  const pending = new Map(Object.entries(values).map(([k, v]) => [k, String(v)]));
  const updated = [];
  const added = [];

  const lines = existing.split('\n').map((line) => {
    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=/.exec(line);
    if (!m) return line;
    const key = m[1];
    if (!pending.has(key)) return line;
    const value = pending.get(key);
    pending.delete(key);
    updated.push(key);
    return `${key}=${formatValue(value)}`;
  });

  for (const [key, value] of pending) {
    lines.push(`${key}=${formatValue(value)}`);
    added.push(key);
  }

  let text = lines.join('\n');
  if (!text.endsWith('\n')) text += '\n';

  // 先写临时文件再 rename：避免进程在写一半时被杀，留下一个半截的 .env
  //（那会让服务下次启动时读到不完整的配置）。
  const tmp = `${path}.tmp-${process.pid}`;
  try {
    writeFileSync(tmp, text, 'utf8');
    renameSync(tmp, path);
  } catch {
    // 某些文件系统（FUSE / 容器挂载）不允许 rename，退化成正写。
    try {
      unlinkSync(tmp);
    } catch {
      /* ignore */
    }
    writeFileSync(path, text, 'utf8');
  }

  return { updated, added };
}

/** 读 .env 里的某个键（读不到返回 undefined），调试面板用 */
export function readEnvValue(path, key) {
  if (!existsSync(path)) return undefined;
  const line = readFileSync(path, 'utf8')
    .split('\n')
    .find((l) => new RegExp(`^\\s*${key}\\s*=`).test(l));
  if (!line) return undefined;
  return line.slice(line.indexOf('=') + 1).trim().replace(/^"(.*)"$/, '$1');
}

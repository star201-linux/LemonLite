// server/src/admin/shared.js
//
// 面板几个子路由共用的小工具。都是纯函数，方便单独测。

/** 应用 id：字母数字开头，可含 _ . - ，最多 64 位 */
export const APP_ID_RE = /^[A-Za-z0-9][\w.-]{1,63}$/;

/** 版本号：字母数字点加号连字符 */
export const VERSION_RE = /^[\w.+-]{1,32}$/;

/** 从请求体读一个数字，夹到合理区间 */
export function intIn(value, fallback, min, max) {
  const n = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

/** JSON 列在 mysql2 里可能已经是数组，也可能是字符串 */
export function parseJsonArray(value) {
  if (Array.isArray(value)) return value;
  if (typeof value !== 'string' || !value.trim()) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/**
 * 把 GROUP_CONCAT 出来的 `id\u0001name\u0002id\u0001name` 还原成对象数组。
 *
 * 为什么用两个不可见分隔符而不是 JSON：MySQL 的 JSON_ARRAYAGG 在
 * 空集时返回 NULL、且有长度限制；GROUP_CONCAT + 两个控制字符最省事。
 * \u0001 分隔 id 与 name，\u0002 分隔条目 —— 应用名里不可能出现这两个字符。
 */
export function parseCategoryPairs(value) {
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

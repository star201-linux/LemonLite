export function toSqlTime(date) {
  return new Date(date.getTime()).toISOString().slice(0, 23).replace('T', ' ');
}

/** `'YYYY-MM-DD HH:mm:ss.SSS'`（UTC）→ Date；空值 / 非法返回 null */
export function parseSqlTime(value) {
  if (!value) return null;
  const d = new Date(`${String(value).replace(' ', 'T')}Z`);
  return Number.isNaN(d.getTime()) ? null : d;
}

/**
 * SQL 时间 → 带 Z 的 ISO 字符串（给 JSON 用）。
 *
 * 对外一律用 ISO + Z：浏览器 `new Date(iso)` 与 Dart `DateTime.parse(iso)`
 * 都能正确按 UTC 解析，并各自转成本地时间显示。返回裸字符串的话，
 * 客户端就得自己猜时区 —— 而它们猜的往往不一样。
 */
export function sqlToIso(value) {
  const d = parseSqlTime(value);
  return d ? d.toISOString() : null;
}

/** 现在（UTC）的 SQL 字符串 */
export function nowSql() {
  return toSqlTime(new Date());
}

/** 现在 + N 毫秒 的 SQL 字符串 */
export function sqlAfterMs(ms) {
  return toSqlTime(new Date(Date.now() + ms));
}

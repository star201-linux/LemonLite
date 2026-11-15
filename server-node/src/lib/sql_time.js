// server/src/lib/sql_time.js
//
// MySQL DATETIME(3) 与 JS Date 之间的转换。
//
// 为什么全项目只在这一个文件里做转换：
//   连接池开了 `dateStrings: true`（见 db.js），所以 DATETIME 读出来是
//   `'2026-11-15 09:30:00.000'` 这种**不带时区**的字符串，含义是 UTC
//   （写入时 mysql2 按 UTC 序列化 Date）。只要有一处用 `new Date(str)`
//   去解析，它就会按**服务器本地时区**解释，凭空多出/少掉几小时 ——
//   这类 bug 在本地时区为 UTC 的开发机上看不出来，上线才炸。
//   所以统一：读 → 加 Z 再解析；写 → toISOString 截到毫秒并把 T 换成空格。

/** Date → `'YYYY-MM-DD HH:mm:ss.SSS'`（UTC） */
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

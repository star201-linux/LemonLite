// server/src/lib/sqlfile.js
//
// 把 .sql 文件切成一条条语句。
//
// 为什么需要它：schema.sql 靠 `npm run init` 执行，而服务启动时也要
// 再跑一遍**同一份**文件（幂等建表，见 lib/schema_guard.js）。
// 如果两处各写一份切分逻辑，早晚会分叉 —— 而分叉出来的后果是
// 「init 建了表、启动时没建」，排查起来非常浪费时间。

/**
 * 把 SQL 文件按分号切成一条条语句。
 *
 * 只处理本项目 schema 用到的语法：
 *   * 整行 `--` 注释直接丢掉；
 *   * 以 `;\n` 结尾切分（字符串里的分号在 schema 里不存在）；
 *   * `SET NAMES` 丢掉 —— 连接本身已经设了 utf8mb4。
 */
export function splitStatements(sql) {
  const cleaned = String(sql)
    .split('\n')
    .filter((line) => !line.trim().startsWith('--'))
    .join('\n');
  return cleaned
    .split(/;\s*\n/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0 && !/^SET\s+NAMES/i.test(s));
}

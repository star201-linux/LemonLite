// server/src/lib/schema_guard.js
//
// 启动时的「表结构自检」。
//
// 为什么启动时还要跑一遍 schema.sql：
//   升级到新版本时，旧库里没有新表（比如多分类用的 app_categories）。
//   正常流程是 `npm run init`，但真实世界里总有人 `git pull` 完直接重启 ——
//   然后市场接口每次 500（表不存在）。这里把建表语句全跑一遍：
//   全是 `CREATE TABLE IF NOT EXISTS`，幂等、一次几毫秒，换来「升级不用记命令」。
//
// 它**不负责**灌种子数据（那是 init.js 的事），也绝不做 ALTER/删表。
// 唯一的例外是 ensureUserColumns()：`CREATE TABLE IF NOT EXISTS` 不会给
// 已经存在的表补列，而 users 上的「注销冷静期」两列（0.8）与「封禁时长 /
// 原因」两列（0.9）都是后加的。那段 ALTER 是幂等的（列已存在时吃 1060
// 错误码），并且只加 NULL / 带默认值的空列、不改不删任何已有数据。

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pool } from '../db.js';
import { splitStatements } from './sqlfile.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA_PATH = join(HERE, '..', '..', 'sql', 'schema.sql');

/**
 * 把「应用的主分类」补进多分类关联表。
 *
 * apps.category_id 是历史字段（单分类时代），app_categories 才是
 * 现在的归类关系。升级上来的库里有前者的数据、没有后者，
 * 不补的话「按分类筛选」会漏掉这些应用。
 *
 * @param {{query: Function}} conn 连接池或 init.js 里的单连接
 * @returns {Promise<number>} 补了多少行
 */
export async function backfillAppCategories(conn = pool) {
  const [result] = await conn.query(
    `INSERT IGNORE INTO app_categories (app_id, category_id)
     SELECT id, category_id FROM apps WHERE category_id IS NOT NULL`,
  );
  return result?.affectedRows ?? 0;
}

/**
 * 给已存在的 users 表补「注销冷静期」两列。
 *
 * 为什么不能只写在 schema.sql 里：那里全是 `CREATE TABLE IF NOT EXISTS`，
 * 表已经存在时整条语句直接跳过 —— 老库升级上来会缺这两列，
 * 然后「申请注销」每次 500（Unknown column）。
 *
 * 幂等：列已存在时 MySQL 报 ER_DUP_FIELDNAME(1060)，直接当作成功。
 * 只加 NULL 列，不动任何已有数据，所以对生产库是安全的。
 */
const USER_ADDED_COLUMNS = [
  // 注销冷静期（0.8）
  ['deletion_requested_at', 'DATETIME(3) NULL'],
  ['deletion_scheduled_at', 'DATETIME(3) NULL'],
  // 封禁时长 + 原因（0.9）。NULL + status=disabled 表示永久封禁。
  ['banned_until', 'DATETIME(3) NULL'],
  ['ban_reason', "VARCHAR(255) NOT NULL DEFAULT ''"],
];

export async function ensureUserColumns(conn = pool) {
  const added = [];
  for (const [name, type] of USER_ADDED_COLUMNS) {
    try {
      await conn.query(`ALTER TABLE users ADD COLUMN ${name} ${type}`);
      added.push(name);
    } catch (e) {
      // 1060 = Duplicate column name，其它错误交给调用方记录
      if (e.code !== 'ER_DUP_FIELDNAME' && e.errno !== 1060) throw e;
    }
  }
  return added;
}

/**
 * 幂等建表 + 回填。
 *
 * 失败不抛异常：数据库账号可能只有读写权限（没 CREATE），
 * 那种部署下服务仍然应该能启动，只是会在用到缺失的表时报错。
 * 所以这里收集失败原因交给调用方打日志。
 */
export async function ensureSchema({ logger = console } = {}) {
  let sql;
  try {
    sql = readFileSync(SCHEMA_PATH, 'utf8');
  } catch (e) {
    return { ok: false, executed: 0, failed: [`读不到 schema.sql：${e.message}`], filled: 0 };
  }

  const statements = splitStatements(sql);
  const failed = [];
  for (const stmt of statements) {
    try {
      await pool.query(stmt);
    } catch (e) {
      failed.push(e.code || e.message);
    }
  }

  // 老库补列（新库这里已经是 no-op）
  try {
    const added = await ensureUserColumns();
    if (added.length > 0) logger.log(`[schema] users 表补列：${added.join(', ')}`);
  } catch (e) {
    failed.push(e.code || e.message);
  }

  if (failed.length > 0) {
    logger.warn(`! 表结构自检有 ${failed.length} 条没执行成功（${failed[0]}）`);
    logger.warn('  如果接口报「表不存在」，先跑一次：npm run init');
  }

  let filled = 0;
  try {
    filled = await backfillAppCategories();
  } catch (e) {
    failed.push(e.code || e.message);
  }

  return { ok: failed.length === 0, executed: statements.length, failed, filled };
}

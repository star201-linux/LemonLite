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

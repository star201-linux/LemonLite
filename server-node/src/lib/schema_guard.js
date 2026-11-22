
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

const USER_ADDED_COLUMNS = [
  // 注销冷静期（0.8）
  ['deletion_requested_at', 'DATETIME(3) NULL'],
  ['deletion_scheduled_at', 'DATETIME(3) NULL'],
  // 封禁时长 + 原因（0.9）。NULL + status=disabled 表示永久封禁。
  ['banned_until', 'DATETIME(3) NULL'],
  ['ban_reason', "VARCHAR(255) NOT NULL DEFAULT ''"],
];

const ANNOUNCEMENT_ADDED_COLUMNS = [
  // 公告级别 1~4（0.10）。老公告默认 1（只在设置页红点），最不打扰。
  ['level', 'TINYINT NOT NULL DEFAULT 1'],
];

/** 给一张表补列，列已存在（1060）视为成功 */
async function ensureColumns(conn, table, columns) {
  const added = [];
  for (const [name, type] of columns) {
    try {
      await conn.query(`ALTER TABLE ${table} ADD COLUMN ${name} ${type}`);
      added.push(name);
    } catch (e) {
      // 1060 = Duplicate column name，其它错误交给调用方记录
      if (e.code !== 'ER_DUP_FIELDNAME' && e.errno !== 1060) throw e;
    }
  }
  return added;
}

export async function ensureUserColumns(conn = pool) {
  return ensureColumns(conn, 'users', USER_ADDED_COLUMNS);
}

export async function ensureAnnouncementColumns(conn = pool) {
  return ensureColumns(conn, 'announcements', ANNOUNCEMENT_ADDED_COLUMNS);
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
  for (const [table, ensure] of [
    ['users', ensureUserColumns],
    ['announcements', ensureAnnouncementColumns],
  ]) {
    try {
      const added = await ensure();
      if (added.length > 0) logger.log(`[schema] ${table} 表补列：${added.join(', ')}`);
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

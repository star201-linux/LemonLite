// server/src/init.js
//
// 一键初始化：建库 → 建表 → 灌种子数据。
//
// 用法：
//   npm run init            # 只在库/表不存在时创建，不会清空已有数据
//   npm run init -- --seed  # 额外灌入演示应用（已存在则跳过）
//   npm run init -- --reset # **危险**：DROP 整个库再重建（会二次确认）
//
// 为什么把「建库」和「建表」放同一个脚本：
//   MySQL 的 `CREATE TABLE` 必须在 USE 之后，而 USE 需要库已存在。
//   拆成两个脚本的话，第一次部署的人一定会漏跑其中一个，
//   然后拿到一个「表不存在」的错误 —— 那是最没必要浪费时间的错误。

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import mysql from 'mysql2/promise';
import { config, readEnvFile } from './config.js';
import { backfillAppCategories } from './lib/schema_guard.js';
import { splitStatements } from './lib/sqlfile.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SQL_PATH = join(__dirname, '..', 'sql', 'schema.sql');
const SEED_PATH = join(__dirname, '..', 'sql', 'seed.sql');

const args = new Set(process.argv.slice(2));
const wantSeed = args.has('--seed');
const wantReset = args.has('--reset');

/** 是否有交互式终端（决定 --reset 要不要二次确认） */
const interactive = process.stdin.isTTY;

async function confirm(question) {
  if (!interactive) {
    // CI / 管道里没有 tty：直接拒绝，绝不允许「无确认地删库」。
    console.error('✗ --reset 需要交互式终端确认。请在本地终端里执行。');
    process.exit(1);
  }
  process.stdout.write(`${question} (输入 DELETE 继续)：`);
  const answer = await new Promise((resolve) => {
    process.stdin.setEncoding('utf8');
    process.stdin.once('data', (chunk) => resolve(String(chunk).trim()));
  });
  if (answer !== 'DELETE') {
    console.log('已取消。');
    process.exit(0);
  }
}

function step(text) {
  console.log(`\x1b[36m==>\x1b[0m ${text}`);
}

function ok(text) {
  console.log(`\x1b[32m  ✓\x1b[0m ${text}`);
}

function warn(text) {
  console.log(`\x1b[33m  !\x1b[0m ${text}`);
}

function fail(text) {
  console.error(`\x1b[31m  ✗\x1b[0m ${text}`);
}

async function main() {
  // 让「第一次 clone 下来就 npm run init」也能跑：.env 不存在时按 .env.example
  // 的默认值走，并提示用户去改。
  const envExisted = readEnvFile();
  if (!envExisted) {
    warn('没有找到 .env，已按 .env.example 的默认值连接（root@localhost:3306）');
    warn('生产环境请先 cp .env.example .env 并改掉 DB_USER / DB_PASSWORD');
  }

  const { host, port, user, password, database } = config.db;

  step(`连接 MySQL：${user}@${host}:${port}（不指定库）`);
  let conn;
  try {
    conn = await mysql.createConnection({
      host,
      port,
      user,
      password,
      multipleStatements: false,
      // 允许连一个不存在的库：我们要先建它
      charset: 'utf8mb4',
    });
  } catch (e) {
    fail(`连不上 MySQL：${e.code || e.message}`);
    console.error('');
    console.error('  排查顺序：');
    console.error('    1. MySQL 起来了吗：systemctl status mysql（或 mariadb）');
    console.error('    2. .env 里的 DB_HOST / DB_PORT / DB_USER / DB_PASSWORD 对吗');
    console.error('    3. 这个账号有 CREATE DATABASE 权限吗');
    process.exit(1);
  }
  ok('已连接');

  // ---------------------------------------------------------------- 建库
  const dbName = database.replace(/`/g, '');
  if (wantReset) {
    await confirm(`⚠ 这会 DROP 整个数据库 \`${dbName}\`，所有账号与市场数据都会丢失。`);
    step(`DROP DATABASE \`${dbName}\``);
    await conn.query(`DROP DATABASE IF EXISTS \`${dbName}\``);
    ok('已删除旧库');
  }

  step(`确保数据库 \`${dbName}\` 存在`);
  await conn.query(
    `CREATE DATABASE IF NOT EXISTS \`${dbName}\` ` +
      'CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci',
  );
  ok(`数据库就绪：${dbName}`);

  await conn.query(`USE \`${dbName}\``);

  // ---------------------------------------------------------------- 建表
  step('执行 schema.sql（表已存在则跳过，不会动数据）');
  const sql = readFileSync(SQL_PATH, 'utf8');
  const statements = splitStatements(sql);
  let created = 0;
  for (const stmt of statements) {
    // 从语句里认出表名，好打日志
    const m = /CREATE TABLE IF NOT EXISTS\s+`?(\w+)`?/i.exec(stmt);
    try {
      await conn.query(stmt);
      if (m) {
        created++;
        ok(`表 ${m[1]}`);
      }
    } catch (e) {
      fail(`执行失败：${e.message}`);
      console.error(stmt.slice(0, 300));
      process.exit(1);
    }
  }
  ok(`${created} 张表已就绪`);

  // ---------------------------------------------------------------- 种子
  if (wantSeed) {
    step('灌入演示数据（seed.sql，按主键去重）');
    const seed = readFileSync(SEED_PATH, 'utf8');
    for (const stmt of splitStatements(seed)) {
      try {
        await conn.query(stmt);
      } catch (e) {
        warn(`跳过一条种子语句（${e.code || e.message}）`);
      }
    }
    const [[cats]] = await conn.query('SELECT COUNT(*) AS n FROM categories');
    const [[apps]] = await conn.query('SELECT COUNT(*) AS n FROM apps');
    const [[tags]] = await conn.query('SELECT COUNT(*) AS n FROM tags');
    ok(`现有数据：${cats.n} 个分类 / ${apps.n} 个应用 / ${tags.n} 个标签`);
  }

  // ---------------------------------------------------------------- 多分类回填
  //
  // 老库里应用只有 apps.category_id（单分类），新的关联表是空的。
  // 不补的话「按分类筛选」会漏掉所有老应用。幂等，跑多少次都一样。
  step('补齐多分类关联表（app_categories）');
  const filled = await backfillAppCategories(conn);
  ok(`本次补了 ${filled} 条（已有的不会重复插入）`);

  // ---------------------------------------------------------------- 汇总
  const [tables] = await conn.query('SHOW TABLES');
  console.log('');
  console.log(`\x1b[32m✓ 初始化完成\x1b[0m  库 \`${dbName}\` 共 ${tables.length} 张表`);
  for (const row of tables) {
    const name = Object.values(row)[0];
    const [[cnt]] = await conn.query(
      `SELECT COUNT(*) AS n FROM \`${name}\``,
    );
    console.log(`    ${name.padEnd(16)} ${cnt.n} 行`);
  }
  console.log('');
  if (!wantSeed) {
    console.log('  想灌演示应用数据：npm run init -- --seed');
  }
  console.log('  启动服务：npm start');
  console.log('');

  await conn.end();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

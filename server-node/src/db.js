// server/src/db.js
//
// MySQL 连接池 + 查询辅助。
//
// 为什么用连接池而不是每次 createConnection：
//   每个 HTTP 请求建一次连接要 10~30ms，登录/市场列表这种高频接口
//   累计起来很可观，而且 MySQL 的 max_connections 很快会被吃满。

import mysql from 'mysql2/promise';
import { config } from './config.js';

export const pool = mysql.createPool({
  host: config.db.host,
  port: config.db.port,
  user: config.db.user,
  password: config.db.password,
  database: config.db.database,
  connectionLimit: config.db.connectionLimit,
  charset: 'utf8mb4',
  // 让 DATETIME 直接返回字符串而不是 JS Date：
  // MySQL 的 DATETIME 没有时区信息，转成 Date 会被按服务器本地时区解释，
  // 而客户端期望的是「原样的字符串」。省掉这次转换就省掉一类时区 bug。
  dateStrings: true,
  // 关闭「一次调用只允许一条语句」，避免把用户输入拼进多语句查询
  multipleStatements: false,
});

/** 查多行 */
export async function query(sql, params = []) {
  const [rows] = await pool.query(sql, params);
  return rows;
}

/** 查一行（没有则 null） */
export async function queryOne(sql, params = []) {
  const [rows] = await pool.query(sql, params);
  return rows.length > 0 ? rows[0] : null;
}

/** 写操作，返回 ResultSetHeader（含 insertId / affectedRows） */
export async function execute(sql, params = []) {
  const [result] = await pool.execute(sql, params);
  return result;
}

/** 在一个事务里跑一串操作 */
export async function transaction(fn) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const result = await fn(conn);
    await conn.commit();
    return result;
  } catch (e) {
    await conn.rollback();
    throw e;
  } finally {
    conn.release();
  }
}

/** 启动时探活：连不上要在启动阶段就报错，而不是等第一个请求 */
export async function ping() {
  const conn = await pool.getConnection();
  try {
    await conn.query('SELECT 1');
  } finally {
    conn.release();
  }
}

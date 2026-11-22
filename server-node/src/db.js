
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

/**
 * 关闭连接池。
 *
 * 优雅退出时必须调：容器发 SIGTERM 后，若还有连接没归还，
 * MySQL 会保留一段时间的 sleep 会话，滚动发布时很快把连接数吃满。
 */
export async function closePool() {
  try {
    await pool.end();
  } catch (e) {
    console.error('[db] 关闭连接池失败（忽略）', e?.message || e);
  }
}

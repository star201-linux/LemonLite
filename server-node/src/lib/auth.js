// server/src/lib/auth.js
//
// token 签发 / 校验 / 撤销。
//
// **0.4 起 token 是有状态会话，不是纯 JWT。**
//
// 为什么改：纯 JWT 签出去就没法收回 —— 用户点「退出登录」、
// 或者手机丢了想踢掉某台设备，服务端只能等到过期。现在每次鉴权都查
// login_sessions 表，撤销是一条 UPDATE 就生效。
//
// token 长什么样：
//   32 字节加密随机数 → base64url（43 字符）
//   形如 `lmn_3q2-7wXb...`
//   前缀 `lmn_` 是为了让人在日志/截图里一眼认出来「这是本服务的 token」，
//   也方便将来换格式时做区分。
//
// 数据库里存的是它的 **SHA-256**（不存明文）：
//   * 数据库泄露时，攻击者拿到哈希也算不出 token（输入是 256 位随机值）
//   * 不需要盐：随机 token 熵足够高，彩虹表无意义
//   * 校验时对收到的 token 做同样哈希再查主键，一次 B 树查找

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import bcrypt from 'bcryptjs';
import { config } from '../config.js';
import { execute, queryOne } from '../db.js';
import { ApiError } from './http.js';

const TOKEN_PREFIX = 'lmn_';
const TOKEN_BYTES = 32;

/** 生成一个新的 token 明文（只在这一刻存在于内存里） */
export function newToken() {
  return TOKEN_PREFIX + randomBytes(TOKEN_BYTES).toString('base64url');
}

/** token 明文 → 入库用的哈希 */
export function hashToken(token) {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

/** 常数时间比较两个十六进制串（防时序侧信道） */
function safeEqualHex(a, b) {
  if (a.length !== b.length) return false;
  try {
    return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
  } catch {
    return false;
  }
}

/** 生成密码哈希。永远不要在库里存明文。 */
export function hashPassword(plain) {
  return bcrypt.hash(plain, config.auth.bcryptRounds);
}

/** 校验密码。bcryptjs 的 compare 本身是常数时间比较。 */
export function verifyPassword(plain, hash) {
  return bcrypt.compare(plain, hash);
}

/**
 * 把一个「无效哈希」喂给 bcrypt。
 *
 * 用于登录时用户不存在的情况：仍然跑一次 bcrypt，让两种失败的耗时接近。
 * 否则「响应快 = 用户名不存在」本身就是一个用户名枚举信道。
 */
const DUMMY_HASH =
  '$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';

export async function burnPasswordTime(password) {
  await bcrypt.compare(password, DUMMY_HASH);
}

/**
 * 创建会话：插入 login_sessions 并返回 token 明文。
 *
 * @param {number} userId
 * @param {{ ip?: string, device?: string }} meta
 * @returns {Promise<{token: string, expiresAt: Date}>}
 */
export async function createSession(userId, { ip = '', device = '' } = {}) {
  const token = newToken();
  const tokenHash = hashToken(token);
  const ttlMs = parseDuration(config.auth.sessionTtl);
  const expiresAt = new Date(Date.now() + ttlMs);

  await execute(
    `INSERT INTO login_sessions
       (token_hash, user_id, expires_at, login_ip, device)
     VALUES (?, ?, ?, ?, ?)`,
    [tokenHash, userId, expiresAt, truncate(ip, 45), truncate(device, 128)],
  );

  return { token, expiresAt };
}

/**
 * 校验 token，返回 { userId, session } 或 null。
 *
 * 只查一次库，且是主键查询。过期 / 撤销 / 不存在都返回 null ——
 * 调用方统一当作「未登录」，不区分原因（避免信息泄露，也简化调用方）。
 */
export async function resolveSession(token) {
  if (!token || !token.startsWith(TOKEN_PREFIX)) return null;
  const tokenHash = hashToken(token);

  const row = await queryOne(
    `SELECT s.token_hash, s.user_id, s.expires_at, s.revoked,
            u.username, u.status
       FROM login_sessions s
       JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = ?
      LIMIT 1`,
    [tokenHash],
  );
  if (!row) return null;
  if (row.revoked) return null;
  if (row.status !== 'active') return null;

  // 过期判断放在 JS 里而不是 SQL 的 `expires_at > NOW()`：
  // 数据库时区与应用服务器时区可能不一致，用 JS 的 Date 比较
  // 至少两边用的是同一个时钟。datetime 是 dateStrings=true 读出来的字符串，
  // 这里显式按 UTC 解析（写入时 mysql2 也是按 UTC 序列化的）。
  const expires = new Date(row.expires_at.replace(' ', 'T') + 'Z');
  if (Number.isNaN(expires.getTime()) || expires.getTime() <= Date.now()) {
    return null;
  }

  return {
    userId: Number(row.user_id),
    username: row.username,
    tokenHash: row.token_hash,
    expiresAt: expires,
  };
}

/** 刷新 last_seen_at（不 await 的调用方应自己 catch） */
export async function touchSession(tokenHash) {
  await execute(
    'UPDATE login_sessions SET last_seen_at = CURRENT_TIMESTAMP(3) WHERE token_hash = ?',
    [tokenHash],
  );
}

/** 撤销单个会话（退出登录） */
export async function revokeSession(tokenHash) {
  await execute(
    'UPDATE login_sessions SET revoked = 1 WHERE token_hash = ?',
    [tokenHash],
  );
}

/** 撤销某用户的全部会话（「退出所有设备」/ 改密码后强制重登） */
export async function revokeAllSessions(userId, { except = null } = {}) {
  if (except) {
    await execute(
      'UPDATE login_sessions SET revoked = 1 WHERE user_id = ? AND token_hash <> ?',
      [userId, except],
    );
  } else {
    await execute('UPDATE login_sessions SET revoked = 1 WHERE user_id = ?', [
      userId,
    ]);
  }
}

/** 该用户当前有效的会话列表（给「我的登录设备」用） */
export async function listSessions(userId) {
  const rows = await queryOne('SELECT 1'); // 保持 query 用法一致；下面是真查询
  void rows;
  const { query } = await import('../db.js');
  return query(
    `SELECT token_hash, created_at, last_seen_at, expires_at, login_ip, device
       FROM login_sessions
      WHERE user_id = ? AND revoked = 0 AND expires_at > UTC_TIMESTAMP(3)
      ORDER BY last_seen_at DESC
      LIMIT 50`,
    [userId],
  );
}

/** 清理过期且已撤销 / 过期很久的行（运维脚本或定时任务调用） */
export async function pruneSessions() {
  const result = await execute(
    `DELETE FROM login_sessions
      WHERE expires_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL 30 DAY)`,
  );
  return result.affectedRows;
}

// ---------------------------------------------------------------- 中间件

function extractToken(req) {
  const header = req.get('authorization') || '';
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  return m ? m[1].trim() : null;
}

/**
 * 必须登录。成功后 req.auth = { userId, username, tokenHash }。
 *
 * 每次请求都查一次库 —— 这是有状态会话的代价，也是它能「立刻撤销」的原因。
 * 主键查询 + 连接池，实测在亚毫秒级，比业务查询本身便宜得多。
 */
export async function requireAuth(req, _res, next) {
  try {
    const token = extractToken(req);
    if (!token) throw ApiError.unauthorized();

    const session = await resolveSession(token);
    if (!session) throw ApiError.unauthorized('登录已失效，请重新登录');

    req.auth = session;

    // 顺手更新 last_seen_at。每 60 秒才写一次，避免每个请求都产生一次 UPDATE
    // （高频接口上这会变成显著的写放大）。用一个进程内的时间戳表做节流。
    maybeTouch(session.tokenHash);

    return next();
  } catch (e) {
    return next(e);
  }
}

/** 有就解析，没有也放行（市场接口用） */
export async function optionalAuth(req, _res, next) {
  try {
    const token = extractToken(req);
    if (token) {
      const session = await resolveSession(token);
      if (session) {
        req.auth = session;
        maybeTouch(session.tokenHash);
      }
    }
  } catch {
    // 解析失败当作未登录，**不要** 401 —— 否则「可选登录」变成事实上的强制
  }
  return next();
}

// last_seen_at 节流：token 哈希 → 上次写入的毫秒时间
const _lastTouch = new Map();
const TOUCH_INTERVAL_MS = 60_000;

function maybeTouch(tokenHash) {
  const now = Date.now();
  const prev = _lastTouch.get(tokenHash) ?? 0;
  if (now - prev < TOUCH_INTERVAL_MS) return;
  _lastTouch.set(tokenHash, now);

  // 表不要无限增长：超过 5000 个 token 时清掉最旧的一半记录
  if (_lastTouch.size > 5000) {
    const entries = [..._lastTouch.entries()].sort((a, b) => a[1] - b[1]);
    for (const [k] of entries.slice(0, 2500)) _lastTouch.delete(k);
  }

  touchSession(tokenHash).catch((e) => {
    // 写失败不该影响请求本身
    console.warn('[auth] last_seen_at 更新失败', e.code || e.message);
  });
}

/** 当前登录用户 id（number）；未登录返回 null */
export function currentUserId(req) {
  return req.auth?.userId ?? null;
}

// ---------------------------------------------------------------- 小工具

function truncate(value, max) {
  const s = String(value ?? '');
  return s.length <= max ? s : s.slice(0, max);
}

/**
 * 解析 `7d` / `12h` / `30m` / `3600s` / 纯毫秒数。
 * 只支持这几种 —— 够用，且不会像 ms 库那样为了兼容一堆写法牺牲可读性。
 */
function parseDuration(input) {
  const s = String(input ?? '').trim();
  const m = /^(\d+)\s*(ms|s|m|h|d)?$/.exec(s);
  if (!m) return 7 * 24 * 3600 * 1000;
  const n = Number.parseInt(m[1], 10);
  switch (m[2]) {
    case 'ms':
      return n;
    case 's':
      return n * 1000;
    case 'm':
      return n * 60 * 1000;
    case 'h':
      return n * 3600 * 1000;
    case 'd':
      return n * 24 * 3600 * 1000;
    default:
      return n;
  }
}

// safeEqualHex 目前没用到（查库是按哈希主键查，不涉及比较），
// 保留导出以便将来做「token 前缀提示」之类需要常数时间比较的场景。
export { TOKEN_PREFIX, safeEqualHex };

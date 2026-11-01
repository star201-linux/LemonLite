// server/src/lib/email_codes.js
//
// 邮箱验证码的签发与核验。
//
// 这里管三件事，缺一件就会被刷：
//   1. 生成：密码学随机数，不用 Math.random（后者可预测）。
//   2. 限流：冷却（同一邮箱 60s 一次）+ 小时配额（邮箱 / IP 各一条线）。
//   3. 核验：一次性、限次数、常量时间比较。
//
// 时间一律由 **应用进程** 算好再写库，不用 MySQL 的 NOW()。
// 原因：DATETIME 没有时区信息，数据库与 Node 进程时区不一致时
// 「过期了没有」会判错，而且这种错很难复现。统一用 UTC 字符串就没有歧义。

import { createHash, randomInt, timingSafeEqual } from 'node:crypto';
import { execute, query, queryOne } from '../db.js';
import { config } from '../config.js';
import { ApiError } from './http.js';

/** 允许的用途。先只开注册，reset 的结构留好了，加接口即可。 */
export const PURPOSES = Object.freeze(['register']);

/**
 * Date → MySQL DATETIME(3) 字符串（UTC）。
 * 例：2026-11-01T08:21:56.123Z → '2026-11-01 08:21:56.123'
 */
function toSqlTime(date) {
  return date.toISOString().slice(0, 23).replace('T', ' ');
}

/** MySQL 返回的 DATETIME(3) 字符串（按 UTC 存）→ Date */
function fromSqlTime(value) {
  if (value instanceof Date) return value;
  if (typeof value !== 'string' || !value) return new Date(Number.NaN);
  return new Date(`${value.slice(0, 19).replace(' ', 'T')}Z`);
}

/** 邮箱归一化：与 users 表一致（小写 + trim） */
export function normalizeEmail(raw) {
  return String(raw ?? '').trim().toLowerCase();
}

/** 生成指定位数的数字验证码（首位允许 0，因为用户是复制粘贴的） */
export function generateCode(length = config.mail.codeLength) {
  const digits = Math.min(8, Math.max(4, length));
  let out = '';
  for (let i = 0; i < digits; i += 1) out += String(randomInt(0, 10));
  return out;
}

/**
 * 验证码的哈希：sha256(email|purpose|code)。
 *
 * 把 email 与 purpose 一起拌进去，是为了让「同一串数字发给不同人」
 * 得到不同哈希 —— 否则库里的哈希可以直接被拿去撞别人的码。
 */
export function hashCode(email, purpose, code) {
  return createHash('sha256')
    .update(`${normalizeEmail(email)}|${purpose}|${String(code).trim()}`)
    .digest('hex');
}

/** 常量时间比较两个十六进制摘要 */
function digestEquals(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const bufA = Buffer.from(a, 'hex');
  const bufB = Buffer.from(b, 'hex');
  if (bufA.length !== bufB.length || bufA.length === 0) return false;
  return timingSafeEqual(bufA, bufB);
}

/**
 * 签发一个验证码并写入数据库。
 *
 * 返回 { code, expiresAt } —— 明文 code 只在这里出现一次，
 * 调用方负责把它送进邮件，**不要**写进日志或响应（除非开了 devEchoCode）。
 *
 * 限流失败抛 ApiError（429），调用方直接往外抛即可。
 */
export async function issueCode({ email, purpose = 'register', ip = '' }) {
  const target = normalizeEmail(email);
  const now = new Date();

  // ---- 冷却：同一个邮箱两次索要之间要隔一会儿
  const latest = await queryOne(
    `SELECT created_at FROM email_codes
      WHERE email = ? AND purpose = ?
      ORDER BY id DESC LIMIT 1`,
    [target, purpose],
  );
  if (latest) {
    const waited = (now.getTime() - fromSqlTime(latest.created_at).getTime()) / 1000;
    if (waited < config.mail.codeCooldown) {
      const retryAfter = Math.ceil(config.mail.codeCooldown - waited);
      throw new ApiError(
        429,
        'code_cooldown',
        `请等 ${retryAfter} 秒后再获取验证码`,
        { retryAfter },
      );
    }
  }

  // ---- 小时配额（邮箱维度）
  const hourAgo = toSqlTime(new Date(now.getTime() - 3600 * 1000));
  const byEmail = await queryOne(
    `SELECT COUNT(*) AS n FROM email_codes
      WHERE email = ? AND purpose = ? AND created_at >= ?`,
    [target, purpose, hourAgo],
  );
  if (Number(byEmail?.n ?? 0) >= config.mail.codeMaxPerEmailHour) {
    throw new ApiError(429, 'code_rate_limited', '这个邮箱获取验证码太频繁了，请稍后再试', {
      limit: 'email',
    });
  }

  // ---- 小时配额（IP 维度）：空 IP 不计（内网/代理后面拿不到就不硬算）
  if (ip) {
    const byIp = await queryOne(
      'SELECT COUNT(*) AS n FROM email_codes WHERE ip = ? AND created_at >= ?',
      [ip, hourAgo],
    );
    if (Number(byIp?.n ?? 0) >= config.mail.codeMaxPerIpHour) {
      throw new ApiError(429, 'code_rate_limited', '当前网络获取验证码太频繁了，请稍后再试', {
        limit: 'ip',
      });
    }
  }

  // ---- 生成并落库。同一个邮箱旧的未用码直接作废：用户收到第二封后
  //      应该只认最新那一个，留着一堆有效码只会让「试出来」的概率变大。
  const code = generateCode();
  const expiresAt = new Date(now.getTime() + config.mail.codeTtl * 1000);
  await execute(
    `UPDATE email_codes SET consumed = 1
      WHERE email = ? AND purpose = ? AND consumed = 0`,
    [target, purpose],
  );
  const result = await execute(
    `INSERT INTO email_codes (email, purpose, code_hash, ip, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
    [
      target,
      purpose,
      hashCode(target, purpose, code),
      String(ip ?? '').slice(0, 45),
      toSqlTime(now),
      toSqlTime(expiresAt),
    ],
  );

  return { id: result.insertId, code, expiresAt };
}

/**
 * 核验验证码，成功后立刻作废（一次性）。
 *
 * 抛的错都带明确 code，客户端据此决定「提示什么、要不要让用户重填邮箱」：
 *   code_missing   从没获取过
 *   code_expired   过期了
 *   code_locked    输错太多次，需要重新获取
 *   invalid_code   不正确
 */
export async function consumeCode({ email, purpose = 'register', code }) {
  const target = normalizeEmail(email);
  const row = await queryOne(
    `SELECT * FROM email_codes
      WHERE email = ? AND purpose = ? AND consumed = 0
      ORDER BY id DESC LIMIT 1`,
    [target, purpose],
  );

  if (!row) throw ApiError.badRequest('code_missing', '请先获取邮箱验证码');
  if (fromSqlTime(row.expires_at).getTime() <= Date.now()) {
    throw ApiError.badRequest('code_expired', '验证码已过期，请重新获取');
  }
  if (Number(row.attempts) >= config.mail.codeMaxAttempts) {
    throw new ApiError(429, 'code_locked', '验证码错误次数过多，请重新获取');
  }

  const expected = String(row.code_hash ?? '');
  if (!digestEquals(expected, hashCode(target, purpose, code))) {
    // 输错也计数：否则 6 位数字只有一百万种，慢慢试总能撞上。
    await execute('UPDATE email_codes SET attempts = attempts + 1 WHERE id = ?', [row.id]);
    const left = config.mail.codeMaxAttempts - Number(row.attempts) - 1;
    throw ApiError.badRequest(
      'invalid_code',
      left > 0 ? `验证码不正确，还可以再试 ${left} 次` : '验证码不正确，请重新获取',
    );
  }

  await execute('UPDATE email_codes SET consumed = 1 WHERE id = ?', [row.id]);
  // 顺手把这个邮箱其余的待用码一起废掉
  await execute(
    `UPDATE email_codes SET consumed = 1
      WHERE email = ? AND purpose = ? AND consumed = 0`,
    [target, purpose],
  );
  return true;
}

/**
 * 丢弃刚签发的那条验证码。
 *
 * 场景：码已经落库，但邮件发失败了。留着它有两个坏处：
 *   * 用户会在 60 秒冷却里干等一个永远收不到的信；
 *   * 库里多一条「有效但无人知晓」的码。
 * 所以发信失败时把它删掉，让用户可以立刻重试。
 */
export async function discardCode(id) {
  if (!id) return;
  await execute('DELETE FROM email_codes WHERE id = ?', [id]);
}

/** 清理过期一天以上的验证码（由 npm run prune 调用） */
export async function purgeExpiredCodes() {
  const cutoff = toSqlTime(new Date(Date.now() - 24 * 3600 * 1000));
  const result = await execute('DELETE FROM email_codes WHERE expires_at < ?', [cutoff]);
  return result.affectedRows ?? 0;
}

/** 给「这条邮箱还能不能再要一次」用的冷却剩余秒数（0 = 可以） */
export async function cooldownRemaining(email, purpose = 'register') {
  const target = normalizeEmail(email);
  const latest = await queryOne(
    `SELECT created_at FROM email_codes
      WHERE email = ? AND purpose = ? ORDER BY id DESC LIMIT 1`,
    [target, purpose],
  );
  if (!latest) return 0;
  const waited = (Date.now() - fromSqlTime(latest.created_at).getTime()) / 1000;
  return Math.max(0, Math.ceil(config.mail.codeCooldown - waited));
}

/** 统计（运维看一眼就知道有没有人刷） */
export async function recentCodeStats() {
  const rows = await query(
    `SELECT email, COUNT(*) AS n FROM email_codes
      WHERE created_at >= ?
      GROUP BY email ORDER BY n DESC LIMIT 10`,
    [toSqlTime(new Date(Date.now() - 24 * 3600 * 1000))],
  );
  return rows;
}

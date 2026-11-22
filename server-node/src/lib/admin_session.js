
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

export const SESSION_VERSION = 'v1';

/** 32 字节随机密钥（hex 文本存 .env） */
export function newAdminSecret() {
  return randomBytes(32).toString('hex');
}

function sign(secret, payload, passwordHash) {
  return createHmac('sha256', secret)
    .update(`${payload}.${passwordHash}`, 'utf8')
    .digest('base64url');
}

/**
 * 签发一个会话 cookie 值。
 * @param {{id: number, passwordHash: string, secret: string, ttlMs: number}} o
 */
export function createAdminSession({ id, passwordHash, secret, ttlMs }) {
  if (!secret) throw new Error('管理面板签名密钥未初始化');
  if (!Number.isSafeInteger(id) || id <= 0) throw new Error('管理账号 id 不合法');
  const expires = Date.now() + ttlMs;
  const payload = `${SESSION_VERSION}.${id}.${expires}`;
  return `${payload}.${sign(secret, payload, passwordHash)}`;
}

/**
 * 只做格式解析，**不做**签名校验（校验还需要密钥与 password_hash）。
 * 解析失败一律返回 null，绝不抛异常 —— 坏 cookie 是常态，不是错误。
 */
export function parseAdminSession(raw) {
  const value = String(raw ?? '').trim();
  if (value.length < 12 || value.length > 256) return null;
  const last = value.lastIndexOf('.');
  if (last <= 0) return null;
  const payload = value.slice(0, last);
  const signature = value.slice(last + 1);
  if (!signature) return null;
  const parts = payload.split('.');
  if (parts.length !== 3 || parts[0] !== SESSION_VERSION) return null;
  const id = Number.parseInt(parts[1], 10);
  const expires = Number.parseInt(parts[2], 10);
  if (!Number.isSafeInteger(id) || id <= 0) return null;
  if (!Number.isFinite(expires) || expires <= 0) return null;
  return { id, expires, payload, signature };
}

/**
 * 校验签名与有效期。
 * 签名用 `timingSafeEqual` 比较 —— 逐字节比 `===` 会泄露「前多少字节对」。
 */
export function verifyAdminSession(parsed, { secret, passwordHash, now = Date.now() }) {
  if (!parsed || !secret || !passwordHash) return false;
  if (parsed.expires <= now) return false;
  const expected = Buffer.from(sign(secret, parsed.payload, passwordHash));
  const actual = Buffer.from(parsed.signature);
  if (expected.length !== actual.length) return false;
  try {
    return timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------- 账号校验

/** 3~32 位，字母数字开头，可含 _ . - ；不允许中文，避免登录时输入法/空格问题 */
export const ADMIN_USERNAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{2,31}$/;
export const ADMIN_PASSWORD_MIN = 8;
export const ADMIN_PASSWORD_MAX = 128;

/** @returns {string|null} 不合法时返回人话，合法返回 null */
export function validateAdminUsername(name) {
  const value = String(name ?? '').trim();
  if (!value) return '用户名不能为空';
  if (!ADMIN_USERNAME_RE.test(value)) {
    return '用户名要 3~32 位，只能用字母、数字、下划线、点和连字符，且以字母或数字开头';
  }
  return null;
}

/** @returns {string|null} 不合法时返回人话，合法返回 null */
export function validateAdminPassword(password) {
  const value = String(password ?? '');
  if (value.length < ADMIN_PASSWORD_MIN) return `密码至少 ${ADMIN_PASSWORD_MIN} 位`;
  if (value.length > ADMIN_PASSWORD_MAX) return `密码最多 ${ADMIN_PASSWORD_MAX} 位`;
  return null;
}

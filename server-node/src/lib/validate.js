
import { ApiError } from './http.js';

export const USERNAME_MIN = 3;
export const USERNAME_MAX = 32;
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 128;

/**
 * 用户名：3~32 字符，允许中文 / 字母 / 数字 / 下划线 / 连字符 / 点，
 * 不允许纯数字（会和 id、手机号混淆，也容易被扫号）。
 */
export function validateUsername(raw) {
  const name = String(raw ?? '').trim();
  if (name.length < USERNAME_MIN || name.length > USERNAME_MAX) {
    throw ApiError.badRequest(
      'invalid_username',
      `用户名需要 ${USERNAME_MIN}~${USERNAME_MAX} 个字符`,
    );
  }
  if (!/^[\p{L}\p{N}_.-]+$/u.test(name)) {
    throw ApiError.badRequest(
      'invalid_username',
      '用户名只能包含中文、字母、数字、下划线、连字符和点',
    );
  }
  if (/^\d+$/.test(name)) {
    throw ApiError.badRequest('invalid_username', '用户名不能是纯数字');
  }
  return name;
}

/** 邮箱：统一小写（库里按 utf8mb4_0900_ai_ci 比较，大小写本来就不敏感） */
export function validateEmail(raw) {
  const email = String(raw ?? '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) {
    throw ApiError.badRequest('invalid_email', '邮箱格式不正确');
  }
  if (email.length > 255) {
    throw ApiError.badRequest('invalid_email', '邮箱过长');
  }
  return email;
}

export function validatePassword(raw) {
  const pw = String(raw ?? '');
  if (pw.length < PASSWORD_MIN) {
    throw ApiError.badRequest('weak_password', `密码至少 ${PASSWORD_MIN} 位`);
  }
  if (pw.length > PASSWORD_MAX) {
    // 上限是为了防止 bcrypt 被超长输入拖慢（DoS）
    throw ApiError.badRequest('invalid_password', '密码过长');
  }
  return pw;
}

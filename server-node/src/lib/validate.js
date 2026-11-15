// server/src/lib/validate.js
//
// 用户名 / 邮箱 / 密码的校验规则。
//
// 为什么抽成独立模块：注册、改资料、换邮箱、**管理面板代改** 都要用同一套规则。
// 面板如果自己写一份「大概差不多」的校验，迟早出现「面板能存进去、客户端
// 登录不上」的数据 —— 那种不一致排查起来非常费劲。
//
// 规则本身刻意宽松：
//   * 用户名允许中文（这个产品面向中文用户，「小明」比「xiaoming123」更常见）；
//   * 邮箱不追求 RFC 5322 全兼容（那串正则没人能维护），只保证
//     「有本地部分、有 @、域名里有点」；
//   * 密码只卡长度，不强制大小写与符号 —— 强制复杂度反而促使用户在末尾加个 1。

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

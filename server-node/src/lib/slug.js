// server/src/lib/slug.js
//
// 分类 id / 标签 slug 的生成规则。
//
// 为什么不让用户随便填 id：这两个值会出现在 URL 与接口参数里
// （`/api/market/feed?category=tools`），任意字符串既不好看也不安全。
// 规则统一成「小写字母数字 + _ -」，最长 32。
//
// 中文名没法直接转成 ASCII：`slugify('效率')` 返回空串，
// 调用方就退回 `randomId('cat')` —— 一个稳定的随机 id 也比
// 「中文拼进 URL 再被各种编码」好排查。

import { randomBytes } from 'node:crypto';

const ID_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;

/** 名字 → 候选 id；转不出来返回空串 */
export function slugify(name) {
  const ascii = String(name ?? '')
    .normalize('NFKD')
    // 去掉声调符号（café → cafe）
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    // 非字母数字一律变连字符
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 28);
  return ascii;
}

/** 形如 cat_1a2b3c4d 的随机 id（8 位十六进制，碰撞概率可以忽略） */
export function randomId(prefix) {
  return `${prefix}_${randomBytes(4).toString('hex')}`;
}

/** 是否是一个合法的 id / slug */
export function isValidId(value) {
  return ID_RE.test(String(value ?? ''));
}

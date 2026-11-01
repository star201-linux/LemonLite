// test/admin.test.js
//
// 管理面板里那些纯函数：签名 cookie、账号校验、id 生成、SQL 切分。
// 这些逻辑出错的后果都挺严重（会话伪造 / 面板进不去 / 建表漏语句），
// 但它们本身没有 IO，所以值得单独测。

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createAdminSession,
  newAdminSecret,
  parseAdminSession,
  validateAdminPassword,
  validateAdminUsername,
  verifyAdminSession,
} from '../src/lib/admin_session.js';
import { isValidId, randomId, slugify } from '../src/lib/slug.js';
import { splitStatements } from '../src/lib/sqlfile.js';

const SECRET = 'a'.repeat(64);
const HASH = '$2a$10$abcdefghijklmnopqrstuv';

test('会话 cookie：签发 → 解析 → 校验通过', () => {
  const raw = createAdminSession({ id: 7, passwordHash: HASH, secret: SECRET, ttlMs: 60_000 });
  const parsed = parseAdminSession(raw);
  assert.equal(parsed.id, 7);
  assert.ok(parsed.expires > Date.now());
  assert.equal(verifyAdminSession(parsed, { secret: SECRET, passwordHash: HASH }), true);
});

test('会话 cookie：改一个字符就校验失败', () => {
  const raw = createAdminSession({ id: 7, passwordHash: HASH, secret: SECRET, ttlMs: 60_000 });
  const parsed = parseAdminSession(raw);
  assert.equal(
    verifyAdminSession(parsed, { secret: SECRET, passwordHash: HASH.replace('a', 'b') }),
    false,
  );
  assert.equal(verifyAdminSession(parsed, { secret: newAdminSecret(), passwordHash: HASH }), false);
  // 改签名本身
  const tampered = parseAdminSession(raw.slice(0, -1) + (raw.endsWith('A') ? 'B' : 'A'));
  assert.equal(verifyAdminSession(tampered, { secret: SECRET, passwordHash: HASH }), false);
});

test('会话 cookie：过期即失败，且换密码会让旧 cookie 失效', () => {
  const raw = createAdminSession({ id: 3, passwordHash: HASH, secret: SECRET, ttlMs: -1 });
  const parsed = parseAdminSession(raw);
  assert.equal(verifyAdminSession(parsed, { secret: SECRET, passwordHash: HASH }), false);

  // 换密码 = password_hash 变 = 同一份 cookie 校验不过（这正是「改密即踢人」）
  const fresh = createAdminSession({ id: 3, passwordHash: HASH, secret: SECRET, ttlMs: 60_000 });
  const freshParsed = parseAdminSession(fresh);
  assert.equal(
    verifyAdminSession(freshParsed, { secret: SECRET, passwordHash: HASH + 'x' }),
    false,
  );
});

test('会话 cookie：垃圾输入一律返回 null，不抛异常', () => {
  for (const bad of ['', 'abc', 'v1.1', 'v2.1.9999999999999.sig', 'v1.0.1.sig', 'v1.x.1.sig']) {
    assert.equal(parseAdminSession(bad), null, `应拒绝 ${bad}`);
  }
});

test('管理员用户名 / 密码的校验规则', () => {
  assert.equal(validateAdminUsername('admin'), null);
  assert.equal(validateAdminUsername('a_b-c.d'), null);
  assert.ok(validateAdminUsername('ab'));
  assert.ok(validateAdminUsername('-abc'));
  assert.ok(validateAdminUsername('中文名'));
  assert.ok(validateAdminUsername(''));

  assert.equal(validateAdminPassword('12345678'), null);
  assert.ok(validateAdminPassword('1234567'));
  assert.ok(validateAdminPassword('x'.repeat(129)));
});

test('slug：英文转 id，中文退回随机 id', () => {
  assert.equal(slugify('Tools'), 'tools');
  assert.equal(slugify('Café & Bar'), 'cafe-bar');
  assert.equal(slugify('效率'), '');
  const id = randomId('cat');
  assert.match(id, /^cat_[0-9a-f]{8}$/);
  assert.equal(isValidId(id), true);
  assert.equal(isValidId('Tools'), false);
  assert.equal(isValidId('-bad'), false);
  assert.equal(isValidId('x'.repeat(33)), false);
});

test('SQL 切分：去掉整行注释与 SET NAMES，保留语句', () => {
  const sql = [
    '-- 头部注释',
    'SET NAMES utf8mb4;',
    '',
    'CREATE TABLE IF NOT EXISTS a (id INT);',
    '-- 中间注释',
    'CREATE TABLE IF NOT EXISTS b (id INT);',
  ].join('\n');
  const statements = splitStatements(sql);
  assert.equal(statements.length, 2);
  assert.match(statements[0], /CREATE TABLE IF NOT EXISTS a/);
  assert.match(statements[1], /CREATE TABLE IF NOT EXISTS b/);
});

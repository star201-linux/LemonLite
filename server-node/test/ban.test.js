// test/ban.test.js
//
// 封禁的时长解析与状态判断。
//
// 这里钉的是三件事：
//   1. `-1` 是永久，**不是**「负一天」；
//   2. 永久封禁的 banned_until 是 NULL，不能被「到期」判断顺手放过
//      （SQL 里 NULL 比较恒为 NULL，但 JS 里 `null` 转数字是 0 —— 很容易写错）；
//   3. 临时封禁到期后 `banBlocks` 立刻返回 false，不用等清理任务。

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  banBlocks,
  banInfo,
  banMessage,
  parseBanDuration,
} from '../src/lib/ban.js';

const DAY = 24 * 3600 * 1000;

function utcString(offsetMs) {
  return new Date(Date.now() + offsetMs)
    .toISOString()
    .slice(0, 23)
    .replace('T', ' ');
}

test('-1 = 永久：until 为 null', () => {
  const parsed = parseBanDuration(-1);
  assert.equal(parsed.until, null);
  assert.equal(parsed.days, -1);
});

test('正整数天 → 到期时间是 now + N 天', () => {
  const parsed = parseBanDuration(3);
  assert.ok(parsed.until instanceof Date);
  const delta = parsed.until.getTime() - Date.now();
  assert.ok(delta > 3 * DAY - 5000 && delta <= 3 * DAY, String(delta));
});

test('0 / 负数（除了 -1）/ 非数字都要拒绝', () => {
  for (const bad of [0, -2, -100, '', 'abc', null, undefined, 1.5e9]) {
    assert.throws(() => parseBanDuration(bad), /封禁时长/, String(bad));
  }
});

test('超过上限被拒（防止多打一个 0 变成一百年）', () => {
  assert.throws(() => parseBanDuration(3651), /封禁时长/);
});

test('字符串形式也能解析（表单提交都是字符串）', () => {
  assert.equal(parseBanDuration('7').days, 7);
  assert.equal(parseBanDuration('-1').until, null);
});

test('正常账号：banInfo 为 null，banBlocks 为 false', () => {
  const row = { status: 'active', banned_until: null, ban_reason: '' };
  assert.equal(banInfo(row), null);
  assert.equal(banBlocks(row), false);
});

test('永久封禁：banInfo.permanent = true，until = null', () => {
  const row = { status: 'disabled', banned_until: null, ban_reason: '刷广告' };
  const info = banInfo(row);
  assert.equal(info.permanent, true);
  assert.equal(info.until, null);
  assert.equal(info.reason, '刷广告');
  assert.equal(info.daysLeft, -1);
  assert.equal(banBlocks(row), true);
});

test('临时封禁：到期前拦住，到期后放行（不依赖清理任务）', () => {
  const future = { status: 'disabled', banned_until: utcString(2 * DAY) };
  assert.equal(banBlocks(future), true);
  assert.equal(banInfo(future).daysLeft, 2);

  const past = { status: 'disabled', banned_until: utcString(-1 * DAY) };
  assert.equal(banBlocks(past), false);
  // 但状态字段还没改，banInfo 仍然能读出「曾经封过」——
  // 面板据此知道该显示「即将到期」而不是「未封禁」。
  assert.equal(banInfo(past).permanent, false);
});

test('提示语带到期时间与原因', () => {
  const perm = banMessage({
    status: 'disabled',
    banned_until: null,
    ban_reason: '违规',
  });
  assert.match(perm, /永久封禁/);
  assert.match(perm, /违规/);

  const temp = banMessage({
    status: 'disabled',
    banned_until: utcString(DAY),
    ban_reason: '',
  });
  assert.match(temp, /封禁至/);
  assert.ok(!temp.includes('原因'));
});

test('坏时间字符串按「永久」处理（宁可多拦一次，也别放过）', () => {
  const row = { status: 'disabled', banned_until: 'not-a-date' };
  assert.equal(banBlocks(row), true);
});

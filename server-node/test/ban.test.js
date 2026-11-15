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
  parseBanHours,
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

test('小时口径：0 天 1 小时 = 1 小时，不是 1 天', () => {
  const parsed = parseBanHours(1);
  const delta = parsed.until.getTime() - Date.now();
  assert.ok(delta > 3600_000 - 5000 && delta <= 3600_000, String(delta));
  assert.equal(parsed.hours, 1);
  // 兼容字段向上取整，只用于「天数」口径的老调用方
  assert.equal(parsed.days, 1);
});

test('小时口径：1 天 2 小时 = 26 小时', () => {
  assert.equal(parseBanHours(26).hours, 26);
  assert.equal(parseBanHours(26).days, 2);
});

test('小时口径：-1 仍是永久，0 与负数（除 -1）被拒', () => {
  assert.equal(parseBanHours(-1).until, null);
  assert.equal(parseBanHours('-1').hours, -1);
  for (const bad of [0, -2, '', 'abc', null, undefined, 1.5, '1.5', '2 小时']) {
    assert.throws(() => parseBanHours(bad), /封禁时长/, String(bad));
  }
});

test('小时口径：上限 3650 天，多 1 小时也拒', () => {
  assert.equal(parseBanHours(3650 * 24).hours, 3650 * 24);
  assert.throws(() => parseBanHours(3650 * 24 + 1), /封禁时长/);
});

test('天数口径不再被 parseInt 糊弄：1.5 天 / "7 天" 都拒', () => {
  for (const bad of [1.5, '1.5', '7 天']) {
    assert.throws(() => parseBanDuration(bad), /封禁时长/, String(bad));
  }
  assert.equal(parseBanDuration(' 7 ').days, 7);
});

test('剩余时长按小时算，封 1 小时不会显示成「剩 1 天」', () => {
  const row = {
    status: 'disabled',
    banned_until: utcString(3600_000),
    ban_reason: '',
  };
  const info = banInfo(row);
  assert.equal(info.hoursLeft, 1);
  // 老字段保持原语义（向上取整的天数），不影响已上线的客户端
  assert.equal(info.daysLeft, 1);
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

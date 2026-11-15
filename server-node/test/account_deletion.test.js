// test/account_deletion.test.js
//
// 注销冷静期的时间换算。
//
// 这里最容易错的是**时区**：数据库存的是 UTC 的
// 'YYYY-MM-DD HH:mm:ss.SSS' 字符串，如果按本地时间解析，
// 东八区会凭空多出 8 小时 —— 用户刚点注销，界面却显示「还剩 6 天」。
// 所以专门钉住：纯 UTC 解析 + daysLeft 向上取整。

import test from 'node:test';
import assert from 'node:assert/strict';

import { deletionInfo } from '../src/lib/account_deletion.js';

const DAY = 24 * 3600 * 1000;

/** 把毫秒偏移变成服务端那种 UTC 字符串 */
function utcString(offsetMs) {
  return new Date(Date.now() + offsetMs)
    .toISOString()
    .slice(0, 23)
    .replace('T', ' ');
}

test('没有申请过 → null', () => {
  assert.equal(deletionInfo({ deletion_scheduled_at: null }), null);
  assert.equal(deletionInfo({}), null);
  assert.equal(deletionInfo(null), null);
});

test('还剩 6 天多 → 显示 7 天（ceil，不出现「还剩 0 天却没删」）', () => {
  const info = deletionInfo({
    deletion_requested_at: utcString(0),
    deletion_scheduled_at: utcString(6.2 * DAY),
  });
  assert.equal(info.daysLeft, 7);
  assert.equal(info.due, false);
});

test('刚申请 7 天 → 7 天', () => {
  const info = deletionInfo({
    deletion_requested_at: utcString(0),
    deletion_scheduled_at: utcString(7 * DAY),
  });
  assert.equal(info.daysLeft, 7);
});

test('已过期 → due = true，daysLeft = 0', () => {
  const info = deletionInfo({
    deletion_requested_at: utcString(-10 * DAY),
    deletion_scheduled_at: utcString(-1 * DAY),
  });
  assert.equal(info.due, true);
  assert.equal(info.daysLeft, 0);
});

test('坏时间字符串按「没有排期」处理，不抛异常', () => {
  assert.equal(deletionInfo({ deletion_scheduled_at: 'not-a-date' }), null);
});

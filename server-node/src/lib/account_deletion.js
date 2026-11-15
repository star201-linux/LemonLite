// server/src/lib/account_deletion.js
//
// 注销账号：**申请 → 冷静期 → 物理删除** 三段式。
//
// 为什么不点一下就删：
//   * 注销是不可逆的。手滑、赌气、被盗号后被人点一下，数据就没了；
//   * 冷静期给了「后悔」和「被盗后自救」的窗口 —— 期间照常登录，
//     登录后在账号页一键撤销即可。
//
// 为什么服务端面板可以「立即删除」：
//   运营侧要能处理「用户写信要求马上删」「这个号在发垃圾内容」这类情况。
//   面板的删除**跳过冷静期**（先撤销全部会话，再删数据与行），
//   与客户端申请是两条不同的入口，共用一个 purgeUser()。
//
// 删除时机：
//   1. 启动时扫一次（进程重启后不会漏掉到期账号）；
//   2. 每 ACCOUNT_PURGE_INTERVAL_MINUTES 分钟扫一次（默认 30）；
//   3. npm run prune（crontab 兜底）；
//   4. 到期后即使还没被扫到，resolveSession() 也会拒绝这个账号的 token
//      —— 用户看到的是「登录已失效」，而不是「过期了却还能用」。
//
// 删除范围：users 行 + login_sessions（外键 CASCADE）+ userdata/<id>/ 目录。
// 邮件验证码按邮箱存，不在这里删：它们本来就只留一天（见 prune）。

import { rm } from 'node:fs/promises';
import { config } from '../config.js';
import { execute, query } from '../db.js';
import { revokeAllSessions } from './auth.js';
import { userDir } from './userdata.js';

const DAY_MS = 24 * 3600 * 1000;

/** Date → MySQL DATETIME(3) 的 UTC 字符串（与 lib/auth.js 的写法一致） */
function sqlTime(date) {
  return new Date(date.getTime()).toISOString().slice(0, 23).replace('T', ' ');
}

/**
 * 'YYYY-MM-DD HH:mm:ss.SSS'（UTC，mysql2 dateStrings）→ Date。
 * 解析失败返回 null，调用方按「没有排期」处理。
 */
function parseSqlTime(value) {
  if (!value) return null;
  const d = new Date(`${String(value).replace(' ', 'T')}Z`);
  return Number.isNaN(d.getTime()) ? null : d;
}

/**
 * 数据库行 → 对外的注销状态。没有申请过就返回 null。
 *
 * daysLeft 用 ceil：还剩 6 天 3 小时 → 7，文案上不会出现「还剩 0 天」
 * 却还没删的矛盾。到期后返回 0。
 */
export function deletionInfo(row) {
  const scheduled = parseSqlTime(row?.deletion_scheduled_at);
  if (!scheduled) return null;
  const remaining = scheduled.getTime() - Date.now();
  return {
    requestedAt: row.deletion_requested_at ?? null,
    scheduledAt: row.deletion_scheduled_at ?? null,
    daysLeft: remaining <= 0 ? 0 : Math.ceil(remaining / DAY_MS),
    due: remaining <= 0,
  };
}

/**
 * 申请注销。冷静期为 0 时直接删除（返回 { immediate: true }）。
 *
 * 注意：这里**不撤销会话**。用户还要能登录回来撤销申请；
 * 到期清理时才 revokeAllSessions()。
 */
export async function requestDeletion(userId) {
  const days = Math.max(0, Number(config.account.deleteDelayDays) || 0);
  if (days === 0) {
    await purgeUser(userId, { reason: '冷静期为 0，申请即删除' });
    return { immediate: true, deletion: null };
  }

  const requestedAt = new Date();
  const scheduledAt = new Date(requestedAt.getTime() + days * DAY_MS);
  await execute(
    `UPDATE users
        SET deletion_requested_at = ?, deletion_scheduled_at = ?
      WHERE id = ?`,
    [sqlTime(requestedAt), sqlTime(scheduledAt), userId],
  );

  return {
    immediate: false,
    deletion: {
      requestedAt: sqlTime(requestedAt),
      scheduledAt: sqlTime(scheduledAt),
      daysLeft: days,
      due: false,
    },
  };
}

/** 撤销注销申请。没有申请时也返回成功（幂等，避免「点两次报错」）。 */
export async function cancelDeletion(userId) {
  await execute(
    `UPDATE users
        SET deletion_requested_at = NULL, deletion_scheduled_at = NULL
      WHERE id = ?`,
    [userId],
  );
}

/**
 * 物理删除一个账号。
 *
 * 顺序有讲究：先撤会话 → 再删磁盘 → 最后删数据库行。
 * 反过来的话，删行成功后磁盘删失败就再也没有 id 可用了（孤儿目录），
 * 而先删磁盘、后删行时即使中途失败，账号仍在、可以重试。
 */
export async function purgeUser(userId, { reason = '账号注销到期' } = {}) {
  const id = Number(userId);
  if (!Number.isSafeInteger(id) || id <= 0) return false;

  await revokeAllSessions(id);

  // 目录可能本来就不存在（从来没写过数据），忽略 ENOENT
  try {
    await rm(userDir(id), { recursive: true, force: true });
  } catch (e) {
    console.warn(`[account] 删除用户数据目录失败（id=${id}）：${e.message}`);
  }

  const result = await execute('DELETE FROM users WHERE id = ?', [id]);
  const removed = result?.affectedRows ?? 0;
  if (removed > 0) {
    console.log(`\x1b[33m[account]\x1b[0m 已删除账号 ${id}（${reason}）`);
  }
  return removed > 0;
}

/**
 * 清理所有到期的注销申请。返回删除的账号数。
 *
 * 一次最多处理 limit 个：到期账号理论上很少，加个上限是为了防止
 * 「某天配置写错、几万个账号同时到期」时把进程卡在这里。
 */
export async function purgeDueDeletions({ limit = 50 } = {}) {
  const rows = await query(
    `SELECT id FROM users
      WHERE deletion_scheduled_at IS NOT NULL
        AND deletion_scheduled_at <= UTC_TIMESTAMP(3)
      ORDER BY deletion_scheduled_at ASC
      LIMIT ?`,
    [limit],
  );
  let removed = 0;
  for (const row of rows) {
    try {
      if (await purgeUser(Number(row.id))) removed++;
    } catch (e) {
      console.error(`[account] 删除账号 ${row.id} 失败：${e.message}`);
    }
  }
  return removed;
}

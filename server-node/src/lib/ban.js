// server/src/lib/ban.js
//
// 封禁：时长 + 原因，`-1` 表示永久。
//
// 数据放在 users 上，**不另开一张封禁记录表**：
//   * 现在只有「当前是否被封、封到什么时候、为什么」三个问题，一张表就能答；
//   * 多个面板同时操作同一用户时，单行更新天然是「最后一次生效」的语义，
//     而追加记录还要额外定义「以哪条为准」。
// 如果将来要做「封禁历史 / 申诉」，那时再开历史表，当前状态仍然留在这里。
//
// 列的含义：
//   status = 'disabled'  被封（沿用原有字段，鉴权链路早就认它）
//   banned_until         解封时点；**NULL = 永久**
//   ban_reason           原因，可空
// 三个要一起写、一起清，任何一处漏掉都会出现「解封了但还显示封禁原因」。
//
// 自动解封不靠定时任务的准确性：
//   * resolveSession() 与登录接口都会先判断到期时间 —— 到点立刻放行，
//     哪怕清理任务晚了半小时；
//   * 定时任务只是把 status 真正改回去，让面板列表不再显示「已封禁」。

import { execute, query, queryOne } from '../db.js';
import { ApiError } from './http.js';
import { parseSqlTime, toSqlTime } from './sql_time.js';

/** 时长上限（天）。10 年 ≈ 永久，再大就没意义了，还容易填错位数。 */
export const MAX_BAN_DAYS = 3650;
/** 同上，换算成小时：面板按「天 + 小时」填，边界统一按小时比 */
export const MAX_BAN_HOURS = MAX_BAN_DAYS * 24;

/**
 * 严格整数：`'7abc'`、`'1.5'`、`''`、`NaN` 全部退化成 NaN。
 *
 * 不用 parseInt：它会把 `'1.5'` 悄悄读成 1、把 `'7 天'` 读成 7，
 * 「填错了却被接受」比直接报错更难发现。
 */
function toInt(raw) {
  if (typeof raw === 'number') return Number.isInteger(raw) ? raw : Number.NaN;
  const text = String(raw ?? '').trim();
  return /^-?\d+$/.test(text) ? Number(text) : Number.NaN;
}

function assertParsed(value, unit) {
  if (!Number.isFinite(value)) {
    throw ApiError.badRequest('bad_duration', `封禁时长要填整数${unit}，-1 表示永久`);
  }
}

/**
 * 按**小时**解析封禁时长 —— 面板「x 天 x 小时」合成的就是这个数。
 *
 * @param {unknown} raw 小时数字符串 / 数字；`-1` = 永久
 * @returns {{ until: Date|null, hours: number, days: number }}
 */
export function parseBanHours(raw) {
  const hours = toInt(raw);
  assertParsed(hours, '小时');
  if (hours === -1) return { until: null, hours: -1, days: -1 };
  if (hours < 1 || hours > MAX_BAN_HOURS) {
    throw ApiError.badRequest(
      'bad_duration',
      `封禁时长要在 1 小时 ~ ${MAX_BAN_DAYS} 天之间，或者选「永久」`,
    );
  }
  return {
    until: new Date(Date.now() + hours * 3600_000),
    hours,
    // 兼容旧调用方：它们只认「天」，这里向上取整
    days: Math.ceil(hours / 24),
  };
}

/**
 * 按**天**解析 —— 老的 `durationDays` 字段走这里，保持兼容。
 *
 * @param {unknown} raw 天数字符串 / 数字；`-1` = 永久，`0` = 拒绝
 * @returns {{ until: Date|null, hours: number, days: number }}
 */
export function parseBanDuration(raw) {
  const days = toInt(raw);
  assertParsed(days, '天');
  if (days === -1) return { until: null, hours: -1, days: -1 };
  if (days < 1 || days > MAX_BAN_DAYS) {
    throw ApiError.badRequest(
      'bad_duration',
      `封禁时长要在 1 天 ~ ${MAX_BAN_DAYS} 天之间，或者填 -1 表示永久`,
    );
  }
  return { until: new Date(Date.now() + days * 86400_000), hours: days * 24, days };
}

/** 封禁状态：面板与客户端都用这一份 */
export function banInfo(row) {
  if (!row) return null;
  const until = parseSqlTime(row.banned_until);
  const disabled = row.status === 'disabled';
  if (!disabled && !until) return null;
  return {
    // 永久封禁时 until = null
    permanent: disabled && !until,
    // 到期时间（ISO，带 Z）；永久为 null
    until: until ? until.toISOString() : null,
    reason: String(row.ban_reason ?? ''),
    // 还剩几小时（向上取整），永久为 -1。面板按「x 天 x 小时」显示用这个 ——
    // 封 1 小时时 daysLeft 会是 1，拿它当「剩 1 天」显示就错了。
    hoursLeft: until
      ? Math.max(0, Math.ceil((until.getTime() - Date.now()) / 3600_000))
      : -1,
    // 还剩几天（向上取整），永久为 -1。老字段，保留给只认「天」的调用方。
    daysLeft: until
      ? Math.max(0, Math.ceil((until.getTime() - Date.now()) / 86400_000))
      : -1,
  };
}

/**
 * 这个账号现在是否可用。
 *
 * 关键点：**status 是 disabled 但已过解封时间**时返回可用 ——
 * 否则「封 1 天」的账号会在清理任务跑到之前一直登不上。
 */
export function banBlocks(row, now = Date.now()) {
  if (!row || row.status !== 'disabled') return false;
  const until = parseSqlTime(row.banned_until);
  if (!until) return true; // 永久
  return until.getTime() > now;
}

/** 描述「封到什么时候」，直接拼进错误提示 */
export function banMessage(row) {
  const info = banInfo(row);
  const reason = info?.reason ? `（原因：${info.reason}）` : '';
  if (!info || info.permanent) return `这个账号已被永久封禁${reason}`;
  const until = parseSqlTime(row.banned_until);
  const text = until
    ? until.toISOString().slice(0, 16).replace('T', ' ')
    : '';
  return `这个账号已被封禁至 ${text}（UTC）${reason}`;
}

/**
 * 登录 / 鉴权链路里统一调用：被封就抛 403，已到期就顺手解封。
 *
 * 「顺手解封」写在这里而不是只靠定时任务：用户被封 1 天后回来登录，
 * 恰好赶上任务还没跑，此时又不解封又拒绝登录，是最难解释的状态。
 */
export async function assertNotBanned(row, { code = 'account_banned' } = {}) {
  if (!row || row.status !== 'disabled') return;
  if (banBlocks(row)) {
    throw ApiError.forbidden(code, banMessage(row));
  }
  // 到期了：清掉封禁字段，让后续判断一致（也避免面板继续显示已封禁）
  await liftBan(row.id);
}

/** 解封：三个字段一起清 */
export async function liftBan(userId) {
  await execute(
    `UPDATE users
        SET status = 'active', banned_until = NULL, ban_reason = ''
      WHERE id = ?`,
    [userId],
  );
}

/**
 * 批量解封到期的账号。
 *
 * 只处理 `banned_until <= now` 的行 —— 永久封禁的 banned_until 是 NULL，
 * 必须显式排除，否则会被这条「到期」判断顺手放过（NULL 比较恒为 NULL）。
 */
export async function liftExpiredBans({ limit = 200 } = {}) {
  const rows = await query(
    `SELECT id FROM users
      WHERE status = 'disabled'
        AND banned_until IS NOT NULL
        AND banned_until <= UTC_TIMESTAMP(3)
      LIMIT ?`,
    [limit],
  );
  for (const row of rows) await liftBan(row.id);
  return rows.length;
}

/** 详情页用：读完整一行（含封禁与头像字段） */
export async function findUserRow(userId) {
  return queryOne('SELECT * FROM users WHERE id = ?', [userId]);
}

// server/src/prune.js
//
// 运维脚本：清理过期很久的登录会话与邮箱验证码。
//
// 用法：
//   npm run prune
//
// 建议挂到 crontab，每天跑一次：
//   0 4 * * * cd /path/to/server && npm run prune >> prune.log 2>&1
//
// 保留策略：只删「过期超过 30 天」的行。
// 不删刚过期的，是因为它们仍然是审计线索（谁在什么时候登过），
// 30 天足够回答「上周那个登录是不是我」这类问题。

import { pool } from './db.js';
import { pruneSessions } from './lib/auth.js';
import { purgeExpiredCodes } from './lib/email_codes.js';
import { readEnvFile } from './config.js';

readEnvFile();

const removed = await pruneSessions();
console.log(
  removed > 0
    ? `已清理 ${removed} 条过期会话`
    : '没有需要清理的会话',
);

// 验证码只留一天：它只是「一次注册的临时凭证」，留久了毫无价值，
// 反倒会成为一份「谁在什么时候想注册」的名单。
const codes = await purgeExpiredCodes();
console.log(
  codes > 0 ? `已清理 ${codes} 条过期验证码` : '没有需要清理的验证码',
);

await pool.end();

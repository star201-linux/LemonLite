// server/src/routes/admin.js
//
// 管理面板的路由装配。
//
// 一个不需要前端构建、不需要外网的小后台。拆成几个模块放在 src/admin/：
//   auth.js       首次建号 / 登录 / 会话 / 管理员账号管理
//   apps.js       应用增删改、上下架、传包（多分类）
//   taxonomy.js   分类与标签的增删改
//   users.js      市场用户的封禁 / 改密 / 踢下线
//   mail.js       邮件通道与验证码策略
//   ui.js         整页 HTML（服务端模板字符串，无构建步骤）
//
// 三条安全底线：
//   1. 账号在数据库里，第一个管理员由**第一次访问的人**创建；
//      之后只能由已有管理员加人。没有「全服共用一个口令」这回事。
//   2. 登录态是 HMAC 签名 cookie，签名密钥混入 password_hash ——
//      改密码即踢掉该账号所有会话。
//   3. 登录失败限流，失败信息统一（不区分用户名不存在 / 密码错）。

import { Router } from 'express';
import { queryOne } from '../db.js';
import { sendOk, wrap } from '../lib/http.js';
import { mailStatus } from '../lib/mailer.js';
import { config } from '../config.js';
import {
  adminAccountsRouter,
  adminAuthRouter,
  panelVersion,
  requireAdmin,
} from '../admin/auth.js';
import { appsRouter } from '../admin/apps.js';
import { taxonomyRouter } from '../admin/taxonomy.js';
import { usersRouter } from '../admin/users.js';
import { mailRouter } from '../admin/mail.js';
import { renderAdminPage } from '../admin/ui.js';

export const adminRouter = Router();

/** 页面本身永远可访问：它先去问 /api/session，再决定显示「建号 / 登录 / 面板」 */
adminRouter.get('/', (_req, res) => {
  res.type('html').send(renderAdminPage({ version: panelVersion() }));
});

// 公开接口：会话探测、首次建号、登录、登出
adminRouter.use(adminAuthRouter);

// 以下全部要求已登录（未登录的接口一律 401）
adminRouter.use(requireAdmin);

function uptimeLabel() {
  const seconds = Math.floor(process.uptime());
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d} 天 ${h} 小时`;
  if (h > 0) return `${h} 小时 ${m} 分`;
  return `${m} 分`;
}

// ================================================================ 概况

adminRouter.get(
  '/api/status',
  wrap(async (_req, res) => {
    const [users, apps, categories, tags, sessions, codes, admins] = await Promise.all([
      queryOne('SELECT COUNT(*) AS n FROM users'),
      queryOne('SELECT COUNT(*) AS n FROM apps WHERE deleted_at IS NULL'),
      queryOne('SELECT COUNT(*) AS n FROM categories'),
      queryOne('SELECT COUNT(*) AS n FROM tags'),
      queryOne(
        `SELECT COUNT(*) AS n FROM login_sessions
          WHERE revoked = 0 AND expires_at > UTC_TIMESTAMP(3)`,
      ),
      queryOne(
        `SELECT COUNT(*) AS n FROM email_codes
          WHERE created_at >= UTC_TIMESTAMP(3) - INTERVAL 1 DAY`,
      ),
      queryOne('SELECT COUNT(*) AS n FROM admin_users'),
    ]);
    const mail = mailStatus();
    sendOk(res, {
      counts: {
        users: Number(users?.n ?? 0),
        apps: Number(apps?.n ?? 0),
        categories: Number(categories?.n ?? 0),
        tags: Number(tags?.n ?? 0),
        sessions: Number(sessions?.n ?? 0),
        codes24h: Number(codes?.n ?? 0),
        admins: Number(admins?.n ?? 0),
      },
      mail: { driver: mail.driver, ready: mail.ready, reason: mail.reason },
      auth: {
        registerCode: config.auth.registerCode,
        loginCode: config.auth.loginCode,
        tokenTtl: config.auth.sessionTtl,
      },
      db: { ok: true },
      uptime: uptimeLabel(),
    });
  }),
);

adminRouter.use(adminAccountsRouter);
adminRouter.use(appsRouter);
adminRouter.use(taxonomyRouter);
adminRouter.use(usersRouter);
adminRouter.use(mailRouter);

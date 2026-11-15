// server/src/server.js
//
// HTTP 入口：装配中间件、挂路由、启动监听。

import express from 'express';
import cors from 'cors';
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { config, describeConfig, readEnvFile } from './config.js';
import { ping, closePool } from './db.js';
import { errorHandler, notFoundHandler, sendOk } from './lib/http.js';
import {
  describeInsecureConfig,
  rateLimit,
  requestId,
  securityHeaders,
} from './lib/security.js';
import { marketRouter } from './routes/market.js';
import { authRouter } from './routes/auth.js';
import { uploadRouter, userDataRouter } from './routes/upload.js';
import { packageRouter } from './routes/packages.js';
import { adminRouter } from './routes/admin.js';
import { adminCount, ensureAdminSecret } from './admin/auth.js';
import { ensureSchema } from './lib/schema_guard.js';
import { purgeDueDeletions } from './lib/account_deletion.js';
import { iconsRoot } from './lib/icon_store.js';
import { describeMail, mailStatus } from './lib/mailer.js';

readEnvFile();

const app = express();

// ---------------------------------------------------------------- 中间件

// 不报 X-Powered-By：这条头对客户端没用，只是告诉扫描器「这是 Express」。
app.disable('x-powered-by');

if (config.http.trustProxy) app.set('trust proxy', true);

app.use(requestId);
app.use(securityHeaders);

// CORS：客户端是 Android App（原生 HTTP 请求，不受同源限制），
// 网页版调试 / 管理后台才需要。开发期放开，生产必须用 CORS_ORIGIN 限定。
//
// 生产环境没配 CORS_ORIGIN 时**不发** CORS 头（默认同源）：
// 放行全部等于把 API 借给任意网站，而客户端根本不需要它。
const corsOrigin = process.env.CORS_ORIGIN;
const isProduction = process.env.NODE_ENV === 'production';
app.use(
  cors({
    origin:
      corsOrigin && corsOrigin !== '*'
        ? corsOrigin.split(',').map((s) => s.trim()).filter(Boolean)
        : isProduction
          ? false
          : true,
    credentials: false,
    maxAge: 600,
  }),
);

// 请求体上限：头像走 multipart，不走这里；JSON 只放小对象（登录、改资料）。
// 1MB 足够，再大就是有人在拿它当文件传输。
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false, limit: '1mb' }));

// 限流：全局按 IP 300 次/分钟，认证类接口 20 次/分钟（防撞库与验证码轰炸）。
// 放在路由之前，被限的请求不会碰到数据库。
app.use(
  '/api',
  rateLimit({
    windowMs: 60_000,
    max: 300,
    message: '请求太频繁，请稍后再试',
  }),
);
app.use(
  ['/api/auth/login', '/api/auth/register', '/api/auth/email-code', '/api/auth/login-code', '/api/auth/password'],
  rateLimit({
    windowMs: 60_000,
    max: 20,
    message: '尝试太频繁，请一分钟后再试',
  }),
);

// 极简访问日志：方法、路径、状态、耗时。
// 不记 body —— 里面可能有密码。
app.use((req, res, next) => {
  const started = Date.now();
  res.on('finish', () => {
    const ms = Date.now() - started;
    const mark = res.statusCode >= 500 ? '\x1b[31m' : res.statusCode >= 400 ? '\x1b[33m' : '\x1b[32m';
    console.log(
      `${mark}${res.statusCode}\x1b[0m ${req.method} ${req.originalUrl} ${ms}ms` +
        (req.id ? ` [${req.id}]` : ''),
    );
  });
  next();
});

// ---------------------------------------------------------------- 用户数据目录

// 只确保目录存在，**不**静态挂载。
//
// 为什么不挂 express.static：userdata/<id>/ 里有 data.json（用户私有数据），
// 静态挂载等于把它们全部公开可下载 —— 而 id 是自增的，谁都能挨个试。
// 头像走 /api/upload/avatar/:id 这个专用接口（它只回图片、带 ETag），
// data.json 走需要登录的 /api/user/data。
const userdataDir = join(config.root, config.userdata.dir);
if (!existsSync(userdataDir)) mkdirSync(userdataDir, { recursive: true });

// ---------------------------------------------------------------- 小程序图标
//
// 图标是公开内容（列表里人人都要看），所以静态托管。
// 目录由管理员上传接口写入；文件名是 <appId>.<ext>，没有目录穿越的空间。
// 这里**不**做「目录不存在就跳过」：先建出来，之后第一次上传不用再建。
const iconsDir = iconsRoot();
if (!existsSync(iconsDir)) mkdirSync(iconsDir, { recursive: true });
app.use(
  '/icons',
  express.static(iconsDir, {
    // 换图标时文件名不变（<appId>.png），所以不能设 immutable；
    // 一天的缓存 + 客户端本地缓存已经够了。
    maxAge: '1d',
    index: false,
    dotfiles: 'deny',
    // 不落到后续路由：/icons 下没有的东西就是 404，不要被 SPA 兜底接走
    fallthrough: false,
  }),
);

// ---------------------------------------------------------------- 路由

/** 健康检查：部署后第一件事就是 curl 它 */
app.get('/api/health', async (_req, res, next) => {
  try {
    await ping();
    sendOk(res, {
      status: 'ok',
      db: 'up',
      version: process.env.npm_package_version || '1.0.0',
      uptime: Math.round(process.uptime()),
      time: new Date().toISOString(),
    });
  } catch (e) {
    next(e);
  }
});

// 包路由必须在 marketRouter **之前** 挂载。
//
// 原因：marketRouter 里有 `/app/:id` 这样的通配段，而包路由的
// `/:appId/package` 与它是两种不同的两段路径。Express 按挂载顺序匹配，
// 如果把 marketRouter 放前面，`/api/market/xxx/package` 不会命中
// `/app/:id`（段数不同，实际不会冲突）—— 但 `/updates` 会先被
// marketRouter 的兜底逻辑看到。把更具体的包路由放前面是稳妥做法，
// 代价只是多一次路由表遍历。
app.use('/api/market', packageRouter);
app.use('/api/market', marketRouter);
app.use('/api/auth', authRouter);
app.use('/api/upload', uploadRouter);
// 用户私有 JSON：前缀是 /api/user，**不是** /api/upload（见 upload.js 里的说明）
app.use('/api/user', userDataRouter);
// 管理面板：/admin。账号在数据库里（admin_users），第一次打开时创建第一个管理员
app.use('/admin', adminRouter);

// 根路径给一句人话（否则访问 / 会拿到 404 JSON，看起来像挂了）
app.get('/', (_req, res) => {
  res.type('text/plain; charset=utf-8').send(
    [
      'LemonLite 市场服务端在跑。',
      '',
      '接口：',
      '  GET  /api/health',
      '  GET  /api/market/feed?limit=20&cursor=',
      '  GET  /api/market/search?q=&tag=&limit=20&offset=0',
      '  GET  /api/market/app/:id',
      '  GET  /api/market/:appId/version    （打开小程序前检查版本）',
      '  POST /api/market/updates           （批量检查已装小程序）',
      '  GET  /api/market/:appId/package    （下载小程序包）',
      '  GET  /icons/:appId.(png|jpg|webp|gif) （小程序图标）',
      '  GET  /api/market/tags',
      '  GET  /api/auth/config        （客户端据此决定要不要验证码输入框）',
      '  POST /api/auth/email-code    （发注册验证码）',
      '  POST /api/auth/login-code    （发登录验证码，需先给对密码）',
      '  POST /api/auth/register      （需要 code）',
      '  POST /api/auth/login',
      '  GET  /api/auth/me',
      '  PATCH /api/auth/me',
      '  POST /api/auth/password',
      '  GET  /api/auth/check?username=',
      '  GET  /api/auth/sessions',
      '  DELETE /api/auth/sessions/:id',
      '  POST /api/auth/logout',
      '  POST /api/auth/logout-all',
      '',
      '  GET  /admin                  （管理面板：概览 / 应用 / 分类标签 / 用户 / 管理员 / 邮件）',
      '  POST /api/upload/avatar       （multipart，字段名 file）',
      '  GET  /api/upload/avatar/:id',
      '  DELETE /api/upload/avatar',
      '  GET  /api/user/data',
      '  PUT  /api/user/data',
      '  PATCH /api/user/data',
      '  DELETE /api/user/data',
      '',
    ].join('\n'),
  );
});

app.use(notFoundHandler);
app.use(errorHandler);

// ---------------------------------------------------------------- 启动

/** 扫一遍到期的注销申请。失败只记日志：清理不该挡住服务启动。 */
async function runDeletionPurge(reason) {
  try {
    const removed = await purgeDueDeletions();
    if (removed > 0) {
      console.log(`\x1b[32m✓\x1b[0m ${reason}清理：删除了 ${removed} 个注销到期账号`);
    }
  } catch (e) {
    console.error(`[account] 注销清理失败（${reason}）：${e.code || e.message}`);
  }
}

/**
 * 递归排期而不是 setInterval：间隔来自 config，
 * 面板改完 `ACCOUNT_PURGE_INTERVAL_MINUTES` 之后，下一次排期就会用新值。
 * 间隔为 0 表示关掉定时清理（只靠启动时与 npm run prune）。
 */
function scheduleDeletionPurge() {
  const minutes = Math.max(0, Number(config.account.purgeIntervalMinutes) || 0);
  if (minutes === 0) return;
  const timer = setTimeout(async () => {
    await runDeletionPurge('定时');
    scheduleDeletionPurge();
  }, minutes * 60 * 1000);
  // 不因这个定时器而阻止进程退出
  timer.unref();
}

async function start() {
  try {
    await ping();
  } catch (e) {
    console.error('\x1b[31m✗ 连不上数据库\x1b[0m');
    console.error(`  ${e.code || e.message}`);
    console.error('');
    console.error('  先跑一次初始化：npm run init -- --seed');
    console.error('  或检查 .env 里的 DB_* 配置');
    process.exit(1);
  }

  // 表结构自检：升级后即使忘了跑 npm run init，也能把新表补上
  const schema = await ensureSchema();
  if (schema.filled > 0) {
    console.log(`\x1b[32m✓\x1b[0m 已把 ${schema.filled} 个应用的主分类补进多分类关联表`);
  }
  // 面板 cookie 的签名密钥：没有就生成一个写回 .env
  await ensureAdminSecret();

  // 注销到期的账号：启动时先扫一次（进程停了两天也不会漏掉），
  // 之后按配置的间隔递归排期。间隔读的是 config，管理面板改完下一次就生效。
  await runDeletionPurge('启动');
  scheduleDeletionPurge();

  // 反代 / 慢客户端保护：头 10 秒内必须收完，整个请求 30 秒内必须结束。
  // 不设的话，一个故意不读完 body 的连接会一直占着 socket。
  const server = app.listen(config.http.port, config.http.host, async () => {
    console.log('');
    console.log('\x1b[32mLemonLite 服务端已启动\x1b[0m');
    console.log('');
    console.log(describeConfig());
    console.log('');
    // 邮件通道单独一行：注册流程能不能跑通全看它
    const mail = mailStatus();
    console.log(
      `${mail.ready ? '\x1b[32m✓\x1b[0m' : '\x1b[33m!\x1b[0m'} 邮件 ${describeMail()}`,
    );
    if (!mail.ready) {
      console.log('  客户端注册会失败：先在 .env 里配好 MAIL_DRIVER 与对应凭据');
    }
    // 管理面板能改邮件通道，所以把它当前状态也说清楚
    const admins = await adminCount();
    const panel = `http://<本机IP>:${config.http.port}/admin`;
    if (admins === 0) {
      console.log(`\x1b[33m!\x1b[0m 管理面板 ${panel} 还没有管理员账号，首次打开时创建一个`);
    } else {
      console.log(`\x1b[32m✓\x1b[0m 管理面板 ${panel}（${admins} 个管理账号）`);
    }
    console.log('');
    console.log(`  本机   http://127.0.0.1:${config.http.port}`);
    console.log(`  局域网 http://<本机IP>:${config.http.port}`);
    console.log('');
    console.log('  客户端在「设置 → 开发者选项 → 服务器地址」里填上面的地址。');
    console.log('');

    for (const warning of describeInsecureConfig(config)) {
      console.log(`\x1b[33m!\x1b[0m ${warning}`);
    }
    if (process.env.NODE_ENV !== 'production') {
      console.log('\x1b[90m（开发模式：CORS 放开、详细日志；生产请设 NODE_ENV=production）\x1b[0m');
    }
    console.log('');
  });

  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 65_000;

  // 优雅退出：让正在处理的请求跑完（容器部署时 SIGTERM 很重要）
  let closing = false;
  const shutdown = (signal) => {
    if (closing) return;
    closing = true;
    console.log(`\n收到 ${signal}，正在关闭…`);
    server.close(async () => {
      await closePool();
      process.exit(0);
    });
    // 兜底：10 秒还没关完就强退，避免卡住部署流程
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

start();

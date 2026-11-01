// server/src/server.js
//
// HTTP 入口：装配中间件、挂路由、启动监听。

import express from 'express';
import cors from 'cors';
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { config, describeConfig, readEnvFile } from './config.js';
import { ping } from './db.js';
import { errorHandler, notFoundHandler, sendOk } from './lib/http.js';
import { marketRouter } from './routes/market.js';
import { authRouter } from './routes/auth.js';
import { uploadRouter, userDataRouter } from './routes/upload.js';
import { packageRouter } from './routes/packages.js';
import { adminRouter } from './routes/admin.js';
import { adminCount, ensureAdminSecret } from './admin/auth.js';
import { ensureSchema } from './lib/schema_guard.js';
import { describeMail, mailStatus } from './lib/mailer.js';

readEnvFile();

const app = express();

// ---------------------------------------------------------------- 中间件

if (config.http.trustProxy) app.set('trust proxy', true);

// CORS：客户端是 Android App（原生 HTTP 请求，不受同源限制），
// 但网页版调试 / 管理后台会需要。开发期放开，生产建议用 CORS_ORIGIN 收紧。
const corsOrigin = process.env.CORS_ORIGIN;
app.use(
  cors({
    origin: corsOrigin && corsOrigin !== '*' ? corsOrigin.split(',') : true,
    credentials: false,
  }),
);

// 请求体上限：头像走 multipart，不走这里；JSON 只放小对象（登录、改资料）。
// 5MB 是给将来可能的批量导入留的余量，但绝不该更大。
app.use(express.json({ limit: '5mb' }));
app.use(express.urlencoded({ extended: false, limit: '5mb' }));

// 极简访问日志：方法、路径、状态、耗时。
// 不记 body —— 里面可能有密码。
app.use((req, res, next) => {
  const started = Date.now();
  res.on('finish', () => {
    const ms = Date.now() - started;
    const mark = res.statusCode >= 500 ? '\x1b[31m' : res.statusCode >= 400 ? '\x1b[33m' : '\x1b[32m';
    console.log(
      `${mark}${res.statusCode}\x1b[0m ${req.method} ${req.originalUrl} ${ms}ms`,
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

// ---------------------------------------------------------------- 路由

/** 健康检查：部署后第一件事就是 curl 它 */
app.get('/api/health', async (_req, res, next) => {
  try {
    await ping();
    sendOk(res, { status: 'ok', db: 'up', time: new Date().toISOString() });
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
  });

  // 优雅退出：让正在处理的请求跑完（容器部署时 SIGTERM 很重要）
  const shutdown = (signal) => {
    console.log(`\n收到 ${signal}，正在关闭…`);
    server.close(() => process.exit(0));
    // 兜底：10 秒还没关完就强退，避免卡住部署流程
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

start();

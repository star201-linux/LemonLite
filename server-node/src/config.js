// server/src/config.js
//
// 配置的唯一入口：优先读环境变量，其次读 .env，最后用内置默认值。
//
// 为什么不直接用 dotenv 的 `config()` 就完事：
//   init.js 需要「.env 不存在也能跑」（第一次部署），并且要能告诉用户
//   「你现在用的是默认值」。所以这里自己包一层，返回「有没有真的读到文件」。

import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const ENV_PATH = join(ROOT, '.env');

/**
 * 把 .env 读进 process.env（不覆盖已存在的真实环境变量）。
 * @returns {boolean} 文件是否存在
 */
export function readEnvFile() {
  if (!existsSync(ENV_PATH)) return false;
  const text = readFileSync(ENV_PATH, 'utf8');
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    // 去掉可选的引号
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
  return true;
}

function env(key, fallback) {
  const v = process.env[key];
  return v === undefined || v === '' ? fallback : v;
}

function envInt(key, fallback) {
  const n = Number.parseInt(env(key, ''), 10);
  return Number.isFinite(n) ? n : fallback;
}

// 注意：这里**必须**在构造 config 之前把 .env 读进 process.env。
//
// 之前是各入口脚本（server.js / init.js）自己调 readEnvFile()，但 ESM 的
// import 是先于模块体执行的：`config` 对象在 import 阶段就已经按
// process.env 的**默认值**算好了，入口脚本再读 .env 已经来不及。
// 症状很隐蔽 —— 服务照常启动，但连的是 localhost/root，而不是 .env 里写的库。
readEnvFile();

export const config = {
  db: {
    host: env('DB_HOST', '127.0.0.1'),
    port: envInt('DB_PORT', 3306),
    user: env('DB_USER', 'root'),
    password: env('DB_PASSWORD', ''),
    database: env('DB_NAME', 'lemonlite'),
    connectionLimit: envInt('DB_POOL_SIZE', 10),
  },

  http: {
    port: envInt('PORT', 3000),
    // 监听地址：0.0.0.0 才能让手机从局域网访问到（开发用）。
    // 生产环境放在 Nginx 后面时应改成 127.0.0.1。
    host: env('HOST', '0.0.0.0'),
    // 反向代理后面要信任 X-Forwarded-For，否则日志里全是代理 IP
    trustProxy: env('TRUST_PROXY', 'false') === 'true',
  },

  auth: {
    // token 有效期。
    //   never / 0 → **永不过期**：只要客户端不卸载（本地 token 还在），就一直有效；
    //               撤销仍然随时生效（退出登录 / 踢设备 / 改密码）。
    //   7d / 12h  → 到点失效；每次请求会顺手续期（滑窗），常来用就不会掉线。
    // 默认 never：这个 App 的定位是「自己或小圈子用」，为了不让人反复登录
    // 牺牲一点「token 被偷后的窗口期」是划算的；面向公网的多租户场景请改回 7d。
    sessionTtl: env('TOKEN_TTL', 'never'),

    // 注册是否要邮箱验证码。关掉只适合内网/自测 —— 邮箱不是秘密，
    // 没有验证就等于谁都能用别人的邮箱开号。
    registerCode: env('AUTH_REGISTER_CODE', 'on').toLowerCase() === 'on',

    // 登录是否再要一次邮箱验证码（二次验证）。
    // 打开后：输对密码还不够，还要收到一封验证码邮件才能登录。
    // 客户端不会写死这个行为 —— 启动时读 /api/auth/config，跟着服务端走。
    loginCode: env('AUTH_LOGIN_CODE', 'off').toLowerCase() === 'on',
    // bcrypt 代价因子。10 在手机/中端服务器上约 60~100ms，够用且不拖慢登录。
    bcryptRounds: envInt('BCRYPT_ROUNDS', 10),
    // 单个用户最多同时保留多少个有效会话（超出时踢掉最旧的）。
    // 0 表示不限制。设一个上限是为了防止「脚本无限登录」把表撑爆。
    maxSessionsPerUser: envInt('MAX_SESSIONS_PER_USER', 20),
  },

  // ---------------------------------------------------------------- 邮件
  //
  // 注册要发邮箱验证码，而「邮件从哪发出去」在不同部署环境差别很大：
  // 自己的 VPS 上装 Postfix、用企业邮箱的 SMTP、还是直接调第三方 API。
  // 所以通道做成可切换的（改 MAIL_DRIVER 即可，不用改代码）。
  mail: {
    // smtp | resend | sendgrid | aliyun | console
    // console 只把邮件打到日志里 —— 仅用于本地开发/演示。
    driver: env('MAIL_DRIVER', 'console').toLowerCase(),
    // 发件地址（必须是通道那边验证过的域名/邮箱，否则会被拒）
    from: env('MAIL_FROM', ''),
    fromName: env('MAIL_FROM_NAME', 'LemonLite'),

    // 验证码策略
    codeLength: Math.min(8, Math.max(4, envInt('MAIL_CODE_LENGTH', 6))),
    // 有效期（秒）。10 分钟是「够用户去看邮箱，又不至于留太久」的经验值。
    codeTtl: envInt('MAIL_CODE_TTL', 10 * 60),
    // 同一邮箱两次索要之间的最小间隔（秒）。防连点、防短信轰炸。
    codeCooldown: envInt('MAIL_CODE_COOLDOWN', 60),
    // 同一邮箱 / 同一 IP 每小时最多发多少封
    codeMaxPerEmailHour: envInt('MAIL_CODE_MAX_PER_EMAIL', 10),
    codeMaxPerIpHour: envInt('MAIL_CODE_MAX_PER_IP', 30),
    // 单个验证码允许输错几次（超过就作废，必须重新获取）
    codeMaxAttempts: envInt('MAIL_CODE_MAX_ATTEMPTS', 5),
    // 开发期把验证码塞进接口响应，省得去翻日志。生产必须 false。
    devEchoCode: env('MAIL_DEV_ECHO_CODE', 'false') === 'true',
    // 第三方 API 的超时（毫秒）
    httpTimeoutMs: envInt('MAIL_HTTP_TIMEOUT_MS', 10_000),

    // ---- 自建 / 兼容 SMTP 的邮箱
    smtp: {
      host: env('SMTP_HOST', ''),
      port: envInt('SMTP_PORT', 587),
      // 隐式 TLS（465 端口用 true；587/25 用 false + STARTTLS）
      secure: env('SMTP_SECURE', 'false') === 'true',
      // 明文连上后升级 TLS。除非是同机 Postfix 走 127.0.0.1，否则别关。
      starttls: env('SMTP_STARTTLS', 'true') === 'true',
      user: env('SMTP_USER', ''),
      password: env('SMTP_PASSWORD', ''),
      // 自签证书的内网邮件服务器可以设 false；公网服务保持 true。
      rejectUnauthorized: env('SMTP_REJECT_UNAUTHORIZED', 'true') === 'true',
      timeoutMs: envInt('SMTP_TIMEOUT_MS', 15_000),
    },

    // ---- 第三方：Resend
    resend: {
      apiKey: env('RESEND_API_KEY', ''),
      endpoint: env('RESEND_ENDPOINT', 'https://api.resend.com/emails'),
    },

    // ---- 第三方：SendGrid
    sendgrid: {
      apiKey: env('SENDGRID_API_KEY', ''),
      endpoint: env('SENDGRID_ENDPOINT', 'https://api.sendgrid.com/v3/mail/send'),
    },

    // ---- 第三方：阿里云邮件推送 DirectMail
    aliyun: {
      accessKeyId: env('ALIYUN_DM_ACCESS_KEY_ID', ''),
      accessKeySecret: env('ALIYUN_DM_ACCESS_KEY_SECRET', ''),
      // 发信地址（在阿里云控制台配置的那个，如 no-reply@mail.example.com）
      accountName: env('ALIYUN_DM_ACCOUNT_NAME', ''),
      region: env('ALIYUN_DM_REGION', 'cn-hangzhou'),
      endpoint: env('ALIYUN_DM_ENDPOINT', 'https://dm.aliyuncs.com'),
    },
  },

  // ---------------------------------------------------------------- 管理面板
  //
  // 一个纯服务端渲染的小后台：看运行概况、改邮件通道、发测试信。
  // 没有密码就**不启用** —— 未授权可访问的管理面板比没有面板更危险。
  admin: {
    enabled: env('ADMIN_PASSWORD', '') !== '',
    // 登录口令。空 = 面板关闭（/admin 会显示一行提示，告诉你怎么开）。
    password: env('ADMIN_PASSWORD', ''),
    // 登录态有效期（毫秒）。7 天足够，太久反而给了别人长时间窗口。
    sessionTtlMs: envInt('ADMIN_SESSION_HOURS', 24 * 7) * 3600 * 1000,
  },

  market: {
    // 分段加载的每页条数上限。客户端传更大的值会被夹到这个上限 ——
    // 不设上限的话一个 `?limit=999999` 就能把整个应用表拉出来。
    maxPageSize: envInt('MARKET_MAX_PAGE', 50),
    defaultPageSize: envInt('MARKET_PAGE_SIZE', 20),
  },

  packages: {
    // 小程序包根目录：packages/<appId>/<version>.zip
    dir: env('PACKAGES_DIR', 'packages'),
    // 包大小上限（字节）。与 routes/packages.js 里的常量保持一致。
    maxBytes: envInt('PACKAGE_MAX_BYTES', 20 * 1024 * 1024),
  },

  userdata: {
    // 用户数据根目录：userdata/<id>/data.json 与 userdata/<id>/avatar.png
    dir: env('USERDATA_DIR', 'userdata'),
    // 上传头像大小上限（字节）。2MB 对头像绰绰有余。
    maxAvatarBytes: envInt('AVATAR_MAX_BYTES', 2 * 1024 * 1024),
    // data.json 大小上限（字节）。这是「一大块不透明 JSON」，
    // 上限设大一点（16MB）但绝不能无上限 —— 否则一个用户就能把磁盘写满。
    maxDataBytes: envInt('USERDATA_MAX_BYTES', 16 * 1024 * 1024),
  },

  root: ROOT,
};

/** 让人一眼看出「现在用的是不是默认配置」 */
export function describeConfig() {
  const lines = [];
  lines.push(`HTTP   ${config.http.host}:${config.http.port}`);
  lines.push(`MySQL  ${config.db.user}@${config.db.host}:${config.db.port}/${config.db.database}`);
  lines.push(
    `会话   token ${config.auth.sessionTtl === 'never' ? '永不过期' : config.auth.sessionTtl + ' 有效'}` +
      '，落库可撤销',
  );
  lines.push(
    `验证码 注册${config.auth.registerCode ? '需要' : '不需要'}` +
      ' / ' +
      `登录${config.auth.loginCode ? '需要' : '不需要'}`,
  );
  lines.push(
    `用户数据 ${config.userdata.dir}/<id>/{data.json,avatar.png}` +
      `（头像上限 ${Math.round(config.userdata.maxAvatarBytes / 1024 / 1024)}MB）`,
  );
  lines.push(`小程序包 ${config.packages.dir}/<appId>/<version>.zip`);
  // 邮件通道是「部署后最容易配漏」的一项，启动时就把它摊开说清楚
  lines.push(
    `邮件   ${config.mail.driver}` +
      `（验证码 ${config.mail.codeLength} 位 / ${Math.round(config.mail.codeTtl / 60)} 分钟有效 / ` +
      `${config.mail.codeCooldown}s 冷却）`,
  );
  return lines.join('\n');
}

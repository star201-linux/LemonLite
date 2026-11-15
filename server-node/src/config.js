// server/src/config.js
//
// 配置的唯一入口：**读 config.yaml**，缺项用内置默认值，环境变量可临时覆盖。
//
// 为什么从 .env 换成 YAML：
//   * 配置是**分层的**（`mail.smtp.host` 属于「邮件 → SMTP → 主机」），
//     而 .env 是一层扁平键，只能靠 `MAIL_SMTP_HOST` 这种前缀硬编码层级；
//     层级一多，键名就开始互相撞（`MAIL_CODE_TTL` 到底是验证码有效期还是别的？）。
//   * YAML 能写注释、能表示布尔与数字，不需要「把 'true' 和 'on' 都当 true」。
//   * 一个文件就能看懂全部可配项，不用在 README 和 .env.example 之间来回翻。
//
// 优先级：**环境变量 > config.yaml > 内置默认值**。
//   保留环境变量覆盖是为了容器 / CI：`DB_PASSWORD=xxx npm start` 能临时改一项，
//   不必挂载整个配置文件。它不是让你把配置拆两处写。
//
// config.yaml 不存在时：自动从 config.example.yaml 复制一份。
//   「clone 下来就能跑」很重要 —— 第一次部署的人不该先读三页文档才知道
//   有个文件没建。

import { copyFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { readConfigFile, setIn } from './lib/configfile.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

export const CONFIG_PATH = join(ROOT, 'config.yaml');
export const EXAMPLE_CONFIG_PATH = join(ROOT, 'config.example.yaml');

// ================================================================ 内置默认值
//
// 这份对象有两个作用：config.yaml 缺项时的兜底，以及「哪些键是合法的」的定义。
// 它必须与 config.example.yaml 的键集合完全一致 —— 有测试盯着这件事
// （test/config_file.test.js），否则迟早出现「文档里有、代码不认」的配置项。

export const CONFIG_DEFAULTS = {
  http: { host: '0.0.0.0', port: 3000, trustProxy: false },

  db: {
    host: '127.0.0.1',
    port: 3306,
    user: 'root',
    password: '',
    database: 'lemonlite',
    connectionLimit: 10,
  },

  auth: {
    sessionTtl: 'never',
    registerCode: true,
    loginCode: false,
    bcryptRounds: 10,
    maxSessionsPerUser: 20,
  },

  mail: {
    driver: 'console',
    from: '',
    fromName: 'LemonLite',
    codeLength: 6,
    codeTtl: 600,
    codeCooldown: 60,
    codeMaxPerEmailHour: 10,
    codeMaxPerIpHour: 30,
    codeMaxAttempts: 5,
    devEchoCode: false,
    httpTimeoutMs: 10_000,
    smtp: {
      host: '',
      port: 587,
      secure: false,
      starttls: true,
      user: '',
      password: '',
      rejectUnauthorized: true,
      timeoutMs: 15_000,
    },
    resend: { apiKey: '', endpoint: 'https://api.resend.com/emails' },
    sendgrid: { apiKey: '', endpoint: 'https://api.sendgrid.com/v3/mail/send' },
    aliyun: {
      accessKeyId: '',
      accessKeySecret: '',
      accountName: '',
      region: 'cn-hangzhou',
      endpoint: 'https://dm.aliyuncs.com',
    },
  },

  admin: { secret: '', setupToken: '', sessionTtlHours: 168 },

  account: { deleteDelayDays: 7, purgeIntervalMinutes: 30 },

  market: { defaultPageSize: 20, maxPageSize: 50 },

  packages: { dir: 'packages', maxBytes: 20 * 1024 * 1024 },
  icons: { dir: 'icons', maxBytes: 2 * 1024 * 1024 },
  userdata: {
    dir: 'userdata',
    maxAvatarBytes: 2 * 1024 * 1024,
    maxDataBytes: 16 * 1024 * 1024,
  },
};

// ================================================================ 读取

/**
 * 确保 config.yaml 存在（不存在就从 config.example.yaml 复制）。
 * @returns {boolean} 是否刚刚新建
 */
function ensureConfigFile() {
  if (existsSync(CONFIG_PATH)) return false;
  if (!existsSync(EXAMPLE_CONFIG_PATH)) return false;
  try {
    copyFileSync(EXAMPLE_CONFIG_PATH, CONFIG_PATH);
    return true;
  } catch (e) {
    console.warn(`! 无法生成 config.yaml（${e.message}），本次运行使用内置默认值`);
    return false;
  }
}

const configCreated = ensureConfigFile();

const loaded = readConfigFile(CONFIG_PATH);
if (loaded.error) {
  // 配置写坏时**直接退出**，而不是带着半套默认值继续跑。
  // 带病运行的后果是「服务起来了但连错库 / 发不出邮件」，那比启动失败
  // 难排查得多 —— 启动失败至少指得清是哪一行。
  console.error(`\x1b[31m✗ config.yaml 解析失败：${loaded.error}\x1b[0m`);
  console.error(`  文件：${CONFIG_PATH}`);
  console.error('  改好之后重新启动。如果只是想重来：');
  console.error('    cp config.example.yaml config.yaml');
  process.exit(1);
}

const FILE = loaded.data;

// ================================================================ 类型收敛
//
// YAML 里 `port: "3000"`（带引号）会读成字符串，`secure: yes` 会读成 true。
// 配置是手写的，不能指望类型永远正确 —— 这里统一收敛成代码期望的类型，
// 顺带把「写成了离谱的值」夹回合法区间。

function str(value, fallback) {
  if (value === undefined || value === null) return fallback;
  const text = String(value).trim();
  return text === '' ? fallback : text;
}

function int(value, fallback, min = -Infinity, max = Infinity) {
  const n =
    typeof value === 'number' ? value : Number.parseInt(String(value ?? '').trim(), 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(n)));
}

function bool(value, fallback) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  const text = String(value ?? '').trim().toLowerCase();
  if (['true', 'yes', 'on', '1'].includes(text)) return true;
  if (['false', 'no', 'off', '0'].includes(text)) return false;
  return fallback;
}

/** `never` / `0` 都表示永不过期，其余按 `7d` / `12h` 原样交给下游解析 */
function ttl(value, fallback) {
  const text = str(value, fallback);
  return text === '0' ? 'never' : text;
}

function section(key) {
  const raw = FILE[key];
  return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
}

/** 取子对象；写成标量时当作「没写」，避免 `mail.smtp: 123` 把启动打崩 */
function sub(obj, key) {
  const raw = obj[key];
  return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
}

// ================================================================ 组装

const d = CONFIG_DEFAULTS;
const httpRaw = section('http');
const dbRaw = section('db');
const authRaw = section('auth');
const mailRaw = section('mail');
const smtpRaw = sub(mailRaw, 'smtp');
const resendRaw = sub(mailRaw, 'resend');
const sendgridRaw = sub(mailRaw, 'sendgrid');
const aliyunRaw = sub(mailRaw, 'aliyun');
const adminRaw = section('admin');
const accountRaw = section('account');
const marketRaw = section('market');
const packagesRaw = section('packages');
const iconsRaw = section('icons');
const userdataRaw = section('userdata');

export const config = {
  db: {
    host: str(dbRaw.host, d.db.host),
    port: int(dbRaw.port, d.db.port, 1, 65535),
    user: str(dbRaw.user, d.db.user),
    password: str(dbRaw.password, d.db.password),
    database: str(dbRaw.database, d.db.database),
    connectionLimit: int(dbRaw.connectionLimit, d.db.connectionLimit, 1, 100),
  },

  http: {
    port: int(httpRaw.port, d.http.port, 1, 65535),
    // 监听地址：0.0.0.0 才能让手机从局域网访问到（开发用）。
    // 生产环境放在 Nginx 后面时应改成 127.0.0.1。
    host: str(httpRaw.host, d.http.host),
    // 反向代理后面要信任 X-Forwarded-For，否则日志里全是代理 IP
    trustProxy: bool(httpRaw.trustProxy, d.http.trustProxy),
  },

  auth: {
    // token 有效期。
    //   never / 0 → **永不过期**：只要客户端不卸载（本地 token 还在），就一直有效；
    //               撤销仍然随时生效（退出登录 / 踢设备 / 改密码）。
    //   7d / 12h  → 到点失效；每次请求会顺手续期（滑窗），常来用就不会掉线。
    // 默认 never：这个 App 的定位是「自己或小圈子用」，为了不让人反复登录
    // 牺牲一点「token 被偷后的窗口期」是划算的；面向公网的多租户场景请改回 7d。
    sessionTtl: ttl(authRaw.sessionTtl, d.auth.sessionTtl),

    // 注册是否要邮箱验证码。关掉只适合内网/自测 —— 邮箱不是秘密，
    // 没有验证就等于谁都能用别人的邮箱开号。
    registerCode: bool(authRaw.registerCode, d.auth.registerCode),

    // 登录是否再要一次邮箱验证码（二次验证）。
    // 打开后：输对密码还不够，还要收到一封验证码邮件才能登录。
    // 客户端不会写死这个行为 —— 启动时读 /api/auth/config，跟着服务端走。
    loginCode: bool(authRaw.loginCode, d.auth.loginCode),
    // bcrypt 代价因子。10 在手机/中端服务器上约 60~100ms，够用且不拖慢登录。
    bcryptRounds: int(authRaw.bcryptRounds, d.auth.bcryptRounds, 4, 15),
    // 单个用户最多同时保留多少个有效会话（超出时踢掉最旧的）。
    // 0 表示不限制。设一个上限是为了防止「脚本无限登录」把表撑爆。
    maxSessionsPerUser: int(authRaw.maxSessionsPerUser, d.auth.maxSessionsPerUser, 0, 1000),
  },

  // ---------------------------------------------------------------- 邮件
  //
  // 注册要发邮箱验证码，而「邮件从哪发出去」在不同部署环境差别很大：
  // 自己的 VPS 上装 Postfix、用企业邮箱的 SMTP、还是直接调第三方 API。
  // 所以通道做成可切换的（改 mail.driver 即可，不用改代码）。
  mail: {
    // smtp | resend | sendgrid | aliyun | console
    // console 只把邮件打到日志里 —— 仅用于本地开发/演示。
    driver: str(mailRaw.driver, d.mail.driver).toLowerCase(),
    // 发件地址（必须是通道那边验证过的域名/邮箱，否则会被拒）
    from: str(mailRaw.from, d.mail.from),
    fromName: str(mailRaw.fromName, d.mail.fromName),

    // 验证码策略
    codeLength: int(mailRaw.codeLength, d.mail.codeLength, 4, 8),
    // 有效期（秒）。10 分钟是「够用户去看邮箱，又不至于留太久」的经验值。
    codeTtl: int(mailRaw.codeTtl, d.mail.codeTtl, 60, 24 * 3600),
    // 同一邮箱两次索要之间的最小间隔（秒）。防连点、防短信轰炸。
    codeCooldown: int(mailRaw.codeCooldown, d.mail.codeCooldown, 0, 24 * 3600),
    // 同一邮箱 / 同一 IP 每小时最多发多少封
    codeMaxPerEmailHour: int(
      mailRaw.codeMaxPerEmailHour,
      d.mail.codeMaxPerEmailHour,
      1,
      1000,
    ),
    codeMaxPerIpHour: int(mailRaw.codeMaxPerIpHour, d.mail.codeMaxPerIpHour, 1, 5000),
    // 单个验证码允许输错几次（超过就作废，必须重新获取）
    codeMaxAttempts: int(mailRaw.codeMaxAttempts, d.mail.codeMaxAttempts, 1, 20),
    // 开发期把验证码单独打一行到服务端日志（**不进接口响应**）。
    devEchoCode: bool(mailRaw.devEchoCode, d.mail.devEchoCode),
    // 第三方 API 的超时（毫秒）
    httpTimeoutMs: int(mailRaw.httpTimeoutMs, d.mail.httpTimeoutMs, 1000, 120_000),

    // ---- 自建 / 兼容 SMTP 的邮箱
    smtp: {
      host: str(smtpRaw.host, d.mail.smtp.host),
      port: int(smtpRaw.port, d.mail.smtp.port, 1, 65535),
      // 隐式 TLS（465 端口用 true；587/25 用 false + STARTTLS）
      secure: bool(smtpRaw.secure, d.mail.smtp.secure),
      // 明文连上后升级 TLS。除非是同机 Postfix 走 127.0.0.1，否则别关。
      starttls: bool(smtpRaw.starttls, d.mail.smtp.starttls),
      user: str(smtpRaw.user, d.mail.smtp.user),
      password: str(smtpRaw.password, d.mail.smtp.password),
      // 自签证书的内网邮件服务器可以设 false；公网服务保持 true。
      rejectUnauthorized: bool(smtpRaw.rejectUnauthorized, d.mail.smtp.rejectUnauthorized),
      timeoutMs: int(smtpRaw.timeoutMs, d.mail.smtp.timeoutMs, 1000, 120_000),
    },

    // ---- 第三方：Resend
    resend: {
      apiKey: str(resendRaw.apiKey, d.mail.resend.apiKey),
      endpoint: str(resendRaw.endpoint, d.mail.resend.endpoint),
    },

    // ---- 第三方：SendGrid
    sendgrid: {
      apiKey: str(sendgridRaw.apiKey, d.mail.sendgrid.apiKey),
      endpoint: str(sendgridRaw.endpoint, d.mail.sendgrid.endpoint),
    },

    // ---- 第三方：阿里云邮件推送 DirectMail
    aliyun: {
      accessKeyId: str(aliyunRaw.accessKeyId, d.mail.aliyun.accessKeyId),
      accessKeySecret: str(aliyunRaw.accessKeySecret, d.mail.aliyun.accessKeySecret),
      // 发信地址（在阿里云控制台配置的那个，如 no-reply@mail.example.com）
      accountName: str(aliyunRaw.accountName, d.mail.aliyun.accountName),
      region: str(aliyunRaw.region, d.mail.aliyun.region),
      endpoint: str(aliyunRaw.endpoint, d.mail.aliyun.endpoint),
    },
  },

  // ---------------------------------------------------------------- 管理面板
  //
  // 账号不来自配置文件，而是数据库里的 admin_users：
  // 第一次访问时页面会让人自己建第一个管理员（admin 组），之后只能由
  // 已有管理员加人。这里只剩两样「机器该管的东西」：
  //
  //   admin.secret      给登录 cookie 签名。首次启动自动生成并写回 config.yaml。
  //                     换掉它 = 所有管理员立刻掉线（相当于全局踢人）。
  //   admin.setupToken  可选。设了之后，建第一个账号时必须填这个口令，
  //                     防止「部署完还没建号」那几分钟被别人抢注。
  admin: {
    secret: str(adminRaw.secret, d.admin.secret),
    setupToken: str(adminRaw.setupToken, d.admin.setupToken),
    // 登录态有效期（小时）。7 天足够，太久反而给了别人长时间窗口。
    sessionTtlHours: int(adminRaw.sessionTtlHours, d.admin.sessionTtlHours, 1, 24 * 365),
  },

  // ---------------------------------------------------------------- 注销账号
  account: {
    // 用户在客户端申请注销后的冷静期（天）。
    //   0  → 立即删除（不推荐：手滑点错就没救了）
    //   7  → 默认。期间账号仍能登录，登录后可以撤销；
    //        到期由启动任务 / 定时任务 / npm run prune 物理删除。
    // 管理面板「站点」页可以改这个值，改完对**新的**申请生效
    // （已经排期的注销不会因为改配置而提前/推迟 —— 那会让「还有几天」变得不可信）。
    deleteDelayDays: int(accountRaw.deleteDelayDays, d.account.deleteDelayDays, 0, 365),
    // 到期清理的扫描间隔（分钟）。0 = 只靠 npm run prune 与启动时清理。
    purgeIntervalMinutes: int(
      accountRaw.purgeIntervalMinutes,
      d.account.purgeIntervalMinutes,
      0,
      24 * 60,
    ),
  },

  market: {
    // 分段加载的每页条数上限。客户端传更大的值会被夹到这个上限 ——
    // 不设上限的话一个 `?limit=999999` 就能把整个应用表拉出来。
    maxPageSize: int(marketRaw.maxPageSize, d.market.maxPageSize, 1, 500),
    defaultPageSize: int(marketRaw.defaultPageSize, d.market.defaultPageSize, 1, 500),
  },

  packages: {
    // 小程序包根目录：packages/<appId>/<version>.zip
    dir: str(packagesRaw.dir, d.packages.dir),
    // 包大小上限（字节）。与 routes/packages.js 里的常量保持一致。
    maxBytes: int(packagesRaw.maxBytes, d.packages.maxBytes, 1024, 200 * 1024 * 1024),
  },

  icons: {
    // 小程序图标根目录：icons/<appId>.png（管理员在面板里上传）
    dir: str(iconsRaw.dir, d.icons.dir),
    // 图标大小上限（字节）。2MB 对一张 512×512 的图标绰绰有余。
    maxBytes: int(iconsRaw.maxBytes, d.icons.maxBytes, 1024, 20 * 1024 * 1024),
  },

  userdata: {
    // 用户数据根目录：userdata/<id>/data.json 与 userdata/<id>/avatar.png
    dir: str(userdataRaw.dir, d.userdata.dir),
    // 上传头像大小上限（字节）。2MB 对头像绰绰有余。
    maxAvatarBytes: int(
      userdataRaw.maxAvatarBytes,
      d.userdata.maxAvatarBytes,
      1024,
      20 * 1024 * 1024,
    ),
    // data.json 大小上限（字节）。这是「一大块不透明 JSON」，
    // 上限设大一点（16MB）但绝不能无上限 —— 否则一个用户就能把磁盘写满。
    maxDataBytes: int(
      userdataRaw.maxDataBytes,
      d.userdata.maxDataBytes,
      1024,
      256 * 1024 * 1024,
    ),
  },

  root: ROOT,
};

// ================================================================ 环境变量覆盖
//
// 保留这一层是为了容器部署：`docker run -e DB_PASSWORD=...` 比挂载并改写
// 一个 YAML 文件方便得多。键名沿用 1.0 的 .env 变量名，老部署不用改。
//
// 类型写在每一项里：环境变量天生是字符串，"false" 必须变成 false，
// 否则 `trustProxy: "false"` 会被当成真值（所有非空字符串都是真值）。

const ENV_MAP = [
  // http
  ['PORT', 'http.port', 'int'],
  ['HOST', 'http.host', 'str'],
  ['TRUST_PROXY', 'http.trustProxy', 'bool'],

  // db
  ['DB_HOST', 'db.host', 'str'],
  ['DB_PORT', 'db.port', 'int'],
  ['DB_USER', 'db.user', 'str'],
  ['DB_PASSWORD', 'db.password', 'str'],
  ['DB_NAME', 'db.database', 'str'],
  ['DB_POOL_SIZE', 'db.connectionLimit', 'int'],

  // auth
  ['TOKEN_TTL', 'auth.sessionTtl', 'ttl'],
  ['AUTH_REGISTER_CODE', 'auth.registerCode', 'onoff'],
  ['AUTH_LOGIN_CODE', 'auth.loginCode', 'onoff'],
  ['BCRYPT_ROUNDS', 'auth.bcryptRounds', 'int'],
  ['MAX_SESSIONS_PER_USER', 'auth.maxSessionsPerUser', 'int'],

  // mail
  ['MAIL_DRIVER', 'mail.driver', 'lower'],
  ['MAIL_FROM', 'mail.from', 'str'],
  ['MAIL_FROM_NAME', 'mail.fromName', 'str'],
  ['MAIL_CODE_LENGTH', 'mail.codeLength', 'int'],
  ['MAIL_CODE_TTL', 'mail.codeTtl', 'int'],
  ['MAIL_CODE_COOLDOWN', 'mail.codeCooldown', 'int'],
  ['MAIL_CODE_MAX_PER_EMAIL', 'mail.codeMaxPerEmailHour', 'int'],
  ['MAIL_CODE_MAX_PER_IP', 'mail.codeMaxPerIpHour', 'int'],
  ['MAIL_CODE_MAX_ATTEMPTS', 'mail.codeMaxAttempts', 'int'],
  ['MAIL_DEV_ECHO_CODE', 'mail.devEchoCode', 'bool'],
  ['MAIL_HTTP_TIMEOUT_MS', 'mail.httpTimeoutMs', 'int'],
  ['SMTP_HOST', 'mail.smtp.host', 'str'],
  ['SMTP_PORT', 'mail.smtp.port', 'int'],
  ['SMTP_SECURE', 'mail.smtp.secure', 'bool'],
  ['SMTP_STARTTLS', 'mail.smtp.starttls', 'bool'],
  ['SMTP_USER', 'mail.smtp.user', 'str'],
  ['SMTP_PASSWORD', 'mail.smtp.password', 'str'],
  ['SMTP_REJECT_UNAUTHORIZED', 'mail.smtp.rejectUnauthorized', 'bool'],
  ['SMTP_TIMEOUT_MS', 'mail.smtp.timeoutMs', 'int'],
  ['RESEND_API_KEY', 'mail.resend.apiKey', 'str'],
  ['RESEND_ENDPOINT', 'mail.resend.endpoint', 'str'],
  ['SENDGRID_API_KEY', 'mail.sendgrid.apiKey', 'str'],
  ['SENDGRID_ENDPOINT', 'mail.sendgrid.endpoint', 'str'],
  ['ALIYUN_DM_ACCESS_KEY_ID', 'mail.aliyun.accessKeyId', 'str'],
  ['ALIYUN_DM_ACCESS_KEY_SECRET', 'mail.aliyun.accessKeySecret', 'str'],
  ['ALIYUN_DM_ACCOUNT_NAME', 'mail.aliyun.accountName', 'str'],
  ['ALIYUN_DM_REGION', 'mail.aliyun.region', 'str'],
  ['ALIYUN_DM_ENDPOINT', 'mail.aliyun.endpoint', 'str'],

  // admin
  ['ADMIN_SECRET', 'admin.secret', 'str'],
  ['ADMIN_SETUP_TOKEN', 'admin.setupToken', 'str'],
  ['ADMIN_SESSION_HOURS', 'admin.sessionTtlHours', 'int'],

  // account
  ['ACCOUNT_DELETE_DELAY_DAYS', 'account.deleteDelayDays', 'int'],
  ['ACCOUNT_PURGE_INTERVAL_MINUTES', 'account.purgeIntervalMinutes', 'int'],

  // market
  ['MARKET_PAGE_SIZE', 'market.defaultPageSize', 'int'],
  ['MARKET_MAX_PAGE', 'market.maxPageSize', 'int'],

  // files
  ['PACKAGES_DIR', 'packages.dir', 'str'],
  ['PACKAGE_MAX_BYTES', 'packages.maxBytes', 'int'],
  ['ICONS_DIR', 'icons.dir', 'str'],
  ['ICON_MAX_BYTES', 'icons.maxBytes', 'int'],
  ['USERDATA_DIR', 'userdata.dir', 'str'],
  ['AVATAR_MAX_BYTES', 'userdata.maxAvatarBytes', 'int'],
  ['USERDATA_MAX_BYTES', 'userdata.maxDataBytes', 'int'],
];

/** 被环境变量覆盖了哪些项（启动日志里提一句，避免「改了文件却没生效」） */
export const envOverrides = [];

for (const [envKey, path, kind] of ENV_MAP) {
  const raw = process.env[envKey];
  if (raw === undefined || raw === '') continue;

  let value;
  if (kind === 'int') {
    const n = Number.parseInt(raw, 10);
    if (!Number.isFinite(n)) continue;
    value = n;
  } else if (kind === 'bool') {
    const text = raw.trim().toLowerCase();
    if (['true', '1', 'yes', 'on'].includes(text)) value = true;
    else if (['false', '0', 'no', 'off'].includes(text)) value = false;
    else continue;
  } else if (kind === 'onoff') {
    const text = raw.trim().toLowerCase();
    if (['on', 'true', '1', 'yes'].includes(text)) value = true;
    else if (['off', 'false', '0', 'no'].includes(text)) value = false;
    else continue;
  } else if (kind === 'ttl') {
    value = raw.trim() === '0' ? 'never' : raw.trim();
  } else if (kind === 'lower') {
    value = raw.trim().toLowerCase();
  } else {
    value = raw;
  }

  setIn(config, path, value);
  envOverrides.push(`${envKey} → ${path}`);
}

// config.admin.sessionTtlMs 是内部用的毫秒值，由小时换算。
// 用 getter 而不是快照：面板改 hours 之后，下一次签 cookie 就该用新值。
Object.defineProperty(config.admin, 'sessionTtlMs', {
  enumerable: true,
  get: () => config.admin.sessionTtlHours * 3600 * 1000,
});

// ================================================================ 状态

/** config.yaml 是不是本次启动才生成的（需要提示用户去改密码） */
export const configFileCreated = configCreated;

/** 是否真的读到了 config.yaml */
export const configFileExisted = loaded.exists;

// ================================================================ 展示

/** 让人一眼看出「现在用的是不是默认配置」 */
export function describeConfig() {
  const lines = [];
  lines.push(
    `配置   ${CONFIG_PATH}${configFileCreated ? '（本次新建，请改掉 db.password）' : ''}`,
  );
  if (envOverrides.length > 0) {
    lines.push(`覆盖   ${envOverrides.length} 项来自环境变量：${envOverrides.join('，')}`);
  }
  lines.push(`HTTP   ${config.http.host}:${config.http.port}`);
  lines.push(
    `MySQL  ${config.db.user}@${config.db.host}:${config.db.port}/${config.db.database}`,
  );
  lines.push(
    `会话   token ${
      config.auth.sessionTtl === 'never' ? '永不过期' : config.auth.sessionTtl + ' 有效'
    }，落库可撤销`,
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
  lines.push(`小程序图标 ${config.icons.dir}/<appId>.<png|jpg|webp|gif>`);
  lines.push(
    `注销   冷静期 ${config.account.deleteDelayDays} 天` +
      (config.account.deleteDelayDays === 0 ? '（申请即删除）' : '（期间可撤销）'),
  );
  // 邮件通道是「部署后最容易配漏」的一项，启动时就把它摊开说清楚
  lines.push(
    `邮件   ${config.mail.driver}` +
      `（验证码 ${config.mail.codeLength} 位 / ${Math.round(config.mail.codeTtl / 60)} 分钟有效 / ` +
      `${config.mail.codeCooldown}s 冷却）`,
  );
  return lines.join('\n');
}

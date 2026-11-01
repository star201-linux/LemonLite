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
    // token 有效期。7 天是「一周内不用重新登录」的常见折衷。
    // 会话落库（login_sessions），所以这个值可以在运行时改短而不影响已签发的旧会话
    // —— 旧会话按自己的 expires_at 走完，新会话用新值。
    sessionTtl: env('TOKEN_TTL', '7d'),
    // bcrypt 代价因子。10 在手机/中端服务器上约 60~100ms，够用且不拖慢登录。
    bcryptRounds: envInt('BCRYPT_ROUNDS', 10),
    // 单个用户最多同时保留多少个有效会话（超出时踢掉最旧的）。
    // 0 表示不限制。设一个上限是为了防止「脚本无限登录」把表撑爆。
    maxSessionsPerUser: envInt('MAX_SESSIONS_PER_USER', 20),
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
  lines.push(`会话   token ${config.auth.sessionTtl} 有效，落库可撤销`);
  lines.push(
    `用户数据 ${config.userdata.dir}/<id>/{data.json,avatar.png}` +
      `（头像上限 ${Math.round(config.userdata.maxAvatarBytes / 1024 / 1024)}MB）`,
  );
  lines.push(`小程序包 ${config.packages.dir}/<appId>/<version>.zip`);
  return lines.join('\n');
}

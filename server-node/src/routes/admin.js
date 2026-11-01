// server/src/routes/admin.js
//
// 管理面板：一个不需要前端构建、不需要外网的小后台。
//
// 存在理由很实际：邮件通道有一堆参数（SMTP 主机/端口/授权码、第三方 API Key），
// 让用户 ssh 上去改 .env 再重启，是把「配置」变成了「运维」。
//
// 三条安全底线：
//   1. **没有 ADMIN_PASSWORD 就不启用**。一个谁都能打开的后台，
//      比没有后台危险得多 —— 它能改发信通道，等于接管了所有验证码。
//   2. 登录态是签名 cookie（HMAC），不是明文口令；口令本身永远不下发。
//   3. 登录失败限流，且失败信息统一（不区分「没设口令 / 口令错」）。

import { Router } from 'express';
import multer from 'multer';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { config } from '../config.js';
import { execute, query, queryOne } from '../db.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { hashPassword, revokeAllSessions } from '../lib/auth.js';
import { listPackages, removePackage, storePackage } from '../lib/package_store.js';
import { updateEnvFile } from '../lib/envfile.js';
import { SUPPORTED_DRIVERS, MailError, mailStatus, sendMail } from '../lib/mailer.js';
import { verificationMail } from '../lib/mail_templates.js';
import { renderAdminPage } from '../admin/ui.js';

export const adminRouter = Router();

const COOKIE_NAME = 'll_admin';

/** 上传 zip 用内存存储：小程序包上限 20MB，落盘前先在内存里校验魔数与哈希 */
const uploadZip = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 20 * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (!/\.zip$/i.test(file.originalname)) {
      return cb(ApiError.badRequest('bad_package', '小程序包必须是 .zip'));
    }
    return cb(null, true);
  },
});
const ENV_PATH = join(config.root, '.env');

/** 管理口令为空时，面板整体不可用（页面会给出提示） */
function panelEnabled() {
  return config.admin.enabled && String(config.admin.password).length > 0;
}

function cookieSecret() {
  return createHash('sha256')
    .update(`lemonlite-admin:${config.admin.password}`)
    .digest();
}

function signValue(value) {
  return createHmac('sha256', cookieSecret()).update(value).digest('base64url');
}

function makeSessionCookie() {
  const expires = Date.now() + config.admin.sessionTtlMs;
  const payload = String(expires);
  return `${payload}.${signValue(payload)}`;
}

function verifySessionCookie(raw) {
  if (!raw) return false;
  const dot = raw.lastIndexOf('.');
  if (dot <= 0) return false;
  const payload = raw.slice(0, dot);
  const signature = raw.slice(dot + 1);
  const expires = Number.parseInt(payload, 10);
  if (!Number.isFinite(expires) || expires <= Date.now()) return false;
  const expected = Buffer.from(signValue(payload));
  const actual = Buffer.from(signature);
  if (expected.length !== actual.length) return false;
  try {
    return timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}

function parseCookies(header) {
  const out = new Map();
  for (const part of String(header || '').split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    out.set(part.slice(0, eq).trim(), decodeURIComponent(part.slice(eq + 1).trim()));
  }
  return out;
}

/** 登录失败限流：同一 IP 10 分钟内最多 10 次 */
const loginAttempts = new Map();
const LOGIN_WINDOW_MS = 10 * 60 * 1000;
const LOGIN_MAX_TRIES = 10;

function tooManyAttempts(ip) {
  const now = Date.now();
  const entry = loginAttempts.get(ip);
  if (!entry || now > entry.resetAt) {
    loginAttempts.set(ip, { count: 1, resetAt: now + LOGIN_WINDOW_MS });
    return false;
  }
  entry.count += 1;
  return entry.count > LOGIN_MAX_TRIES;
}

/** 口令比较：长度先比，再常量时间比较 */
function passwordMatches(input) {
  const expected = String(config.admin.password);
  const actual = String(input ?? '');
  if (expected.length === 0) return false;
  const a = createHash('sha256').update(actual).digest();
  const b = createHash('sha256').update(expected).digest();
  return timingSafeEqual(a, b);
}

/** 页面与接口的统一守卫 */
function requireAdmin(req, res, next) {
  if (!panelEnabled()) {
    if (req.path.startsWith('/api/')) {
      return res.status(503).json({
        ok: false,
        error: { code: 'admin_disabled', message: '面板未启用：在 .env 里设置 ADMIN_PASSWORD' },
      });
    }
    return res.type('html').send(renderAdminPage({ version: version(), enabled: false }));
  }
  const cookies = parseCookies(req.get('cookie'));
  if (verifySessionCookie(cookies.get(COOKIE_NAME))) return next();
  if (req.path.startsWith('/api/')) {
    return res.status(401).json({ ok: false, error: { code: 'unauthorized', message: '请先登录' } });
  }
  return res.type('html').send(renderAdminPage({ version: version(), enabled: true }));
}

/** 版本号只用于顶栏展示；直接 `node src/server.js` 启动时没有 npm_* 变量，
 *  所以从 package.json 读一次（读失败就显示 dev，不影响任何功能）。 */
let cachedVersion = null;
function version() {
  if (cachedVersion) return cachedVersion;
  try {
    const pkg = JSON.parse(readFileSync(join(config.root, 'package.json'), 'utf8'));
    cachedVersion = String(pkg.version || 'dev');
  } catch {
    cachedVersion = 'dev';
  }
  return cachedVersion;
}

function uptimeLabel() {
  const seconds = Math.floor(process.uptime());
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d} 天 ${h} 小时`;
  if (h > 0) return `${h} 小时 ${m} 分`;
  return `${m} 分`;
}

// ================================================================ 页面

adminRouter.get('/', (req, res) => {
  res.type('html').send(
    renderAdminPage({ version: version(), enabled: panelEnabled() }),
  );
});

// ================================================================ 登录

adminRouter.post(
  '/api/login',
  wrap(async (req, res) => {
    if (!panelEnabled()) {
      throw new ApiError(503, 'admin_disabled', '面板未启用：在 .env 里设置 ADMIN_PASSWORD');
    }
    const ip = req.ip || 'unknown';
    if (tooManyAttempts(ip)) {
      throw new ApiError(429, 'too_many_attempts', '尝试次数过多，请 10 分钟后再试');
    }
    if (!passwordMatches(req.body?.password)) {
      throw new ApiError(401, 'bad_password', '口令不正确');
    }
    res.cookie(COOKIE_NAME, makeSessionCookie(), {
      httpOnly: true,
      sameSite: 'strict',
      path: '/admin',
      maxAge: config.admin.sessionTtlMs,
      // 面板通常跑在内网 HTTP 上，这里不强制 secure（否则本地没法用）
    });
    sendOk(res, { ok: true });
  }),
);

adminRouter.post('/api/logout', (req, res) => {
  res.clearCookie(COOKIE_NAME, { path: '/admin' });
  sendOk(res, { ok: true });
});

// ================================================================ 概况

adminRouter.get(
  '/api/status',
  requireAdmin,
  wrap(async (_req, res) => {
    const [users, apps, sessions, codes] = await Promise.all([
      queryOne('SELECT COUNT(*) AS n FROM users'),
      queryOne('SELECT COUNT(*) AS n FROM apps WHERE deleted_at IS NULL'),
      queryOne(
        `SELECT COUNT(*) AS n FROM login_sessions
          WHERE revoked = 0 AND expires_at > UTC_TIMESTAMP(3)`,
      ),
      queryOne(
        `SELECT COUNT(*) AS n FROM email_codes
          WHERE created_at >= UTC_TIMESTAMP(3) - INTERVAL 1 DAY`,
      ),
    ]);
    const mail = mailStatus();
    sendOk(res, {
      counts: {
        users: Number(users?.n ?? 0),
        apps: Number(apps?.n ?? 0),
        sessions: Number(sessions?.n ?? 0),
        codes24h: Number(codes?.n ?? 0),
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

// ================================================================ 邮件配置

/** 当前配置（密钥类只回「有没有设置」，不回值） */
function mailSnapshot() {
  const m = config.mail;
  const status = mailStatus();
  return {
    driver: m.driver,
    from: m.from,
    fromName: m.fromName,
    smtp: {
      host: m.smtp.host,
      port: m.smtp.port,
      user: m.smtp.user,
      secure: m.smtp.secure,
      starttls: m.smtp.starttls,
      rejectUnauthorized: m.smtp.rejectUnauthorized,
      passwordSet: Boolean(m.smtp.password),
    },
    resend: { apiKeySet: Boolean(m.resend.apiKey) },
    sendgrid: { apiKeySet: Boolean(m.sendgrid.apiKey) },
    aliyun: {
      accessKeyId: m.aliyun.accessKeyId,
      accountName: m.aliyun.accountName,
      region: m.aliyun.region,
      accessKeySecretSet: Boolean(m.aliyun.accessKeySecret),
    },
    codeTtl: m.codeTtl,
    codeCooldown: m.codeCooldown,
    codeMaxPerEmailHour: m.codeMaxPerEmailHour,
    codeMaxPerIpHour: m.codeMaxPerIpHour,
    codeMaxAttempts: m.codeMaxAttempts,
    devEchoCode: m.devEchoCode,
    tokenTtl: config.auth.sessionTtl,
    registerCode: config.auth.registerCode,
    loginCode: config.auth.loginCode,
    ready: status.ready,
    reason: status.reason,
  };
}

adminRouter.get('/api/mail', requireAdmin, (_req, res) => {
  sendOk(res, mailSnapshot());
});

/** 从请求体读一个数字，夹到合理区间 */
function intIn(value, fallback, min, max) {
  const n = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

adminRouter.put(
  '/api/mail',
  requireAdmin,
  wrap(async (req, res) => {
    const body = req.body ?? {};
    const driver = String(body.driver ?? config.mail.driver).toLowerCase();
    if (!SUPPORTED_DRIVERS.includes(driver)) {
      throw ApiError.badRequest('bad_driver', `不认识的通道：${driver}`);
    }

    const next = {
      driver,
      from: String(body.from ?? config.mail.from).trim(),
      fromName: String(body.fromName ?? config.mail.fromName).trim(),
      smtp: {
        host: String(body.smtp?.host ?? config.mail.smtp.host).trim(),
        port: intIn(body.smtp?.port, config.mail.smtp.port, 1, 65535),
        user: String(body.smtp?.user ?? config.mail.smtp.user).trim(),
        // 空串 = 保持原值（前端为了不回显密钥，留空表示「不修改」）
        password: String(body.smtp?.password ?? '') || config.mail.smtp.password,
        secure: body.smtp?.secure ?? config.mail.smtp.secure,
        starttls: body.smtp?.starttls ?? config.mail.smtp.starttls,
        rejectUnauthorized:
          body.smtp?.rejectUnauthorized ?? config.mail.smtp.rejectUnauthorized,
      },
      resend: {
        apiKey: String(body.resend?.apiKey ?? '') || config.mail.resend.apiKey,
      },
      sendgrid: {
        apiKey: String(body.sendgrid?.apiKey ?? '') || config.mail.sendgrid.apiKey,
      },
      aliyun: {
        accessKeyId: String(body.aliyun?.accessKeyId ?? config.mail.aliyun.accessKeyId).trim(),
        accessKeySecret:
          String(body.aliyun?.accessKeySecret ?? '') || config.mail.aliyun.accessKeySecret,
        accountName: String(
          body.aliyun?.accountName ?? config.mail.aliyun.accountName,
        ).trim(),
        region: String(body.aliyun?.region ?? config.mail.aliyun.region).trim() || 'cn-hangzhou',
      },
    };

    if (driver !== 'console' && !next.from) {
      throw ApiError.badRequest('missing_from', '除 console 外都必须填发件地址 MAIL_FROM');
    }

    // ---- 写回 .env（重启后依然生效）
    const envValues = {
      MAIL_DRIVER: next.driver,
      MAIL_FROM: next.from,
      MAIL_FROM_NAME: next.fromName,
      SMTP_HOST: next.smtp.host,
      SMTP_PORT: next.smtp.port,
      SMTP_USER: next.smtp.user,
      SMTP_SECURE: String(next.smtp.secure),
      SMTP_STARTTLS: String(next.smtp.starttls),
      SMTP_REJECT_UNAUTHORIZED: String(next.smtp.rejectUnauthorized),
      RESEND_API_KEY: next.resend.apiKey,
      SENDGRID_API_KEY: next.sendgrid.apiKey,
      ALIYUN_DM_ACCESS_KEY_ID: next.aliyun.accessKeyId,
      ALIYUN_DM_ACCESS_KEY_SECRET: next.aliyun.accessKeySecret,
      ALIYUN_DM_ACCOUNT_NAME: next.aliyun.accountName,
      ALIYUN_DM_REGION: next.aliyun.region,
    };
    if (next.smtp.password || body.smtp?.password) {
      envValues.SMTP_PASSWORD = next.smtp.password;
    }
    if (body.codeTtl !== undefined) {
      envValues.MAIL_CODE_TTL = intIn(body.codeTtl, config.mail.codeTtl, 60, 3600);
    }
    if (body.codeCooldown !== undefined) {
      envValues.MAIL_CODE_COOLDOWN = intIn(body.codeCooldown, config.mail.codeCooldown, 0, 600);
    }
    if (body.codeMaxPerEmailHour !== undefined) {
      envValues.MAIL_CODE_MAX_PER_EMAIL = intIn(body.codeMaxPerEmailHour, 10, 1, 200);
    }
    if (body.codeMaxPerIpHour !== undefined) {
      envValues.MAIL_CODE_MAX_PER_IP = intIn(body.codeMaxPerIpHour, 30, 1, 500);
    }
    if (body.codeMaxAttempts !== undefined) {
      envValues.MAIL_CODE_MAX_ATTEMPTS = intIn(body.codeMaxAttempts, 5, 1, 20);
    }
    if (body.devEchoCode !== undefined) {
      envValues.MAIL_DEV_ECHO_CODE = String(Boolean(body.devEchoCode));
    }
    if (body.tokenTtl !== undefined) {
      const ttl = String(body.tokenTtl).trim();
      if (!/^(never|\d+(ms|s|m|h|d))$/.test(ttl)) {
        throw ApiError.badRequest('bad_ttl', 'token 有效期只能是 never 或 7d / 12h / 30m 这类写法');
      }
      envValues.TOKEN_TTL = ttl;
    }
    if (body.registerCode !== undefined) {
      envValues.AUTH_REGISTER_CODE = body.registerCode ? 'on' : 'off';
    }
    if (body.loginCode !== undefined) {
      envValues.AUTH_LOGIN_CODE = body.loginCode ? 'on' : 'off';
    }

    updateEnvFile(ENV_PATH, envValues);

    // ---- 立即应用到内存（不重启即可生效）
    config.mail.driver = next.driver;
    config.mail.from = next.from;
    config.mail.fromName = next.fromName;
    Object.assign(config.mail.smtp, next.smtp);
    Object.assign(config.mail.resend, next.resend);
    Object.assign(config.mail.sendgrid, next.sendgrid);
    Object.assign(config.mail.aliyun, next.aliyun);
    if (envValues.MAIL_CODE_TTL) config.mail.codeTtl = Number(envValues.MAIL_CODE_TTL);
    if (envValues.MAIL_CODE_COOLDOWN) {
      config.mail.codeCooldown = Number(envValues.MAIL_CODE_COOLDOWN);
    }
    if (envValues.MAIL_CODE_MAX_PER_EMAIL) {
      config.mail.codeMaxPerEmailHour = Number(envValues.MAIL_CODE_MAX_PER_EMAIL);
    }
    if (envValues.MAIL_CODE_MAX_PER_IP) {
      config.mail.codeMaxPerIpHour = Number(envValues.MAIL_CODE_MAX_PER_IP);
    }
    if (envValues.MAIL_CODE_MAX_ATTEMPTS) {
      config.mail.codeMaxAttempts = Number(envValues.MAIL_CODE_MAX_ATTEMPTS);
    }
    if (envValues.MAIL_DEV_ECHO_CODE !== undefined) {
      config.mail.devEchoCode = envValues.MAIL_DEV_ECHO_CODE === 'true';
    }
    if (envValues.TOKEN_TTL) config.auth.sessionTtl = envValues.TOKEN_TTL;
    if (envValues.AUTH_REGISTER_CODE) {
      config.auth.registerCode = envValues.AUTH_REGISTER_CODE === 'on';
    }
    if (envValues.AUTH_LOGIN_CODE) {
      config.auth.loginCode = envValues.AUTH_LOGIN_CODE === 'on';
    }

    sendOk(res, { saved: true, mail: mailSnapshot() });
  }),
);

adminRouter.post(
  '/api/mail/test',
  requireAdmin,
  wrap(async (req, res) => {
    const to = String(req.body?.to ?? '').trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(to)) {
      throw ApiError.badRequest('bad_email', '收件地址格式不对');
    }
    const status = mailStatus();
    if (!status.ready) {
      throw new ApiError(503, 'mail_not_configured', `通道未就绪：${status.reason}`);
    }
    const started = Date.now();
    const template = verificationMail({
      code: '123456',
      ttlSeconds: config.mail.codeTtl,
      purpose: 'login',
    });
    try {
      await sendMail({
        to,
        subject: `【测试】${template.subject}`,
        text: `这是一封来自管理面板的测试邮件。\n\n${template.text}`,
        html: template.html,
      });
    } catch (e) {
      const message = e instanceof MailError ? e.message : String(e);
      throw new ApiError(502, 'mail_send_failed', message);
    }
    sendOk(res, { sent: true, driver: status.driver, ms: Date.now() - started });
  }),
);

// ================================================================ 应用管理

const APP_ID_RE = /^[A-Za-z0-9][\w.-]{1,63}$/;
const VERSION_RE = /^[\w.+-]{1,32}$/;

/** 数据库行 → 面板用的应用对象 */
function appToDto(row) {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    categoryId: row.category_id ?? '',
    categoryName: row.category_name ?? '',
    version: row.version,
    author: row.author,
    packageUrl: row.package_url ?? '',
    packageEntry: row.package_entry ?? 'index.html',
    packageSha256: row.package_sha256 ?? '',
    packageBytes: Number(row.package_bytes) || 0,
    icon: row.icon ?? '',
    homepage: row.homepage ?? '',
    screenshots: parseJsonArray(row.screenshots),
    permissions: parseJsonArray(row.permissions),
    tagNames: row.tag_names ? String(row.tag_names).split(',') : [],
    sortWeight: Number(row.sort_weight) || 0,
    publishedAt: row.published_at,
    updatedAt: row.updated_at,
    deleted: Boolean(row.deleted_at),
    deletedAt: row.deleted_at ?? '',
  };
}

/** 取一条应用（含分类名与标签名）：新建/保存后的响应要用同一份口径，
 *  否则列表里有标签、保存返回里没有，前端会以为标签没存上。 */
function fetchAppRow(id) {
  return queryOne(
    `SELECT a.*, c.name AS category_name,
            (SELECT GROUP_CONCAT(t.name ORDER BY t.name)
               FROM app_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.app_id = a.id) AS tag_names
       FROM apps a
       LEFT JOIN categories c ON c.id = a.category_id
      WHERE a.id = ?`,
    [id],
  );
}

function parseJsonArray(value) {
  if (Array.isArray(value)) return value;
  if (typeof value !== 'string' || !value.trim()) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/** 从请求体取应用字段（新建与编辑共用） */
function readAppFields(body, { creating }) {
  const id = String(body.id ?? '').trim();
  const name = String(body.name ?? '').trim();
  if (!name) throw ApiError.badRequest('missing_name', '应用名称不能为空');
  if (name.length > 128) throw ApiError.badRequest('bad_name', '应用名称最多 128 个字符');

  const version = String(body.version ?? '1.0.0').trim() || '1.0.0';
  if (!VERSION_RE.test(version)) {
    throw ApiError.badRequest('bad_version', '版本号只能包含字母、数字、点、加号和连字符');
  }

  const entry = String(body.packageEntry ?? 'index.html').trim() || 'index.html';
  if (entry.startsWith('/') || entry.includes('..')) {
    throw ApiError.badRequest('bad_entry', '入口必须是包内的相对路径');
  }

  if (creating && !APP_ID_RE.test(id)) {
    throw ApiError.badRequest(
      'bad_id',
      '应用 id 只能包含字母、数字、下划线、点和连字符，且以字母或数字开头',
    );
  }

  return {
    id,
    name,
    description: String(body.description ?? '').trim(),
    categoryId: String(body.categoryId ?? '').trim() || null,
    version,
    author: String(body.author ?? '').trim(),
    packageEntry: entry,
    icon: String(body.icon ?? '').trim(),
    homepage: String(body.homepage ?? '').trim(),
    screenshots: Array.isArray(body.screenshots)
      ? body.screenshots.map((x) => String(x).trim()).filter(Boolean).slice(0, 12)
      : [],
    permissions: Array.isArray(body.permissions)
      ? body.permissions.map((x) => String(x).trim()).filter(Boolean).slice(0, 32)
      : [],
    sortWeight: intIn(body.sortWeight, 0, -100000, 100000),
  };
}

/** 重建 app ↔ tag 关联（未知标签名直接忽略，不自动建标签） */
async function replaceAppTags(appId, tagNames) {
  await execute('DELETE FROM app_tags WHERE app_id = ?', [appId]);
  if (!tagNames?.length) return;
  const rows = await query(
    `SELECT id FROM tags WHERE name IN (${tagNames.map(() => '?').join(',')})`,
    tagNames,
  );
  for (const row of rows) {
    await execute('INSERT IGNORE INTO app_tags (app_id, tag_id) VALUES (?, ?)', [
      appId,
      row.id,
    ]);
  }
}

adminRouter.get(
  '/api/apps',
  requireAdmin,
  wrap(async (req, res) => {
    const q = String(req.query.q ?? '').trim();
    const like = `%${q}%`;
    const rows = await query(
      `SELECT a.*, c.name AS category_name,
              (SELECT GROUP_CONCAT(t.name ORDER BY t.name)
                 FROM app_tags at JOIN tags t ON t.id = at.tag_id
                WHERE at.app_id = a.id) AS tag_names
         FROM apps a
         LEFT JOIN categories c ON c.id = a.category_id
        WHERE (? = '' OR a.id LIKE ? OR a.name LIKE ?)
        ORDER BY a.sort_weight DESC, a.updated_at DESC
        LIMIT 200`,
      [q, like, like],
    );
    sendOk(res, { apps: rows.map(appToDto) });
  }),
);

adminRouter.get(
  '/api/categories',
  requireAdmin,
  wrap(async (_req, res) => {
    const categories = await query('SELECT id, name, sort_order FROM categories ORDER BY sort_order, id');
    const tags = await query('SELECT id, name, slug FROM tags ORDER BY name');
    sendOk(res, {
      categories: categories.map((c) => ({ id: c.id, name: c.name })),
      tags: tags.map((t) => ({ id: Number(t.id), name: t.name, slug: t.slug })),
    });
  }),
);

adminRouter.post(
  '/api/apps',
  requireAdmin,
  wrap(async (req, res) => {
    const fields = readAppFields(req.body ?? {}, { creating: true });
    const exists = await queryOne('SELECT id FROM apps WHERE id = ? LIMIT 1', [fields.id]);
    if (exists) throw ApiError.conflict('app_exists', '这个 id 已经被占用了');

    if (fields.categoryId) {
      const cat = await queryOne('SELECT id FROM categories WHERE id = ?', [
        fields.categoryId,
      ]);
      if (!cat) throw ApiError.badRequest('bad_category', '分类不存在');
    }

    await execute(
      `INSERT INTO apps
         (id, name, description, category_id, version, author,
          package_entry, icon, homepage, screenshots, permissions, sort_weight)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        fields.id,
        fields.name,
        fields.description,
        fields.categoryId,
        fields.version,
        fields.author,
        fields.packageEntry,
        fields.icon || null,
        fields.homepage || null,
        JSON.stringify(fields.screenshots),
        JSON.stringify(fields.permissions),
        fields.sortWeight,
      ],
    );
    await replaceAppTags(fields.id, req.body?.tagNames);

    sendOk(res, { app: appToDto(await fetchAppRow(fields.id)) });
  }),
);

adminRouter.put(
  '/api/apps/:id',
  requireAdmin,
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const current = await queryOne('SELECT * FROM apps WHERE id = ?', [id]);
    if (!current) throw ApiError.notFound('没有这个应用');

    // 单独支持「上架 / 下架」：只传 deleted 时不动其它字段
    if (req.body?.deleted !== undefined && Object.keys(req.body).length === 1) {
      await execute('UPDATE apps SET deleted_at = ? WHERE id = ?', [
        req.body.deleted ? new Date() : null,
        id,
      ]);
      return sendOk(res, { app: appToDto(await fetchAppRow(id)) });
    }

    const fields = readAppFields({ ...req.body, id }, { creating: false });
    if (fields.categoryId) {
      const cat = await queryOne('SELECT id FROM categories WHERE id = ?', [
        fields.categoryId,
      ]);
      if (!cat) throw ApiError.badRequest('bad_category', '分类不存在');
    }

    await execute(
      `UPDATE apps SET
         name = ?, description = ?, category_id = ?, version = ?, author = ?,
         package_entry = ?, icon = ?, homepage = ?, screenshots = ?,
         permissions = ?, sort_weight = ?
       WHERE id = ?`,
      [
        fields.name,
        fields.description,
        fields.categoryId,
        fields.version,
        fields.author,
        fields.packageEntry,
        fields.icon || null,
        fields.homepage || null,
        JSON.stringify(fields.screenshots),
        JSON.stringify(fields.permissions),
        fields.sortWeight,
        id,
      ],
    );
    if (req.body?.tagNames !== undefined) {
      await replaceAppTags(id, req.body.tagNames);
    }

    sendOk(res, { app: appToDto(await fetchAppRow(id)) });
  }),
);

adminRouter.delete(
  '/api/apps/:id',
  requireAdmin,
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const row = await queryOne('SELECT id FROM apps WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个应用');
    // 软删除：市场不再返回它，但数据还在，误删可以改回来
    await execute('UPDATE apps SET deleted_at = NOW(3) WHERE id = ?', [id]);
    sendOk(res, { deleted: true, restorable: true });
  }),
);

adminRouter.post(
  '/api/apps/:id/package',
  requireAdmin,
  uploadZip.single('file'),
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const version = String(req.body?.version ?? '').trim();
    const entry = String(req.body?.entry ?? 'index.html').trim() || 'index.html';

    const app = await queryOne('SELECT id, version FROM apps WHERE id = ?', [id]);
    if (!app) throw ApiError.notFound('没有这个应用');
    if (!req.file?.buffer?.length) {
      throw ApiError.badRequest('no_file', '没有收到文件（字段名应为 file）');
    }
    if (!VERSION_RE.test(version)) {
      throw ApiError.badRequest('bad_version', '版本号只能包含字母、数字、点、加号和连字符');
    }
    if (entry.startsWith('/') || entry.includes('..')) {
      throw ApiError.badRequest('bad_entry', '入口必须是包内的相对路径');
    }

    const stored = await storePackage({ appId: id, version, buffer: req.file.buffer });

    // 版本号、包地址、入口、哈希、大小必须一次性写入：
    // 「版本变了但包没变」会让客户端一直提示升级却升不上去。
    await execute(
      `UPDATE apps
          SET version = ?, package_url = ?, package_entry = ?,
              package_sha256 = ?, package_bytes = ?
        WHERE id = ?`,
      [version, stored.relUrl, entry, stored.sha256, stored.bytes, id],
    );

    sendOk(res, {
      appId: id,
      version,
      entry,
      sha256: stored.sha256,
      bytes: stored.bytes,
      previousVersion: app.version,
    });
  }),
);

adminRouter.get(
  '/api/apps/:id/packages',
  requireAdmin,
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    sendOk(res, { packages: await listPackages(id) });
  }),
);

adminRouter.delete(
  '/api/apps/:id/package/:version',
  requireAdmin,
  wrap(async (req, res) => {
    const id = String(req.params.id ?? '').trim();
    const version = String(req.params.version ?? '').trim();
    const removed = await removePackage(id, version);
    // 删掉的正是当前上架版本时，把 apps 里的包字段清空（否则市场会指向不存在的文件）
    const app = await queryOne('SELECT version FROM apps WHERE id = ?', [id]);
    if (app && app.version === version) {
      await execute(
        `UPDATE apps
            SET package_url = NULL, package_sha256 = NULL, package_bytes = 0
          WHERE id = ?`,
        [id],
      );
    }
    sendOk(res, { removed });
  }),
);

// ================================================================ 用户管理

adminRouter.post(
  '/api/users/:id/status',
  requireAdmin,
  wrap(async (req, res) => {
    const id = Number.parseInt(String(req.params.id ?? ''), 10);
    const status = String(req.body?.status ?? '').trim();
    if (!Number.isFinite(id)) throw ApiError.badRequest('bad_id', '用户 id 不合法');
    if (!['active', 'disabled'].includes(status)) {
      throw ApiError.badRequest('bad_status', '状态只能是 active 或 disabled');
    }
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    await execute('UPDATE users SET status = ? WHERE id = ?', [status, id]);
    // 封禁要立刻生效：光改 status 只是拦下一次校验，已经登录的设备还揣着 token
    if (status === 'disabled') await revokeAllSessions(id);
    sendOk(res, { id, status });
  }),
);

adminRouter.post(
  '/api/users/:id/password',
  requireAdmin,
  wrap(async (req, res) => {
    const id = Number.parseInt(String(req.params.id ?? ''), 10);
    const password = String(req.body?.password ?? '');
    if (!Number.isFinite(id)) throw ApiError.badRequest('bad_id', '用户 id 不合法');
    if (password.length < 8) throw ApiError.badRequest('weak_password', '密码至少 8 位');
    const row = await queryOne('SELECT id FROM users WHERE id = ?', [id]);
    if (!row) throw ApiError.notFound('没有这个用户');

    await execute('UPDATE users SET password_hash = ? WHERE id = ?', [
      await hashPassword(password),
      id,
    ]);
    // 改密码 = 把这个人从所有设备上踢下去（管理面板代改的场合尤其如此）
    await revokeAllSessions(id);
    sendOk(res, { id, updated: true });
  }),
);

adminRouter.post(
  '/api/users/:id/logout',
  requireAdmin,
  wrap(async (req, res) => {
    const id = Number.parseInt(String(req.params.id ?? ''), 10);
    if (!Number.isFinite(id)) throw ApiError.badRequest('bad_id', '用户 id 不合法');
    await revokeAllSessions(id);
    sendOk(res, { id, loggedOut: true });
  }),
);

// ================================================================ 用户列表

adminRouter.get(
  '/api/users',
  requireAdmin,
  wrap(async (_req, res) => {
    const q = String(_req.query.q ?? '').trim();
    const like = `%${q}%`;
    const rows = await query(
      `SELECT id, username, email, status, created_at, created_ip
         FROM users
        WHERE (? = '' OR username LIKE ? OR email LIKE ?)
        ORDER BY id DESC LIMIT 100`,
      [q, like, like],
    );
    sendOk(res, {
      users: rows.map((r) => ({
        id: Number(r.id),
        username: r.username,
        email: r.email,
        status: r.status,
        createdAt: r.created_at,
        createdIp: r.created_ip,
      })),
    });
  }),
);

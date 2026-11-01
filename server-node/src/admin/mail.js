// server/src/admin/mail.js
//
// 面板的「邮件」页：通道配置 + 测试发信 + 验证码/token 策略。
//
// 这些参数全部写进 .env 再同步到内存里的 config —— 不需要重启。
// 密钥类字段（SMTP 密码、API Key）**不会回显**，接口只告诉前端「有没有设置」，
// 留空提交表示「不修改」。这样即使有人偷看响应，也拿不到密钥。

import { Router } from 'express';
import { join } from 'node:path';
import { config } from '../config.js';
import { ApiError, sendOk, wrap } from '../lib/http.js';
import { updateEnvFile } from '../lib/envfile.js';
import { SUPPORTED_DRIVERS, MailError, mailStatus, sendMail } from '../lib/mailer.js';
import { verificationMail } from '../lib/mail_templates.js';
import { intIn } from './shared.js';

export const mailRouter = Router();

const ENV_PATH = join(config.root, '.env');

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

mailRouter.get('/api/mail', (_req, res) => {
  sendOk(res, mailSnapshot());
});

mailRouter.put(
  '/api/mail',
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
        region: String(body.aliyun?.region ?? config.mail.aliyun.region).trim(),
      },
    };

    // ---- 先校验再落盘：写坏 .env 的后果比「保存失败」严重得多
    const envValues = {
      MAIL_DRIVER: next.driver,
      MAIL_FROM: next.from,
      MAIL_FROM_NAME: next.fromName,
      SMTP_HOST: next.smtp.host,
      SMTP_PORT: String(next.smtp.port),
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
    // 密钥类只有真的填了才写，避免「留空提交」把已保存的密钥清掉
    if (body.smtp?.password) envValues.SMTP_PASSWORD = next.smtp.password;
    if (body.resend?.apiKey) envValues.RESEND_API_KEY = next.resend.apiKey;
    if (body.sendgrid?.apiKey) envValues.SENDGRID_API_KEY = next.sendgrid.apiKey;
    if (body.aliyun?.accessKeySecret) {
      envValues.ALIYUN_DM_ACCESS_KEY_SECRET = next.aliyun.accessKeySecret;
    }

    if (body.codeTtl !== undefined) {
      envValues.MAIL_CODE_TTL = String(intIn(body.codeTtl, config.mail.codeTtl, 60, 3600));
    }
    if (body.codeCooldown !== undefined) {
      envValues.MAIL_CODE_COOLDOWN = String(
        intIn(body.codeCooldown, config.mail.codeCooldown, 0, 3600),
      );
    }
    if (body.codeMaxPerEmailHour !== undefined) {
      envValues.MAIL_CODE_MAX_PER_EMAIL = String(
        intIn(body.codeMaxPerEmailHour, config.mail.codeMaxPerEmailHour, 1, 1000),
      );
    }
    if (body.codeMaxPerIpHour !== undefined) {
      envValues.MAIL_CODE_MAX_PER_IP = String(
        intIn(body.codeMaxPerIpHour, config.mail.codeMaxPerIpHour, 1, 5000),
      );
    }
    if (body.codeMaxAttempts !== undefined) {
      envValues.MAIL_CODE_MAX_ATTEMPTS = String(
        intIn(body.codeMaxAttempts, config.mail.codeMaxAttempts, 1, 20),
      );
    }
    if (body.devEchoCode !== undefined) {
      envValues.MAIL_DEV_ECHO_CODE = body.devEchoCode ? 'true' : 'false';
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

mailRouter.post(
  '/api/mail/test',
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

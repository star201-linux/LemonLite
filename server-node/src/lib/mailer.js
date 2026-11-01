// server/src/lib/mailer.js
//
// 邮件发送的唯一出口。
//
// 需求是「邮箱可以选择自部署还是用第三方服务」，所以这里做了一层
// 传输通道抽象：调用方只写 `sendMail({to, subject, text, html})`，
// 具体走哪条路由 `MAIL_DRIVER` 决定：
//
//   smtp      自建 / 任何兼容 SMTP 的邮箱（Postfix、企业邮、QQ/163 授权码）
//   resend    Resend（API Key，一个 POST 就完事，海外最省事）
//   sendgrid  Twilio SendGrid（API Key）
//   aliyun    阿里云邮件推送 DirectMail（AK/SK + RPC 签名，国内送达率最好）
//   console   不发信，只在服务端日志里打印内容（**仅开发用**）
//
// 为什么把「通道」做成配置而不是抽象类继承：
//   运维要改的只是一个环境变量，不需要改代码、不需要重新构建镜像。
//   切换通道的代价应该是「改一行 .env 再重启」。

import { createHmac, randomUUID } from 'node:crypto';
import { config } from '../config.js';
import { sendSmtp } from './smtp.js';

/** 邮件发送失败。路由层据此回 503 + 可读原因，而不是 500。 */
export class MailError extends Error {
  constructor(message, { driver, cause, code = 'mail_failed' } = {}) {
    super(message);
    this.name = 'MailError';
    this.driver = driver;
    this.cause = cause;
    this.code = code;
  }
}

export const SUPPORTED_DRIVERS = Object.freeze([
  'smtp',
  'resend',
  'sendgrid',
  'aliyun',
  'console',
]);

/** 当前配置的通道是否「够用」（缺关键配置时提前失败，而不是发信时才炸） */
export function mailStatus() {
  const m = config.mail;
  const driver = m.driver;
  if (!SUPPORTED_DRIVERS.includes(driver)) {
    return {
      ready: false,
      driver,
      reason: `MAIL_DRIVER=${driver} 不认识（可选：${SUPPORTED_DRIVERS.join(' / ')}）`,
    };
  }
  if (driver === 'console') {
    return { ready: true, driver, reason: '控制台通道：邮件不会真的发出去，只打印日志' };
  }
  if (!m.from) {
    return { ready: false, driver, reason: '没有配置 MAIL_FROM（发件地址）' };
  }
  switch (driver) {
    case 'smtp':
      if (!m.smtp.host) {
        return { ready: false, driver, reason: '没有配置 SMTP_HOST' };
      }
      return { ready: true, driver, reason: `${m.smtp.host}:${m.smtp.port}` };
    case 'resend':
      return m.resend.apiKey
        ? { ready: true, driver, reason: 'Resend API' }
        : { ready: false, driver, reason: '没有配置 RESEND_API_KEY' };
    case 'sendgrid':
      return m.sendgrid.apiKey
        ? { ready: true, driver, reason: 'SendGrid API' }
        : { ready: false, driver, reason: '没有配置 SENDGRID_API_KEY' };
    case 'aliyun':
      if (!m.aliyun.accessKeyId || !m.aliyun.accessKeySecret) {
        return { ready: false, driver, reason: '没有配置 ALIYUN_DM_ACCESS_KEY_ID / SECRET' };
      }
      if (!m.aliyun.accountName) {
        return { ready: false, driver, reason: '没有配置 ALIYUN_DM_ACCOUNT_NAME（发信地址）' };
      }
      return { ready: true, driver, reason: '阿里云邮件推送' };
    default:
      return { ready: false, driver, reason: '未知通道' };
  }
}

// ---------------------------------------------------------------- 第三方 HTTP API

/** 带超时的 fetch；把底层网络错误统一包成 MailError */
async function postJson(url, { headers, body, driver }) {
  let res;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(config.mail.httpTimeoutMs),
    });
  } catch (e) {
    throw new MailError(`请求 ${driver} 失败：${e.message}`, { driver, cause: e });
  }
  const text = await res.text().catch(() => '');
  if (!res.ok) {
    throw new MailError(
      `${driver} 返回 ${res.status}：${text.slice(0, 300) || '（空响应）'}`,
      { driver, code: 'provider_rejected' },
    );
  }
  return text;
}

/** Resend：https://resend.com/docs/api-reference/emails/send-email */
async function sendViaResend({ to, subject, text, html }) {
  const m = config.mail;
  const from = m.fromName ? `${m.fromName} <${m.from}>` : m.from;
  await postJson(m.resend.endpoint, {
    driver: 'resend',
    headers: { Authorization: `Bearer ${m.resend.apiKey}` },
    body: {
      from,
      to: [to],
      subject,
      text,
      ...(html ? { html } : {}),
    },
  });
}

/** SendGrid v3：https://www.twilio.com/docs/sendgrid/api-reference */
async function sendViaSendgrid({ to, subject, text, html }) {
  const m = config.mail;
  await postJson(m.sendgrid.endpoint, {
    driver: 'sendgrid',
    headers: { Authorization: `Bearer ${m.sendgrid.apiKey}` },
    body: {
      personalizations: [{ to: [{ email: to }] }],
      from: {
        email: m.from,
        ...(m.fromName ? { name: m.fromName } : {}),
      },
      subject,
      content: [
        { type: 'text/plain', value: text || '' },
        ...(html ? [{ type: 'text/html', value: html }] : []),
      ],
    },
  });
}

/** 阿里云 RPC 签名要求的百分号编码（RFC 3986，空格是 %20 不是 +） */
function rfc3986(value) {
  return encodeURIComponent(String(value))
    .replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
    .replace(/%7E/g, '~');
}

/**
 * 阿里云邮件推送 DirectMail（RPC 风格签名）：
 *   https://help.aliyun.com/document_detail/29444.html
 *
 * 之所以自己算签名而不装 @alicloud/dm20170622：
 *   官方 SDK 带一长串依赖，而我们只用得到一个 SingleSendMail。
 */
async function sendViaAliyun({ to, subject, text, html }) {
  const m = config.mail;
  const params = {
    Action: 'SingleSendMail',
    Version: '2015-11-23',
    Format: 'JSON',
    RegionId: m.aliyun.region,
    AccessKeyId: m.aliyun.accessKeyId,
    SignatureMethod: 'HMAC-SHA1',
    SignatureVersion: '1.0',
    SignatureNonce: randomUUID(),
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    AccountName: m.aliyun.accountName,
    AddressType: '1', // 1 = 发信地址是随机账号
    ReplyToAddress: 'false',
    ToAddress: to,
    Subject: subject,
    TextBody: text || '',
    ...(html ? { HtmlBody: html } : {}),
  };

  const canonical = Object.keys(params)
    .sort()
    .map((key) => `${rfc3986(key)}=${rfc3986(params[key])}`)
    .join('&');

  const stringToSign = `GET&${rfc3986('/')}&${rfc3986(canonical)}`;
  const signature = createHmac('sha1', `${m.aliyun.accessKeySecret}&`)
    .update(stringToSign)
    .digest('base64');

  const url = `${m.aliyun.endpoint}?${canonical}&Signature=${rfc3986(signature)}`;
  let res;
  try {
    res = await fetch(url, { signal: AbortSignal.timeout(m.httpTimeoutMs) });
  } catch (e) {
    throw new MailError(`请求阿里云失败：${e.message}`, {
      driver: 'aliyun',
      cause: e,
    });
  }
  const body = await res.text().catch(() => '');
  if (!res.ok) {
    throw new MailError(`阿里云返回 ${res.status}：${body.slice(0, 300)}`, {
      driver: 'aliyun',
      code: 'provider_rejected',
    });
  }
  // 阿里云即便 HTTP 200 也可能在体里报业务错误
  if (/"Code"\s*:\s*"([^"]+)"/.test(body) && !/"Code"\s*:\s*"OK"/.test(body)) {
    throw new MailError(`阿里云拒绝发信：${body.slice(0, 300)}`, {
      driver: 'aliyun',
      code: 'provider_rejected',
    });
  }
}

// ---------------------------------------------------------------- 对外接口

/**
 * 发一封邮件。失败抛 MailError（带 `code`，路由层可直接映射到 HTTP）。
 *
 * @param {{ to: string, subject: string, text: string, html?: string }} mail
 * @returns {Promise<{driver: string}>}
 */
export async function sendMail(mail) {
  const m = config.mail;
  const status = mailStatus();
  if (!status.ready) {
    throw new MailError(`邮件通道未就绪：${status.reason}`, {
      driver: status.driver,
      code: 'mail_not_configured',
    });
  }

  const to = String(mail.to ?? '').trim();
  if (!to) throw new MailError('收件地址为空', { code: 'bad_address' });

  switch (m.driver) {
    case 'console': {
      // 开发通道：把邮件打到日志里，方便在本机跑通注册流程
      console.log('');
      console.log('\x1b[35m─── 邮件（console 通道，未真正发送）───\x1b[0m');
      console.log(`  收件人 ${to}`);
      console.log(`  主题   ${mail.subject}`);
      console.log(
        mail.text
          .split('\n')
          .map((line) => `  │ ${line}`)
          .join('\n'),
      );
      console.log('\x1b[35m──────────────────────────────────────\x1b[0m');
      console.log('');
      return { driver: 'console' };
    }
    case 'smtp':
      try {
        await sendSmtp({
          host: m.smtp.host,
          port: m.smtp.port,
          secure: m.smtp.secure,
          starttls: m.smtp.starttls,
          user: m.smtp.user,
          password: m.smtp.password,
          from: m.from,
          fromName: m.fromName,
          to,
          subject: mail.subject,
          text: mail.text,
          html: mail.html,
          timeoutMs: m.smtp.timeoutMs,
          rejectUnauthorized: m.smtp.rejectUnauthorized,
        });
      } catch (e) {
        throw new MailError(`SMTP 发送失败：${e.message}`, {
          driver: 'smtp',
          cause: e,
          code: 'smtp_failed',
        });
      }
      return { driver: 'smtp' };
    case 'resend':
      await sendViaResend(mail);
      return { driver: 'resend' };
    case 'sendgrid':
      await sendViaSendgrid(mail);
      return { driver: 'sendgrid' };
    case 'aliyun':
      await sendViaAliyun(mail);
      return { driver: 'aliyun' };
    default:
      throw new MailError(`不支持的邮件通道：${m.driver}`, { driver: m.driver });
  }
}

/** 一行日志，服务端启动时打印 */
export function describeMail() {
  const status = mailStatus();
  const from = config.mail.from || '（未设置发件地址）';
  return `${status.driver} → ${status.ready ? '就绪' : '未就绪'}（${status.reason}），发件人 ${from}`;
}

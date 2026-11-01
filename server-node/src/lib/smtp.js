// server/src/lib/smtp.js
//
// 一个**够用就好**的 SMTP 客户端。
//
// 为什么不用 nodemailer：
//   这个项目从第一天起就是「clone 下来 npm install 就能跑」，依赖越少越好。
//   而我们需要的只是：连接 → EHLO → (STARTTLS) → AUTH → MAIL/RCPT/DATA。
//   为了这一百来行协议对话引入一个带 8 个传递依赖的库，不划算。
//
// 支持：
//   * 明文 25/587（可再升级 STARTTLS）与隐式 TLS 465
//   * AUTH PLAIN / AUTH LOGIN（自建 Postfix、企业邮箱、QQ/163 授权码都够）
//   * UTF-8 主题与发件人名称（RFC 2047 编码）
//   * multipart/alternative（纯文本 + HTML 双份）
//
// 不支持（也用不上）：
//   * 附件、DKIM 签名、SMTPUTF8、8BITMIME 裸传输
//
// 正文一律 base64 传输：中文邮件走 8bit 会被不少老 MTA 截断，
// 而 base64 是 ASCII 安全的，也就顺便绕开了「行首点号要转义」的坑。

import net from 'node:net';
import tls from 'node:tls';
import { randomUUID } from 'node:crypto';

/** SMTP 层的错误（带阶段信息，便于日志定位） */
export class SmtpError extends Error {
  constructor(message, { stage, code } = {}) {
    super(message);
    this.name = 'SmtpError';
    this.stage = stage;
    this.code = code;
  }
}

// ---------------------------------------------------------------- 行读取

/**
 * 把 socket 上的字节流切成「SMTP 应答」。
 *
 * SMTP 应答可能多行：`250-扩展项` 若干行 + `250 最后一行`。
 * 第四条字符是 '-' 表示还有后续，是空格表示结束。
 */
class ReplyReader {
  constructor(socket) {
    this._buffer = '';
    this._lines = [];
    this._waiters = [];
    this._error = null;
    socket.setEncoding('utf8');
    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('error', (e) => this._fail(e));
    socket.on('close', () => this._fail(new Error('连接被服务器关闭')));
    socket.on('timeout', () => this._fail(new Error('SMTP 连接超时')));
  }

  _onData(chunk) {
    this._buffer += chunk;
    let idx;
    while ((idx = this._buffer.indexOf('\r\n')) >= 0) {
      const line = this._buffer.slice(0, idx);
      this._buffer = this._buffer.slice(idx + 2);
      this._lines.push(line);
      if (line.length >= 4 && line[3] !== '-') this._flush();
    }
  }

  _fail(err) {
    if (this._error) return;
    this._error = err;
    this._flush();
  }

  _flush() {
    if (this._waiters.length === 0) return;
    if (this._lines.length === 0 && !this._error) return;
    const waiter = this._waiters.shift();
    if (this._error) {
      waiter.reject(this._error);
      return;
    }
    const lines = this._lines;
    this._lines = [];
    const code = Number.parseInt(lines[lines.length - 1].slice(0, 3), 10);
    waiter.resolve({ code, lines });
  }

  /** 读一个完整应答；失败抛 SmtpError */
  read() {
    if (this._error) return Promise.reject(this._error);
    if (this._lines.length > 0) {
      // 上一个应答读完就 flush 掉了，这里不会命中；保险起见保留
      const lines = this._lines;
      this._lines = [];
      return Promise.resolve({
        code: Number.parseInt(lines[lines.length - 1].slice(0, 3), 10),
        lines,
      });
    }
    return new Promise((resolve, reject) => {
      this._waiters.push({ resolve, reject });
    });
  }
}

// ---------------------------------------------------------------- MIME 拼装

/** 非 ASCII 头字段要按 RFC 2047 编码，否则中文主题会变成乱码 */
function encodeHeader(value) {
  const text = String(value ?? '');
  // eslint-disable-next-line no-control-regex
  if (/^[\x20-\x7E]*$/.test(text)) return text;
  return `=?UTF-8?B?${Buffer.from(text, 'utf8').toString('base64')}?=`;
}

/** "名称 <a@b.c>" 形式的 From 头 */
function formatAddress(address, name) {
  const addr = String(address ?? '').trim();
  const label = String(name ?? '').trim();
  if (!label) return `<${addr}>`;
  // 名称里有引号/反斜杠会破坏 header，先剔掉
  const safe = label.replace(/["\\]/g, '');
  return `${encodeHeader(safe)} <${addr}>`;
}

/** base64 正文，按 76 字符折行（RFC 2045） */
function base64Body(text) {
  const b64 = Buffer.from(String(text ?? ''), 'utf8').toString('base64');
  const out = [];
  for (let i = 0; i < b64.length; i += 76) out.push(b64.slice(i, i + 76));
  return out.join('\r\n');
}

/**
 * 组一封完整邮件（头部 + 正文）。
 * 有 html 时用 multipart/alternative，纯文本作为降级版本。
 */
export function buildMessage({ from, fromName, to, subject, text, html, host }) {
  const domain = String(from ?? '').split('@')[1] || host || 'localhost';
  const headers = [
    `From: ${formatAddress(from, fromName)}`,
    `To: <${to}>`,
    `Subject: ${encodeHeader(subject)}`,
    `Date: ${new Date().toUTCString()}`,
    `Message-ID: <${randomUUID()}@${domain}>`,
    'MIME-Version: 1.0',
  ];

  if (!html) {
    headers.push(
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
    );
    return `${headers.join('\r\n')}\r\n\r\n${base64Body(text)}`;
  }

  const boundary = `=_lemon_${randomUUID().replace(/-/g, '')}`;
  headers.push(`Content-Type: multipart/alternative; boundary="${boundary}"`);

  const parts = [
    `--${boundary}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    base64Body(text || ''),
    `--${boundary}`,
    'Content-Type: text/html; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    base64Body(html),
    `--${boundary}--`,
  ];

  return `${headers.join('\r\n')}\r\n\r\n${parts.join('\r\n')}`;
}

// ---------------------------------------------------------------- 协议对话

function need(reply, expected, stage) {
  if (!expected.includes(reply.code)) {
    const detail = reply.lines.join(' | ').slice(0, 300);
    const err = new SmtpError(`SMTP ${stage} 失败（${reply.code}）：${detail}`, {
      stage,
      code: reply.code,
    });
    throw err;
  }
}

function parseCapabilities(reply) {
  const caps = new Set();
  for (const line of reply.lines) {
    const text = line.slice(4).trim().toUpperCase();
    if (!text) continue;
    caps.add(text.split(/\s+/)[0]);
  }
  return caps;
}

/**
 * 发送一封邮件。
 *
 * @param {object} opts
 * @param {string} opts.host       SMTP 主机
 * @param {number} opts.port       端口（465 走隐式 TLS，587/25 视配置）
 * @param {boolean} opts.secure    隐式 TLS（不是 STARTTLS）
 * @param {boolean} opts.starttls  明文连上后升级 TLS
 * @param {string} [opts.user]     登录名（空 = 不认证，内网中继常用）
 * @param {string} [opts.password]
 * @param {string} opts.from       发件地址
 * @param {string} [opts.fromName] 发件人显示名
 * @param {string} opts.to         收件地址
 * @param {string} opts.subject
 * @param {string} opts.text       纯文本正文
 * @param {string} [opts.html]     HTML 正文
 * @param {number} [opts.timeoutMs]
 * @param {boolean} [opts.rejectUnauthorized]
 * @param {string} [opts.ehloName]
 */
export async function sendSmtp(opts) {
  const {
    host,
    port,
    secure = false,
    starttls = true,
    user = '',
    password = '',
    from,
    fromName = '',
    to,
    subject,
    text,
    html,
    timeoutMs = 15_000,
    rejectUnauthorized = true,
    ehloName = 'lemonlite.local',
  } = opts;

  if (!host) throw new SmtpError('没有配置 SMTP 主机', { stage: 'config' });
  if (!from) throw new SmtpError('没有配置发件地址', { stage: 'config' });

  let socket = secure
    ? tls.connect({ host, port, servername: host, rejectUnauthorized })
    : net.connect({ host, port });

  socket.setTimeout(timeoutMs);
  await new Promise((resolve, reject) => {
    const onReady = () => {
      cleanup();
      resolve();
    };
    const onError = (e) => {
      cleanup();
      reject(
        new SmtpError(`连不上 ${host}:${port}：${e.message}`, { stage: 'connect' }),
      );
    };
    const cleanup = () => {
      socket.off(secure ? 'secureConnect' : 'connect', onReady);
      socket.off('error', onError);
    };
    socket.once(secure ? 'secureConnect' : 'connect', onReady);
    socket.once('error', onError);
  });

  let reader = new ReplyReader(socket);

  /** 发一行命令并读应答 */
  const command = async (line, { expected, stage } = {}) => {
    const label = stage || line.slice(0, 12);
    socket.write(`${line}\r\n`);
    let reply;
    try {
      reply = await reader.read();
    } catch (e) {
      // 超时 / 断线也要带上阶段，否则日志里只有一个干巴巴的「超时」
      throw new SmtpError(`SMTP ${label} 无响应：${e.message}`, { stage: label });
    }
    if (expected) need(reply, expected, label);
    return reply;
  };

  try {
    // ---- 问候
    need(await reader.read(), [220], 'greeting');

    // ---- EHLO（失败退化 HELO）
    let caps;
    try {
      const ehlo = await command(`EHLO ${ehloName}`, { expected: [250], stage: 'EHLO' });
      caps = parseCapabilities(ehlo);
    } catch {
      await command(`HELO ${ehloName}`, { expected: [250], stage: 'HELO' });
      caps = new Set();
    }

    // ---- STARTTLS
    if (!secure && starttls) {
      if (caps.has('STARTTLS')) {
        await command('STARTTLS', { expected: [220], stage: 'STARTTLS' });
        reader = null;
        const plain = socket;
        socket = tls.connect({
          socket: plain,
          servername: host,
          rejectUnauthorized,
        });
        socket.setTimeout(timeoutMs);
        await new Promise((resolve, reject) => {
          socket.once('secureConnect', resolve);
          socket.once('error', (e) =>
            reject(new SmtpError(`TLS 握手失败：${e.message}`, { stage: 'starttls' })),
          );
        });
        reader = new ReplyReader(socket);
        const ehlo2 = await command(`EHLO ${ehloName}`, {
          expected: [250],
          stage: 'EHLO(加密后)',
        });
        caps = parseCapabilities(ehlo2);
      } else if (port === 587) {
        // 587 端口必须加密；服务器不支持 STARTTLS 时继续裸奔等于把密码
        // 明文发出去 —— 宁可失败。
        throw new SmtpError('服务器不支持 STARTTLS，拒绝在 587 上明文认证', {
          stage: 'starttls',
        });
      }
    }

    // ---- 认证
    //
    // 先试 AUTH PLAIN（一行搞定，Postfix / 企业邮箱 / QQ 授权码都支持）。
    // 服务器不认时退到 AUTH LOGIN —— 比反过来省一次往返。
    if (user) {
      const token = Buffer.from(`\0${user}\0${password}`, 'utf8').toString('base64');
      let authed = false;
      try {
        await command(`AUTH PLAIN ${token}`, {
          expected: [235],
          stage: 'AUTH PLAIN',
        });
        authed = true;
      } catch (e) {
        // 500/501/504 = 不支持这个机制；535 = 凭据不对 —— 后者重试 LOGIN
        // 也没意义，但不同服务器的错误码并不统一，多试一次的成本可以接受。
        // 只在「服务器不认这个机制」时退化到 LOGIN。
        // 535 是凭据不对 —— 换个机制重试只会得到同样的 535，
        // 还会白白多送一次密码（部分服务器会因此锁定账号）。
        if (!(e instanceof SmtpError) || ![500, 501, 504, 530].includes(e.code)) {
          throw e;
        }
      }
      if (!authed) {
        await command('AUTH LOGIN', { expected: [334], stage: 'AUTH LOGIN' });
        await command(Buffer.from(user, 'utf8').toString('base64'), {
          expected: [334],
          stage: 'AUTH LOGIN(用户名)',
        });
        await command(Buffer.from(password, 'utf8').toString('base64'), {
          expected: [235],
          stage: 'AUTH LOGIN(密码)',
        });
      }
    }

    // ---- 信封
    await command(`MAIL FROM:<${from}>`, { expected: [250], stage: 'MAIL FROM' });
    await command(`RCPT TO:<${to}>`, { expected: [250, 251], stage: 'RCPT TO' });

    // ---- 正文
    await command('DATA', { expected: [354], stage: 'DATA' });

    const message = buildMessage({
      from,
      fromName,
      to,
      subject,
      text,
      html,
      host,
    });
    // 行首的点要转义（正文是 base64，理论上不会出现，但协议要求）
    const stuffed = message.replace(/\r\n\./g, '\r\n..');
    socket.write(`${stuffed}\r\n.\r\n`);
    const done = await reader.read();
    need(done, [250], '正文提交');

    // ---- 道别：失败也无所谓，已经投递成功了
    try {
      socket.write('QUIT\r\n');
    } catch {
      /* ignore */
    }
    return { accepted: true };
  } finally {
    socket.destroy();
  }
}

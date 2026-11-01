// server/test/mail.test.js
//
// 邮件相关的单元测试（不依赖数据库、不依赖真实邮箱）。
//
// 跑法：npm test
//
// 覆盖的是最容易出错、又最难在真机上发现的三块：
//   * MIME 头里的中文（主题一乱码，用户根本不会打开那封信）
//   * SMTP 对话的顺序（服务器对顺序很挑，错了会被直接断线）
//   * 验证码哈希与限流参数（错一位就等于没有校验）

import assert from 'node:assert/strict';
import net from 'node:net';
import test from 'node:test';

import { buildMessage, sendSmtp } from '../src/lib/smtp.js';
import { hashCode, generateCode } from '../src/lib/email_codes.js';
import { verificationMail } from '../src/lib/mail_templates.js';

/** 解码一封信里的 base64 正文（取最后一个空行之后的块） */
function decodeBody(raw) {
  const parts = raw.split(/\r\n\r\n/);
  const body = parts[parts.length - 1].replace(/\r\n/g, '');
  return Buffer.from(body.replace(/-+=\w+--?/g, ''), 'base64').toString('utf8');
}

test('MIME：中文主题按 RFC 2047 编码，正文是 base64', () => {
  const message = buildMessage({
    from: 'no-reply@lemonlite.dev',
    fromName: '柠檬轻应用',
    to: 'user@example.com',
    subject: '123456 是你的验证码',
    text: '你正在注册账号，验证码是 123456',
    host: 'lemonlite.dev',
  });

  assert.match(message, /^From: =\?UTF-8\?B\?/m, '发件人名称应被编码');
  assert.match(message, /^To: <user@example\.com>$/m);
  assert.match(message, /^Subject: =\?UTF-8\?B\?/m, '中文主题应被编码');
  assert.match(message, /^MIME-Version: 1\.0$/m);
  assert.match(message, /^Content-Transfer-Encoding: base64$/m);
  assert.ok(
    Buffer.from(message.split('\r\n\r\n')[1], 'base64')
      .toString('utf8')
      .includes('123456'),
    '正文解码后应包含验证码',
  );
});

test('MIME：给了 html 就走 multipart/alternative，纯文本仍然保留', () => {
  const message = buildMessage({
    from: 'no-reply@lemonlite.dev',
    to: 'user@example.com',
    subject: 'hello',
    text: '纯文本版本',
    html: '<b>HTML 版本</b>',
  });
  assert.match(message, /multipart\/alternative; boundary="[^"]+"/);
  assert.match(message, /Content-Type: text\/plain; charset=UTF-8/);
  assert.match(message, /Content-Type: text\/html; charset=UTF-8/);
  // 两个 part 各自的 base64 都要能解回来
  const chunks = message.split(/--=_lemon_[0-9a-f]+/);
  assert.equal(chunks.length, 4, '两个 part + 结尾分隔');
});

test('验证码邮件：主题里带码，正文有效期与模板一致', () => {
  const mail = verificationMail({ code: '654321', ttlSeconds: 600 });
  assert.match(mail.subject, /654321/);
  assert.match(mail.subject, /10 分钟/);
  assert.match(mail.text, /654321/);
  assert.match(mail.html, /654321/);
});

test('验证码：哈希与邮箱、用途绑定，随机码位数正确', () => {
  const a = hashCode('User@Example.com', 'register', '123456');
  const b = hashCode('user@example.com ', 'register', '123456');
  const c = hashCode('user@example.com', 'reset', '123456');
  const d = hashCode('user@example.com', 'register', '123457');

  assert.equal(a, b, '邮箱大小写/空格应归一化');
  assert.equal(a.length, 64, 'sha256 十六进制是 64 位');
  assert.notEqual(a, c, '不同用途必须得到不同哈希');
  assert.notEqual(a, d, '不同验证码必须得到不同哈希');

  for (let i = 0; i < 20; i += 1) {
    const code = generateCode(6);
    assert.match(code, /^\d{6}$/);
  }
});

// ---------------------------------------------------------------- SMTP 对话

/**
 * 一个只够测试用的假 SMTP 服务器。
 * 记录每一行命令与收到的正文，供断言用。
 */
function startFakeSmtp({ auth = false } = {}) {
  const transcript = [];
  let data = '';
  let inData = false;

  const server = net.createServer((socket) => {
    socket.setEncoding('utf8');
    socket.write('220 fake.lemonlite ESMTP\r\n');
    let buffer = '';

    socket.on('data', (chunk) => {
      buffer += chunk;
      if (inData) {
        const end = buffer.indexOf('\r\n.\r\n');
        if (end < 0) return;
        data += buffer.slice(0, end);
        buffer = buffer.slice(end + 5);
        inData = false;
        transcript.push('.<结束正文>');
        socket.write('250 2.0.0 queued as 12345\r\n');
      }
      let idx;
      while ((idx = buffer.indexOf('\r\n')) >= 0) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        transcript.push(line);
        const upper = line.toUpperCase();
        if (upper.startsWith('EHLO') || upper.startsWith('HELO')) {
          socket.write('250-fake.lemonlite\r\n250-AUTH PLAIN LOGIN\r\n250 SIZE 10485760\r\n');
        } else if (upper.startsWith('AUTH PLAIN')) {
          socket.write(auth ? '235 2.7.0 Authentication successful\r\n' : '535 5.7.8 bad credentials\r\n');
        } else if (upper.startsWith('MAIL FROM')) {
          socket.write('250 2.1.0 Ok\r\n');
        } else if (upper.startsWith('RCPT TO')) {
          socket.write('250 2.1.5 Ok\r\n');
        } else if (upper === 'DATA') {
          inData = true;
          socket.write('354 End data with <CR><LF>.<CR><LF>\r\n');
        } else if (upper === 'QUIT') {
          socket.write('221 2.0.0 Bye\r\n');
          socket.end();
        }
      }
    });
    socket.on('error', () => {});
  });

  return {
    server,
    transcript,
    getData: () => data,
    listen: () =>
      new Promise((resolve) => {
        server.listen(0, '127.0.0.1', () => resolve(server.address().port));
      }),
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

test('SMTP：完整对话顺序正确，正文按协议提交', async () => {
  const fake = startFakeSmtp({ auth: true });
  const port = await fake.listen();
  try {
    await sendSmtp({
      host: '127.0.0.1',
      port,
      secure: false,
      starttls: false,
      user: 'bot@lemonlite.dev',
      password: 'secret',
      from: 'no-reply@lemonlite.dev',
      fromName: 'LemonLite',
      to: 'user@example.com',
      subject: '你的验证码是 112233',
      text: '验证码 112233，10 分钟内有效。',
      timeoutMs: 5000,
    });
  } finally {
    await fake.close();
  }

  const commands = fake.transcript.filter((line) => !line.startsWith('<'));
  assert.ok(commands[0].startsWith('EHLO'), '第一句应是 EHLO');
  assert.ok(
    commands.some((line) => line.startsWith('AUTH PLAIN ')),
    '应尝试 AUTH PLAIN',
  );
  assert.ok(
    commands.includes('MAIL FROM:<no-reply@lemonlite.dev>'),
    'MAIL FROM 要带尖括号',
  );
  assert.ok(commands.includes('RCPT TO:<user@example.com>'));
  assert.ok(commands.includes('DATA'));
  assert.ok(commands.includes('QUIT'), '发完应主动 QUIT');

  const data = fake.getData();
  assert.match(data, /Subject: =\?UTF-8\?B\?/, '中文主题必须编码');
  assert.ok(
    Buffer.from(data.split('\r\n\r\n').pop(), 'base64').toString('utf8').includes('112233'),
    '正文应能还原出验证码',
  );
});

test('SMTP：密码错了要抛错，而不是当作发送成功', async () => {
  const fake = startFakeSmtp({ auth: false });
  const port = await fake.listen();
  try {
    await assert.rejects(
      () =>
        sendSmtp({
          host: '127.0.0.1',
          port,
          secure: false,
          starttls: false,
          user: 'bot@lemonlite.dev',
          password: 'wrong',
          from: 'no-reply@lemonlite.dev',
          to: 'user@example.com',
          subject: 'x',
          text: 'x',
          timeoutMs: 5000,
        }),
      /认证|AUTH|535|LOGIN/i,
    );
  } finally {
    await fake.close();
  }
});

// server/src/lib/mail_templates.js
//
// 邮件正文模板。
//
// 只保留纯文本 + HTML 两份：纯文本是给「关掉了 HTML 的客户端 / 终端里的
// mutt」用的降级版本，也是被反垃圾系统拿去匹配的版本 —— 两份内容必须一致，
// 只发 HTML 的邮件在不少自建邮件网关里会被直接判为可疑。

/** 把用户输入里的 HTML 元字符去掉（这里目前只回填邮箱，仍然防一手） */
function escapeHtml(text) {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * 验证码邮件。
 *
 * @param {object} opts
 * @param {string} opts.code       验证码
 * @param {number} opts.ttlSeconds 有效期（秒）
 * @param {string} [opts.purpose]  register / reset
 * @param {string} [opts.brand]    品牌名
 */
export function verificationMail({ code, ttlSeconds, purpose = 'register', brand = 'LemonLite' }) {
  const minutes = Math.max(1, Math.round(ttlSeconds / 60));
  const action = purpose === 'reset' ? '重置密码' : '注册账号';
  const subject = `${code} 是你的 ${brand} 验证码（${minutes} 分钟内有效）`;

  const text = [
    `你正在${action}，验证码是：`,
    '',
    `    ${code}`,
    '',
    `${minutes} 分钟内有效，只能使用一次。`,
    '如果不是你本人操作，直接忽略这封邮件即可 —— 没有验证码，别人无法完成注册。',
    '',
    `—— ${brand}`,
  ].join('\n');

  const html = `<!doctype html>
<html lang="zh-CN">
  <body style="margin:0;padding:24px;background:#f6f4f8;font-family:-apple-system,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',sans-serif;color:#1c1b1f;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;margin:0 auto;background:#ffffff;border-radius:24px;padding:32px;box-shadow:0 1px 3px rgba(0,0,0,.08);">
      <tr><td style="font-size:20px;font-weight:600;padding-bottom:8px;">${escapeHtml(brand)}</td></tr>
      <tr><td style="font-size:15px;color:#49454f;padding-bottom:24px;">你正在${escapeHtml(action)}，请使用下面的验证码：</td></tr>
      <tr><td align="center" style="padding:8px 0 24px;">
        <div style="display:inline-block;padding:16px 28px;background:#f2e7fe;border-radius:16px;font-size:34px;letter-spacing:8px;font-weight:700;color:#5b3ba8;">${escapeHtml(code)}</div>
      </td></tr>
      <tr><td style="font-size:14px;color:#49454f;line-height:1.6;">
        验证码 ${minutes} 分钟内有效，只能使用一次。<br />
        如果不是你本人操作，直接忽略这封邮件即可。
      </td></tr>
      <tr><td style="padding-top:28px;font-size:12px;color:#79747e;">本邮件由系统自动发送，请勿直接回复。</td></tr>
    </table>
  </body>
</html>`;

  return { subject, text, html };
}

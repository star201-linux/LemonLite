// server/src/admin/ui.js
//
// 管理面板的页面（整块 HTML + CSS + 原生 JS）。
//
// 为什么不引前端框架、不挂 CDN：
//   * 这个面板要在**没有外网**的内网服务器上用 —— 任何外链都是单点故障；
//   * 它一共就两屏（概览 / 邮件），引入构建工具只会让「改一行文案」也要重新编译。
// 所以这里是纯静态字符串，浏览器直接吃。

/**
 * @param {{version: string, enabled: boolean}} opts
 * @returns {string} 完整 HTML
 */
export function renderAdminPage({ version, enabled }) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>轻柠 · 管理面板</title>
<style>
  :root {
    --bg: #f7f3fb;
    --surface: #ffffff;
    --surface-2: #f2ecf9;
    --primary: #6b4ea8;
    --primary-2: #7f5fd0;
    --on-primary: #ffffff;
    --text: #1c1b1f;
    --muted: #6b6478;
    --border: #e3dcec;
    --ok: #1f7a4d;
    --warn: #9a6400;
    --err: #b3261e;
    --radius: 18px;
    --shadow: 0 1px 2px rgba(28, 27, 31, .06), 0 8px 24px rgba(28, 27, 31, .06);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #141218; --surface: #1d1b21; --surface-2: #262230;
      --primary: #cfbcff; --primary-2: #b9a2f5; --on-primary: #2a1b52;
      --text: #e8e3ee; --muted: #a9a1b8; --border: #35303f;
      --ok: #7fd6a6; --warn: #f0c06a; --err: #ffb4ab;
      --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px rgba(0,0,0,.35);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
      "PingFang SC", "Microsoft YaHei", sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  header {
    display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
    padding: 18px 20px; max-width: 880px; margin: 0 auto;
  }
  header h1 { font-size: 18px; margin: 0; font-weight: 650; letter-spacing: .2px; }
  .tag {
    font-size: 12px; padding: 3px 9px; border-radius: 999px;
    background: var(--surface-2); color: var(--muted);
  }
  main { max-width: 880px; margin: 0 auto; padding: 0 16px 48px; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); box-shadow: var(--shadow);
    padding: 18px; margin-bottom: 16px;
  }
  .tabs { display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; }
  .tab {
    border: 1px solid var(--border); background: var(--surface);
    color: var(--text); padding: 9px 16px; border-radius: 999px;
    font-size: 14px; cursor: pointer; transition: .18s ease;
  }
  .tab[aria-selected="true"] {
    background: var(--primary); border-color: var(--primary);
    color: var(--on-primary);
  }
  h2 { font-size: 15px; margin: 0 0 12px; font-weight: 650; }
  h3 { font-size: 13px; margin: 18px 0 8px; color: var(--primary); font-weight: 650; }
  p.hint { color: var(--muted); font-size: 13px; line-height: 1.6; margin: 6px 0; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
  .stat {
    background: var(--surface-2); border-radius: 14px; padding: 14px;
  }
  .stat b { display: block; font-size: 22px; font-weight: 700; }
  .stat span { font-size: 12px; color: var(--muted); }
  .row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 560px) { .row { grid-template-columns: 1fr; } }
  label { display: block; font-size: 13px; margin-bottom: 6px; color: var(--muted); }
  input[type=text], input[type=password], input[type=number], select {
    width: 100%; padding: 11px 12px; border-radius: 12px;
    border: 1px solid var(--border); background: var(--surface);
    color: var(--text); font-size: 14px; outline: none;
  }
  input:focus, select:focus { border-color: var(--primary); }
  .field { margin-bottom: 14px; }
  .check { display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--text); margin-bottom: 12px; }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 18px; }
  button.primary, button.ghost {
    border-radius: 999px; padding: 11px 20px; font-size: 14px; cursor: pointer;
    border: 1px solid transparent; transition: .18s ease;
  }
  button.primary { background: var(--primary); color: var(--on-primary); }
  button.primary:disabled { opacity: .5; cursor: default; }
  button.ghost { background: transparent; border-color: var(--border); color: var(--text); }
  button.ghost:hover { background: var(--surface-2); }
  .badge { font-size: 12px; padding: 3px 9px; border-radius: 999px; }
  .badge.ok { background: rgba(31,122,77,.14); color: var(--ok); }
  .badge.warn { background: rgba(154,100,0,.14); color: var(--warn); }
  .badge.err { background: rgba(179,38,30,.14); color: var(--err); }
  .toast {
    position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%) translateY(8px);
    background: var(--text); color: var(--bg); padding: 11px 18px; border-radius: 999px;
    font-size: 13px; opacity: 0; pointer-events: none; transition: .2s ease; max-width: 90vw;
  }
  .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
  .toast.err { background: var(--err); color: #fff; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid var(--border); }
  th { color: var(--muted); font-weight: 500; }
  code { background: var(--surface-2); padding: 1px 6px; border-radius: 6px; font-size: 12px; }
  .kv { display: flex; justify-content: space-between; gap: 12px; padding: 7px 0; border-bottom: 1px dashed var(--border); font-size: 14px; }
  .kv:last-child { border-bottom: 0; }
  .kv span:first-child { color: var(--muted); }
</style>
</head>
<body>
<header>
  <h1>轻柠 · 管理面板</h1>
  <span class="tag">v${version}</span>
  <span id="conn" class="tag">连接中…</span>
</header>
<main>
  <!-- 登录 -->
  <section id="login" class="card" hidden>
    <h2>需要口令</h2>
    <p class="hint">口令就是服务端 <code>.env</code> 里的 <code>ADMIN_PASSWORD</code>。</p>
    <form id="loginForm">
      <div class="field">
        <label for="password">管理口令</label>
        <input id="password" type="password" autocomplete="current-password" placeholder="输入 ADMIN_PASSWORD" />
      </div>
      <div class="actions"><button class="primary" type="submit">登录</button></div>
    </form>
  </section>

  <section id="disabled" class="card" hidden>
    <h2>面板未启用</h2>
    <p class="hint">
      在服务端 <code>.env</code> 里加一行 <code>ADMIN_PASSWORD=你的口令</code>，重启服务后即可使用。
      没有口令时面板是关闭的 —— 一个谁都能打开的后台比没有后台更危险。
    </p>
  </section>

  <!-- 主体 -->
  <section id="panel" hidden>
    <div class="tabs">
      <button class="tab" data-tab="overview" aria-selected="true">概览</button>
      <button class="tab" data-tab="mail" aria-selected="false">邮件通道</button>
      <button class="tab" data-tab="users" aria-selected="false">用户</button>
    </div>

    <!-- 概览 -->
    <div id="tab-overview">
      <div class="card">
        <h2>运行概况</h2>
        <div class="grid" id="stats"></div>
      </div>
      <div class="card">
        <h2>当前策略</h2>
        <div id="policy"></div>
        <p class="hint">策略项在「邮件通道」页底部改，改完立即生效并写入 <code>.env</code>。</p>
      </div>
    </div>

    <!-- 邮件 -->
    <div id="tab-mail" hidden>
      <form class="card" id="mailForm">
        <h2>邮件通道 <span id="mailState" class="badge"></span></h2>
        <p class="hint" id="mailReason"></p>

        <div class="field">
          <label for="mail_driver">通道</label>
          <select id="mail_driver" name="driver">
            <option value="console">console —— 不发信，只打日志（仅开发）</option>
            <option value="smtp">smtp —— 自建 / 企业邮箱 / QQ 授权码</option>
            <option value="resend">resend —— Resend API</option>
            <option value="sendgrid">sendgrid —— Twilio SendGrid</option>
            <option value="aliyun">aliyun —— 阿里云邮件推送</option>
          </select>
        </div>
        <div class="row">
          <div class="field"><label for="mail_from">发件地址 MAIL_FROM</label><input id="mail_from" type="text" placeholder="no-reply@example.com" /></div>
          <div class="field"><label for="mail_from_name">发件人名称</label><input id="mail_from_name" type="text" placeholder="LemonLite" /></div>
        </div>

        <div data-driver-block="smtp">
          <h3>SMTP</h3>
          <div class="row">
            <div class="field"><label for="smtp_host">主机</label><input id="smtp_host" type="text" placeholder="smtp.qq.com" /></div>
            <div class="field"><label for="smtp_port">端口</label><input id="smtp_port" type="number" placeholder="465" /></div>
          </div>
          <div class="row">
            <div class="field"><label for="smtp_user">用户名</label><input id="smtp_user" type="text" placeholder="no-reply@example.com" /></div>
            <div class="field"><label for="smtp_password">密码 / 授权码</label><input id="smtp_password" type="password" placeholder="留空 = 不修改已保存的值" /></div>
          </div>
          <div class="check"><input id="smtp_secure" type="checkbox" /><label for="smtp_secure" style="margin:0">隐式 TLS（465 端口勾上；587 不勾）</label></div>
          <div class="check"><input id="smtp_starttls" type="checkbox" /><label for="smtp_starttls" style="margin:0">STARTTLS（587/25 建议勾上）</label></div>
          <div class="check"><input id="smtp_reject" type="checkbox" /><label for="smtp_reject" style="margin:0">校验服务器证书（公网服务必须勾）</label></div>
        </div>

        <div data-driver-block="resend">
          <h3>Resend</h3>
          <div class="field"><label for="resend_key">API Key</label><input id="resend_key" type="password" placeholder="re_...（留空 = 不修改）" /></div>
        </div>

        <div data-driver-block="sendgrid">
          <h3>SendGrid</h3>
          <div class="field"><label for="sendgrid_key">API Key</label><input id="sendgrid_key" type="password" placeholder="SG....（留空 = 不修改）" /></div>
        </div>

        <div data-driver-block="aliyun">
          <h3>阿里云邮件推送</h3>
          <div class="row">
            <div class="field"><label for="aliyun_id">AccessKey ID</label><input id="aliyun_id" type="text" /></div>
            <div class="field"><label for="aliyun_secret">AccessKey Secret</label><input id="aliyun_secret" type="password" placeholder="留空 = 不修改" /></div>
          </div>
          <div class="row">
            <div class="field"><label for="aliyun_account">发信地址</label><input id="aliyun_account" type="text" placeholder="no-reply@mail.example.com" /></div>
            <div class="field"><label for="aliyun_region">区域</label><input id="aliyun_region" type="text" placeholder="cn-hangzhou" /></div>
          </div>
        </div>

        <h3>测试发信</h3>
        <div class="row">
          <div class="field"><label for="test_to">收件地址</label><input id="test_to" type="text" placeholder="me@example.com" /></div>
          <div class="field" style="display:flex;align-items:flex-end">
            <button class="ghost" type="button" id="testBtn">发送测试邮件</button>
          </div>
        </div>

        <h3>验证码与账号策略</h3>
        <div class="row">
          <div class="field"><label for="code_ttl">验证码有效期（秒）</label><input id="code_ttl" type="number" /></div>
          <div class="field"><label for="code_cooldown">重发冷却（秒）</label><input id="code_cooldown" type="number" /></div>
        </div>
        <div class="row">
          <div class="field"><label for="code_email_hour">单邮箱每小时上限</label><input id="code_email_hour" type="number" /></div>
          <div class="field"><label for="code_ip_hour">单 IP 每小时上限</label><input id="code_ip_hour" type="number" /></div>
        </div>
        <div class="row">
          <div class="field"><label for="token_ttl">token 有效期</label>
            <select id="token_ttl">
              <option value="never">never —— 永不过期（默认）</option>
              <option value="30d">30 天</option>
              <option value="7d">7 天</option>
              <option value="12h">12 小时</option>
            </select>
          </div>
          <div class="field"><label for="code_attempts">验证码最多错几次</label><input id="code_attempts" type="number" /></div>
        </div>
        <div class="check"><input id="register_code" type="checkbox" /><label for="register_code" style="margin:0">注册需要邮箱验证码</label></div>
        <div class="check"><input id="login_code" type="checkbox" /><label for="login_code" style="margin:0">登录需要邮箱验证码（两步验证）</label></div>
        <div class="check"><input id="dev_echo" type="checkbox" /><label for="dev_echo" style="margin:0">开发模式：把验证码直接返回给客户端（生产必须关）</label></div>

        <div class="actions">
          <button class="primary" type="submit">保存并立即生效</button>
          <button class="ghost" type="button" id="reloadBtn">重新读取</button>
        </div>
        <p class="hint">保存会写入服务端 <code>.env</code> 并立即应用到内存，不需要重启。</p>
      </form>
    </div>

    <!-- 用户 -->
    <div id="tab-users" hidden>
      <div class="card">
        <h2>最近注册的用户</h2>
        <div style="overflow:auto"><table id="usersTable"><thead><tr><th>ID</th><th>用户名</th><th>邮箱</th><th>注册 IP</th><th>时间</th></tr></thead><tbody></tbody></table></div>
      </div>
    </div>
  </section>
</main>
<div class="toast" id="toast"></div>
<script>
(function () {
  const ENABLED = ${enabled ? 'true' : 'false'};
  const $ = (id) => document.getElementById(id);
  const toastEl = $('toast');
  let toastTimer = null;

  function toast(message, isError) {
    toastEl.textContent = message;
    toastEl.className = 'toast show' + (isError ? ' err' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toastEl.className = 'toast'; }, 3200);
  }

  async function api(path, options) {
    const res = await fetch('/admin/api' + path, Object.assign({
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
    }, options || {}));
    if (res.status === 401) { showLogin(); throw new Error('unauthorized'); }
    const body = await res.json().catch(() => null);
    if (!res.ok) {
      throw new Error((body && body.error && body.error.message) || ('请求失败 ' + res.status));
    }
    return body.data;
  }

  function showLogin() {
    $('login').hidden = false;
    $('panel').hidden = true;
    $('disabled').hidden = ENABLED ? true : false;
    if (!ENABLED) $('login').hidden = true;
  }

  function showPanel() {
    $('login').hidden = true;
    $('panel').hidden = false;
    $('disabled').hidden = true;
  }

  // ---------------- 登录
  $('loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
      await api('/login', { method: 'POST', body: JSON.stringify({ password: $('password').value }) });
      $('password').value = '';
      showPanel();
      await refreshAll();
    } catch (err) {
      toast(err.message, true);
    }
  });

  // ---------------- Tab
  document.querySelectorAll('.tab').forEach((btn) => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.tab').forEach((b) => b.setAttribute('aria-selected', String(b === btn)));
      ['overview', 'mail', 'users'].forEach((name) => {
        $('tab-' + name).hidden = name !== btn.dataset.tab;
      });
      if (btn.dataset.tab === 'users') loadUsers();
    });
  });

  // ---------------- 概览
  async function loadStatus() {
    const data = await api('/status');
    $('conn').textContent = '已连接 · 运行 ' + data.uptime;
    const stats = [
      ['用户', data.counts.users],
      ['应用', data.counts.apps],
      ['活跃会话', data.counts.sessions],
      ['24h 验证码', data.counts.codes24h],
    ];
    $('stats').innerHTML = stats.map(([k, v]) =>
      '<div class="stat"><b>' + v + '</b><span>' + k + '</span></div>').join('');

    const mail = data.mail;
    $('policy').innerHTML = [
      ['邮件通道', mail.driver + (mail.ready ? ' · 就绪' : ' · 未就绪')],
      ['注册验证码', data.auth.registerCode ? '需要' : '不需要'],
      ['登录验证码', data.auth.loginCode ? '需要' : '不需要'],
      ['token', data.auth.tokenTtl === 'never' ? '永不过期' : data.auth.tokenTtl],
      ['数据库', data.db.ok ? '正常' : '异常'],
    ].map(([k, v]) => '<div class="kv"><span>' + k + '</span><span>' + v + '</span></div>').join('');
  }

  // ---------------- 邮件表单
  const DRIVER_BLOCKS = ['smtp', 'resend', 'sendgrid', 'aliyun'];
  function syncDriverBlocks() {
    const driver = $('mail_driver').value;
    document.querySelectorAll('[data-driver-block]').forEach((el) => {
      el.hidden = el.dataset.driverBlock !== driver;
    });
  }
  $('mail_driver').addEventListener('change', syncDriverBlocks);

  async function loadMail() {
    const mail = await api('/mail');
    $('mail_driver').value = mail.driver;
    $('mail_from').value = mail.from || '';
    $('mail_from_name').value = mail.fromName || '';
    $('smtp_host').value = mail.smtp.host || '';
    $('smtp_port').value = mail.smtp.port || 587;
    $('smtp_user').value = mail.smtp.user || '';
    $('smtp_password').value = '';
    $('smtp_password').placeholder = mail.smtp.passwordSet ? '已保存，留空表示不修改' : '未设置';
    $('smtp_secure').checked = !!mail.smtp.secure;
    $('smtp_starttls').checked = !!mail.smtp.starttls;
    $('smtp_reject').checked = !!mail.smtp.rejectUnauthorized;
    $('resend_key').value = '';
    $('resend_key').placeholder = mail.resend.apiKeySet ? '已保存，留空表示不修改' : '未设置';
    $('sendgrid_key').value = '';
    $('sendgrid_key').placeholder = mail.sendgrid.apiKeySet ? '已保存，留空表示不修改' : '未设置';
    $('aliyun_id').value = mail.aliyun.accessKeyId || '';
    $('aliyun_secret').value = '';
    $('aliyun_secret').placeholder = mail.aliyun.accessKeySecretSet ? '已保存，留空表示不修改' : '未设置';
    $('aliyun_account').value = mail.aliyun.accountName || '';
    $('aliyun_region').value = mail.aliyun.region || 'cn-hangzhou';
    $('code_ttl').value = mail.codeTtl;
    $('code_cooldown').value = mail.codeCooldown;
    $('code_email_hour').value = mail.codeMaxPerEmailHour;
    $('code_ip_hour').value = mail.codeMaxPerIpHour;
    $('code_attempts').value = mail.codeMaxAttempts;
    $('dev_echo').checked = !!mail.devEchoCode;
    $('token_ttl').value = mail.tokenTtl;
    $('register_code').checked = !!mail.registerCode;
    $('login_code').checked = !!mail.loginCode;
    const badge = $('mailState');
    badge.textContent = mail.ready ? '就绪' : '未就绪';
    badge.className = 'badge ' + (mail.ready ? 'ok' : 'warn');
    $('mailReason').textContent = mail.ready ? ('当前通道：' + mail.driver) : ('原因：' + mail.reason);
    syncDriverBlocks();
  }

  $('mailForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const payload = {
      driver: $('mail_driver').value,
      from: $('mail_from').value.trim(),
      fromName: $('mail_from_name').value.trim(),
      smtp: {
        host: $('smtp_host').value.trim(),
        port: Number($('smtp_port').value) || 587,
        user: $('smtp_user').value.trim(),
        password: $('smtp_password').value,
        secure: $('smtp_secure').checked,
        starttls: $('smtp_starttls').checked,
        rejectUnauthorized: $('smtp_reject').checked,
      },
      resend: { apiKey: $('resend_key').value },
      sendgrid: { apiKey: $('sendgrid_key').value },
      aliyun: {
        accessKeyId: $('aliyun_id').value.trim(),
        accessKeySecret: $('aliyun_secret').value,
        accountName: $('aliyun_account').value.trim(),
        region: $('aliyun_region').value.trim() || 'cn-hangzhou',
      },
      codeTtl: Number($('code_ttl').value) || 600,
      codeCooldown: Number($('code_cooldown').value) || 60,
      codeMaxPerEmailHour: Number($('code_email_hour').value) || 10,
      codeMaxPerIpHour: Number($('code_ip_hour').value) || 30,
      codeMaxAttempts: Number($('code_attempts').value) || 5,
      devEchoCode: $('dev_echo').checked,
      tokenTtl: $('token_ttl').value,
      registerCode: $('register_code').checked,
      loginCode: $('login_code').checked,
    };
    try {
      const result = await api('/mail', { method: 'PUT', body: JSON.stringify(payload) });
      toast(result.mail.ready ? '已保存，通道就绪' : '已保存，但通道还未就绪');
      await loadMail();
      await loadStatus();
    } catch (err) {
      toast(err.message, true);
    }
  });

  $('reloadBtn').addEventListener('click', () => loadMail().catch((e) => toast(e.message, true)));

  $('testBtn').addEventListener('click', async () => {
    const to = $('test_to').value.trim();
    if (!to) { toast('先填收件地址', true); return; }
    $('testBtn').disabled = true;
    try {
      const result = await api('/mail/test', { method: 'POST', body: JSON.stringify({ to }) });
      toast('测试邮件已交给 ' + result.driver + '（' + result.ms + 'ms）');
    } catch (err) {
      toast(err.message, true);
    } finally {
      $('testBtn').disabled = false;
    }
  });

  // ---------------- 用户
  async function loadUsers() {
    try {
      const data = await api('/users');
      const tbody = $('usersTable').querySelector('tbody');
      if (!data.users.length) {
        tbody.innerHTML = '<tr><td colspan="5" class="hint">还没有用户</td></tr>';
        return;
      }
      tbody.innerHTML = data.users.map((u) =>
        '<tr><td>' + u.id + '</td><td>' + escapeHtml(u.username) + '</td><td>' +
        escapeHtml(u.email) + '</td><td>' + escapeHtml(u.createdIp || '') + '</td><td>' +
        escapeHtml(u.createdAt || '') + '</td></tr>').join('');
    } catch (err) {
      toast(err.message, true);
    }
  }

  function escapeHtml(text) {
    return String(text == null ? '' : text).replace(/[&<>"']/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  async function refreshAll() {
    await loadStatus();
    await loadMail();
  }

  // ---------------- 启动
  if (!ENABLED) {
    showLogin();
  } else {
    api('/status').then(() => { showPanel(); return refreshAll(); }).catch(() => showLogin());
  }
})();
</script>
</body>
</html>`;
}

// server/src/admin/ui.js
//
// 管理面板的页面（整块 HTML + CSS + 原生 JS）。
//
// 为什么不引前端框架、不挂 CDN：
//   * 这个面板要在**没有外网**的内网服务器上用 —— 任何外链都是单点故障；
//   * 它一共就四屏（概览 / 应用 / 用户 / 邮件），引入构建工具只会让
//     「改一行文案」也要重新编译。
// 所以这里是纯静态字符串，浏览器直接吃。
//
// 注意：内层 <script> 里**不用模板字符串**（反引号 + ${}），
// 因为它们会被外层这个 JS 模板字符串先求值。内层一律用拼接。

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
    --bg: #f7f3fb; --surface: #fff; --surface-2: #f2ecf9;
    --primary: #6b4ea8; --on-primary: #fff;
    --text: #1c1b1f; --muted: #6b6478; --border: #e3dcec;
    --ok: #1f7a4d; --warn: #9a6400; --err: #b3261e;
    --radius: 18px;
    --shadow: 0 1px 2px rgba(28,27,31,.06), 0 8px 24px rgba(28,27,31,.06);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #141218; --surface: #1d1b21; --surface-2: #262230;
      --primary: #cfbcff; --on-primary: #2a1b52;
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
  header { display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
    padding: 18px 20px; max-width: 960px; margin: 0 auto; }
  header h1 { font-size: 18px; margin: 0; font-weight: 650; }
  .tag { font-size: 12px; padding: 3px 9px; border-radius: 999px;
    background: var(--surface-2); color: var(--muted); }
  main { max-width: 960px; margin: 0 auto; padding: 0 16px 64px; }
  .card { background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); box-shadow: var(--shadow); padding: 18px; margin-bottom: 16px; }
  .tabs { display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; }
  .tab { border: 1px solid var(--border); background: var(--surface); color: var(--text);
    padding: 9px 16px; border-radius: 999px; font-size: 14px; cursor: pointer; transition: .18s ease; }
  .tab[aria-selected="true"] { background: var(--primary); border-color: var(--primary); color: var(--on-primary); }
  h2 { font-size: 15px; margin: 0 0 12px; font-weight: 650; }
  h3 { font-size: 13px; margin: 18px 0 8px; color: var(--primary); font-weight: 650; }
  p.hint { color: var(--muted); font-size: 13px; line-height: 1.6; margin: 6px 0; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
  .stat { background: var(--surface-2); border-radius: 14px; padding: 14px; }
  .stat b { display: block; font-size: 22px; font-weight: 700; }
  .stat span { font-size: 12px; color: var(--muted); }
  .row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  @media (max-width: 560px) { .row { grid-template-columns: 1fr; } }
  label { display: block; font-size: 13px; margin-bottom: 6px; color: var(--muted); }
  input[type=text], input[type=password], input[type=number], input[type=file], select, textarea {
    width: 100%; padding: 11px 12px; border-radius: 12px; border: 1px solid var(--border);
    background: var(--surface); color: var(--text); font-size: 14px; outline: none; font-family: inherit; }
  input:focus, select:focus, textarea:focus { border-color: var(--primary); }
  textarea { min-height: 76px; resize: vertical; }
  .field { margin-bottom: 14px; }
  .check { display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--text); margin-bottom: 12px; }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 18px; }
  button.primary, button.ghost { border-radius: 999px; padding: 10px 18px; font-size: 14px;
    cursor: pointer; border: 1px solid transparent; transition: .18s ease; }
  button.primary { background: var(--primary); color: var(--on-primary); }
  button.primary:disabled, button.ghost:disabled { opacity: .5; cursor: default; }
  button.ghost { background: transparent; border-color: var(--border); color: var(--text); }
  button.ghost:hover { background: var(--surface-2); }
  button.ghost.danger { color: var(--err); border-color: var(--err); }
  button.small { padding: 6px 12px; font-size: 13px; }
  .badge { font-size: 12px; padding: 3px 9px; border-radius: 999px; }
  .badge.ok { background: rgba(31,122,77,.14); color: var(--ok); }
  .badge.warn { background: rgba(154,100,0,.14); color: var(--warn); }
  .badge.err { background: rgba(179,38,30,.14); color: var(--err); }
  .toast { position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%) translateY(8px);
    background: var(--text); color: var(--bg); padding: 11px 18px; border-radius: 999px;
    font-size: 13px; opacity: 0; pointer-events: none; transition: .2s ease; max-width: 90vw; z-index: 50; }
  .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
  .toast.err { background: var(--err); color: #fff; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 9px 6px; border-bottom: 1px solid var(--border); vertical-align: middle; }
  th { color: var(--muted); font-weight: 500; }
  code { background: var(--surface-2); padding: 1px 6px; border-radius: 6px; font-size: 12px; }
  .kv { display: flex; justify-content: space-between; gap: 12px; padding: 7px 0;
    border-bottom: 1px dashed var(--border); font-size: 14px; }
  .kv:last-child { border-bottom: 0; }
  .kv span:first-child { color: var(--muted); }
  .toolbar { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin-bottom: 14px; }
  .toolbar input[type=text] { flex: 1 1 220px; width: auto; }
  .item { display: flex; gap: 12px; align-items: center; justify-content: space-between;
    padding: 12px 0; border-bottom: 1px solid var(--border); flex-wrap: wrap; }
  .item:last-child { border-bottom: 0; }
  .item-title { font-size: 14px; font-weight: 600; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .item-sub { font-size: 12px; color: var(--muted); margin-top: 4px; }
  .item-actions { display: flex; gap: 8px; flex-wrap: wrap; }
  .modal { position: fixed; inset: 0; background: rgba(0,0,0,.42); display: flex;
    align-items: flex-start; justify-content: center; padding: 24px 16px; overflow: auto; z-index: 40; }
  .modal[hidden] { display: none; }
  .modal-card { background: var(--surface); border-radius: 20px; padding: 20px; width: 100%;
    max-width: 640px; box-shadow: var(--shadow); }
  .modal-actions { display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px; flex-wrap: wrap; }
  .chip-list { display: flex; flex-wrap: wrap; gap: 8px; }
  .chip { display: inline-flex; align-items: center; gap: 6px; font-size: 13px;
    border: 1px solid var(--border); border-radius: 999px; padding: 6px 12px; }
</style>
</head>
<body>
<header>
  <h1>轻柠 · 管理面板</h1>
  <span class="tag">v${version}</span>
  <span id="conn" class="tag">连接中…</span>
</header>
<main>
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

  <section id="panel" hidden>
    <div class="tabs">
      <button class="tab" data-tab="overview" aria-selected="true">概览</button>
      <button class="tab" data-tab="apps" aria-selected="false">应用</button>
      <button class="tab" data-tab="users" aria-selected="false">用户</button>
      <button class="tab" data-tab="mail" aria-selected="false">邮件</button>
    </div>

    <div id="tab-overview">
      <div class="card">
        <h2>运行概况</h2>
        <div class="grid" id="stats"></div>
      </div>
      <div class="card">
        <h2>当前策略</h2>
        <div id="policy"></div>
        <p class="hint">策略项在「邮件」页底部改，改完立即生效。</p>
      </div>
    </div>

    <div id="tab-apps" hidden>
      <div class="card">
        <div class="toolbar">
          <input id="appSearch" type="text" placeholder="按名称或 id 搜索" />
          <button class="ghost" type="button" id="appSearchBtn">搜索</button>
          <button class="primary" type="button" id="appNewBtn">新建应用</button>
        </div>
        <div id="appList"><p class="hint">加载中…</p></div>
      </div>
    </div>

    <div id="tab-users" hidden>
      <div class="card">
        <div class="toolbar">
          <input id="userSearch" type="text" placeholder="按用户名或邮箱搜索" />
          <button class="ghost" type="button" id="userSearchBtn">搜索</button>
        </div>
        <div style="overflow:auto">
          <table id="usersTable">
            <thead><tr><th>ID</th><th>用户名</th><th>邮箱</th><th>状态</th><th>注册时间</th><th>操作</th></tr></thead>
            <tbody></tbody>
          </table>
        </div>
      </div>
    </div>

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
            <div class="field"><label for="smtp_user">用户名</label><input id="smtp_user" type="text" /></div>
            <div class="field"><label for="smtp_password">密码 / 授权码</label><input id="smtp_password" type="password" placeholder="留空 = 不修改" /></div>
          </div>
          <div class="check"><input id="smtp_secure" type="checkbox" /><label for="smtp_secure" style="margin:0">隐式 TLS（465 勾上；587 不勾）</label></div>
          <div class="check"><input id="smtp_starttls" type="checkbox" /><label for="smtp_starttls" style="margin:0">STARTTLS（587/25 建议勾上）</label></div>
          <div class="check"><input id="smtp_reject" type="checkbox" /><label for="smtp_reject" style="margin:0">校验服务器证书（公网必须勾）</label></div>
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
            <div class="field"><label for="aliyun_account">发信地址</label><input id="aliyun_account" type="text" /></div>
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
  </section>
</main>

<!-- 应用编辑 -->
<div class="modal" id="appModal" hidden>
  <div class="modal-card">
    <h2 id="appModalTitle">编辑应用</h2>
    <div class="row">
      <div class="field"><label for="a_id">应用 id（字母/数字/._-，创建后不可改）</label><input id="a_id" type="text" /></div>
      <div class="field"><label for="a_name">名称</label><input id="a_name" type="text" /></div>
    </div>
    <div class="field"><label for="a_desc">简介</label><textarea id="a_desc"></textarea></div>
    <div class="row">
      <div class="field"><label for="a_category">分类</label><select id="a_category"></select></div>
      <div class="field"><label for="a_author">作者</label><input id="a_author" type="text" /></div>
    </div>
    <div class="row">
      <div class="field"><label for="a_version">版本（客户端靠它判断升级）</label><input id="a_version" type="text" placeholder="1.0.0" /></div>
      <div class="field"><label for="a_sort">排序权重（越大越靠前）</label><input id="a_sort" type="number" /></div>
    </div>
    <div class="row">
      <div class="field"><label for="a_icon">图标 URL</label><input id="a_icon" type="text" /></div>
      <div class="field"><label for="a_home">主页 URL</label><input id="a_home" type="text" /></div>
    </div>
    <div class="field"><label for="a_shots">截图 URL（每行一个）</label><textarea id="a_shots"></textarea></div>
    <div class="field"><label for="a_perms">声明权限（逗号分隔，如 camera,microphone）</label><input id="a_perms" type="text" /></div>
    <div class="field"><label>标签</label><div id="a_tags" class="chip-list"></div></div>

    <div id="pkgBlock" hidden>
      <h3>安装包</h3>
      <p class="hint" id="pkgInfo"></p>
      <div id="pkgVersions" class="hint"></div>
      <div class="row">
        <div class="field"><label for="pkg_version">上传的版本号</label><input id="pkg_version" type="text" placeholder="1.0.1" /></div>
        <div class="field"><label for="pkg_entry">入口文件</label><input id="pkg_entry" type="text" placeholder="index.html" /></div>
      </div>
      <div class="field"><label for="pkg_file">选择 zip</label><input id="pkg_file" type="file" accept=".zip" /></div>
      <button class="ghost" type="button" id="pkgUploadBtn">上传并设为当前版本</button>
    </div>

    <div class="modal-actions">
      <button class="ghost" type="button" id="appCancel">取消</button>
      <button class="primary" type="button" id="appSave">保存</button>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>
<script>
(function () {
  var ENABLED = ${enabled ? 'true' : 'false'};
  var $ = function (id) { return document.getElementById(id); };
  var toastEl = $('toast');
  var toastTimer = null;
  var appCache = [];        // 当前列表（编辑时按 id 取原始数据）
  var metaCache = { categories: [], tags: [] };

  function esc(text) {
    return String(text == null ? '' : text).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function toast(message, isError) {
    toastEl.textContent = message;
    toastEl.className = 'toast show' + (isError ? ' err' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.className = 'toast'; }, 3200);
  }

  function api(path, options) {
    var opts = options || {};
    var init = {
      method: opts.method || 'GET',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' }
    };
    if (opts.body !== undefined) init.body = JSON.stringify(opts.body);
    return fetch('/admin/api' + path, init).then(function (res) {
      if (res.status === 401) { showLogin(); throw new Error('请先登录'); }
      return res.json().catch(function () { return null; }).then(function (body) {
        if (!res.ok) {
          var msg = body && body.error && body.error.message ? body.error.message : ('请求失败 ' + res.status);
          throw new Error(msg);
        }
        return body ? body.data : null;
      });
    });
  }

  function postForm(path, formData) {
    return fetch('/admin/api' + path, {
      method: 'POST', credentials: 'same-origin', body: formData
    }).then(function (res) {
      if (res.status === 401) { showLogin(); throw new Error('请先登录'); }
      return res.json().catch(function () { return null; }).then(function (body) {
        if (!res.ok) {
          var msg = body && body.error && body.error.message ? body.error.message : ('上传失败 ' + res.status);
          throw new Error(msg);
        }
        return body ? body.data : null;
      });
    });
  }

  function showLogin() {
    $('login').hidden = !ENABLED;
    $('panel').hidden = true;
    $('disabled').hidden = ENABLED;
  }

  function showPanel() {
    $('login').hidden = true;
    $('panel').hidden = false;
    $('disabled').hidden = true;
  }

  // ---------------- 登录
  $('loginForm').addEventListener('submit', function (e) {
    e.preventDefault();
    api('/login', { method: 'POST', body: { password: $('password').value } })
      .then(function () {
        $('password').value = '';
        showPanel();
        return refreshAll();
      })
      .catch(function (err) { toast(err.message, true); });
  });

  // ---------------- Tab
  var TAB_NAMES = ['overview', 'apps', 'users', 'mail'];
  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (btn) {
    btn.addEventListener('click', function () {
      Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (b) {
        b.setAttribute('aria-selected', String(b === btn));
      });
      TAB_NAMES.forEach(function (name) {
        $('tab-' + name).hidden = name !== btn.dataset.tab;
      });
      if (btn.dataset.tab === 'apps') loadApps();
      if (btn.dataset.tab === 'users') loadUsers();
    });
  });

  // ---------------- 概览
  function loadStatus() {
    return api('/status').then(function (data) {
      $('conn').textContent = '已连接 · 运行 ' + data.uptime;
      var stats = [
        ['用户', data.counts.users],
        ['应用', data.counts.apps],
        ['活跃会话', data.counts.sessions],
        ['24h 验证码', data.counts.codes24h]
      ];
      $('stats').innerHTML = stats.map(function (pair) {
        return '<div class="stat"><b>' + pair[1] + '</b><span>' + pair[0] + '</span></div>';
      }).join('');
      var mail = data.mail;
      $('policy').innerHTML = [
        ['邮件通道', mail.driver + (mail.ready ? ' · 就绪' : ' · 未就绪')],
        ['注册验证码', data.auth.registerCode ? '需要' : '不需要'],
        ['登录验证码', data.auth.loginCode ? '需要' : '不需要'],
        ['token', data.auth.tokenTtl === 'never' ? '永不过期' : data.auth.tokenTtl],
        ['数据库', data.db.ok ? '正常' : '异常']
      ].map(function (pair) {
        return '<div class="kv"><span>' + pair[0] + '</span><span>' + pair[1] + '</span></div>';
      }).join('');
    });
  }

  // ================================================================ 应用
  function loadApps() {
    var q = $('appSearch').value.trim();
    return api('/apps?q=' + encodeURIComponent(q)).then(function (data) {
      appCache = data.apps;
      renderApps(appCache);
    }).catch(function (err) { toast(err.message, true); });
  }

  function renderApps(apps) {
    var box = $('appList');
    if (!apps.length) {
      box.innerHTML = '<p class="hint">没有匹配的应用。点「新建应用」添加一个。</p>';
      return;
    }
    box.innerHTML = apps.map(function (a) {
      var size = a.packageBytes ? (Math.round(a.packageBytes / 1024 * 10) / 10) + ' KB' : '无包';
      var state = a.deleted
        ? '<span class="badge err">已下架</span>'
        : '<span class="badge ok">已上架</span>';
      var sha = a.packageSha256 ? ' · sha ' + a.packageSha256.slice(0, 8) : '';
      return '<div class="item">' +
        '<div>' +
          '<div class="item-title">' + esc(a.name) +
            ' <span class="tag">' + esc(a.id) + '</span> ' + state + '</div>' +
          '<div class="item-sub">v' + esc(a.version) + ' · ' + esc(a.categoryName || '未分类') +
            ' · 包 ' + size + sha + '</div>' +
        '</div>' +
        '<div class="item-actions">' +
          '<button class="ghost small" data-act="edit" data-id="' + esc(a.id) + '">编辑</button>' +
          '<button class="ghost small" data-act="toggle" data-id="' + esc(a.id) +
            '" data-deleted="' + (a.deleted ? '1' : '0') + '">' + (a.deleted ? '上架' : '下架') + '</button>' +
          '<button class="ghost small danger" data-act="del" data-id="' + esc(a.id) + '">删除</button>' +
        '</div>' +
      '</div>';
    }).join('');
  }

  $('appList').addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-act]');
    if (!btn) return;
    var id = btn.dataset.id;
    var app = appCache.find(function (a) { return a.id === id; });
    if (btn.dataset.act === 'edit') openAppModal(app || null);
    if (btn.dataset.act === 'toggle') toggleDeleted(app);
    if (btn.dataset.act === 'del') deleteApp(app);
  });

  $('appSearchBtn').addEventListener('click', loadApps);
  $('appSearch').addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); loadApps(); }
  });
  $('appNewBtn').addEventListener('click', function () { openAppModal(null); });

  function loadMeta() {
    return api('/categories').then(function (data) {
      metaCache = data;
      var select = $('a_category');
      select.innerHTML = '<option value="">（未分类）</option>' + data.categories.map(function (c) {
        return '<option value="' + esc(c.id) + '">' + esc(c.name) + '</option>';
      }).join('');
      $('a_tags').innerHTML = data.tags.map(function (t) {
        return '<label class="chip"><input type="checkbox" value="' + esc(t.name) + '" />' + esc(t.name) + '</label>';
      }).join('');
    });
  }

  function openAppModal(app) {
    loadMeta().then(function () {
      var creating = !app;
      $('appModalTitle').textContent = creating ? '新建应用' : '编辑应用';
      $('a_id').value = app ? app.id : '';
      $('a_id').disabled = !creating;
      $('a_name').value = app ? app.name : '';
      $('a_desc').value = app ? app.description : '';
      $('a_author').value = app ? app.author : '';
      $('a_version').value = app ? app.version : '1.0.0';
      $('a_sort').value = app ? app.sortWeight : 0;
      $('a_icon').value = app ? app.icon : '';
      $('a_home').value = app ? app.homepage : '';
      $('a_shots').value = app ? app.screenshots.join('\\n') : '';
      $('a_perms').value = app ? app.permissions.join(',') : '';
      $('a_category').value = app ? app.categoryId : '';
      var tagSet = app ? app.tagNames : [];
      Array.prototype.forEach.call($('a_tags').querySelectorAll('input'), function (input) {
        input.checked = tagSet.indexOf(input.value) >= 0;
      });
      $('pkgBlock').hidden = creating;
      if (!creating) loadPkgInfo(app);
      $('appModal').hidden = false;
    }).catch(function (err) { toast(err.message, true); });
  }

  function closeAppModal() { $('appModal').hidden = true; }
  $('appCancel').addEventListener('click', closeAppModal);
  $('appModal').addEventListener('click', function (e) {
    if (e.target === $('appModal')) closeAppModal();
  });

  function readAppModal() {
    var tags = [];
    Array.prototype.forEach.call($('a_tags').querySelectorAll('input:checked'), function (i) {
      tags.push(i.value);
    });
    return {
      id: $('a_id').value.trim(),
      name: $('a_name').value.trim(),
      description: $('a_desc').value.trim(),
      categoryId: $('a_category').value,
      author: $('a_author').value.trim(),
      version: $('a_version').value.trim(),
      sortWeight: Number($('a_sort').value) || 0,
      icon: $('a_icon').value.trim(),
      homepage: $('a_home').value.trim(),
      screenshots: $('a_shots').value.split('\\n').map(function (s) { return s.trim(); }).filter(Boolean),
      permissions: $('a_perms').value.split(',').map(function (s) { return s.trim(); }).filter(Boolean),
      tagNames: tags
    };
  }

  $('appSave').addEventListener('click', function () {
    var payload = readAppModal();
    var creating = !payload.id || $('a_id').disabled === false;
    if (creating) {
      api('/apps', { method: 'POST', body: payload })
        .then(function () { closeAppModal(); toast('已创建'); return loadApps(); })
        .then(loadStatus)
        .catch(function (err) { toast(err.message, true); });
    } else {
      api('/apps/' + encodeURIComponent(payload.id), { method: 'PUT', body: payload })
        .then(function () { closeAppModal(); toast('已保存'); return loadApps(); })
        .then(loadStatus)
        .catch(function (err) { toast(err.message, true); });
    }
  });

  function toggleDeleted(app) {
    if (!app) return;
    api('/apps/' + encodeURIComponent(app.id), {
      method: 'PUT', body: { deleted: !app.deleted }
    }).then(function () {
      toast(app.deleted ? '已上架' : '已下架');
      return loadApps();
    }).then(loadStatus).catch(function (err) { toast(err.message, true); });
  }

  function deleteApp(app) {
    if (!app) return;
    if (!confirm('删除「' + app.name + '」？\\n\\n这是软删除：市场里不再出现，数据还在，之后可以重新上架。')) return;
    api('/apps/' + encodeURIComponent(app.id), { method: 'DELETE' })
      .then(function () { toast('已删除'); return loadApps(); })
      .then(loadStatus)
      .catch(function (err) { toast(err.message, true); });
  }

  // ---------------- 包
  function loadPkgInfo(app) {
    var size = app.packageBytes ? (Math.round(app.packageBytes / 1024 * 10) / 10) + ' KB' : '还没有包';
    $('pkgInfo').textContent = '当前 v' + app.version + ' · ' + size +
      (app.packageSha256 ? ' · sha ' + app.packageSha256.slice(0, 12) : '');
    $('pkg_version').value = app.version;
    $('pkg_entry').value = app.packageEntry || 'index.html';
    $('pkgVersions').textContent = '';
    api('/apps/' + encodeURIComponent(app.id) + '/packages').then(function (data) {
      if (!data.packages.length) return;
      $('pkgVersions').textContent = '本机已有版本：' + data.packages.map(function (p) {
        return 'v' + p.version + '（' + Math.round(p.bytes / 1024) + 'KB）';
      }).join('、');
    }).catch(function () {});
  }

  $('pkgUploadBtn').addEventListener('click', function () {
    var file = $('pkg_file').files[0];
    if (!file) { toast('先选一个 .zip 文件', true); return; }
    var id = $('a_id').value.trim();
    var form = new FormData();
    form.append('file', file);
    form.append('version', $('pkg_version').value.trim());
    form.append('entry', $('pkg_entry').value.trim() || 'index.html');
    $('pkgUploadBtn').disabled = true;
    postForm('/apps/' + encodeURIComponent(id) + '/package', form)
      .then(function (data) {
        toast('已上传 v' + data.version + '（' + Math.round(data.bytes / 1024) + 'KB）');
        $('pkg_file').value = '';
        var app = appCache.find(function (a) { return a.id === id; });
        if (app) {
          app.version = data.version;
          app.packageBytes = data.bytes;
          app.packageSha256 = data.sha256;
          app.packageEntry = data.entry;
          loadPkgInfo(app);
        }
        return loadApps();
      })
      .then(loadStatus)
      .catch(function (err) { toast(err.message, true); })
      .finally(function () { $('pkgUploadBtn').disabled = false; });
  });

  // ================================================================ 用户
  function loadUsers() {
    var q = $('userSearch').value.trim();
    return api('/users?q=' + encodeURIComponent(q)).then(function (data) {
      var tbody = $('usersTable').querySelector('tbody');
      if (!data.users.length) {
        tbody.innerHTML = '<tr><td colspan="6" class="hint">没有匹配的用户</td></tr>';
        return;
      }
      tbody.innerHTML = data.users.map(function (u) {
        var disabled = u.status === 'disabled';
        return '<tr>' +
          '<td>' + u.id + '</td>' +
          '<td>' + esc(u.username) + '</td>' +
          '<td>' + esc(u.email) + '</td>' +
          '<td>' + (disabled ? '<span class="badge err">已封禁</span>' : '<span class="badge ok">正常</span>') + '</td>' +
          '<td>' + esc(u.createdAt || '') + '</td>' +
          '<td><div class="item-actions">' +
            '<button class="ghost small" data-user="' + u.id + '" data-act="toggle" data-status="' +
              (disabled ? 'active' : 'disabled') + '">' + (disabled ? '解封' : '封禁') + '</button>' +
            '<button class="ghost small" data-user="' + u.id + '" data-act="password">改密码</button>' +
            '<button class="ghost small" data-user="' + u.id + '" data-act="logout">踢下线</button>' +
          '</div></td>' +
        '</tr>';
      }).join('');
    }).catch(function (err) { toast(err.message, true); });
  }

  $('userSearchBtn').addEventListener('click', loadUsers);
  $('userSearch').addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); loadUsers(); }
  });

  $('usersTable').addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-user]');
    if (!btn) return;
    var id = btn.dataset.user;
    if (btn.dataset.act === 'toggle') {
      api('/users/' + id + '/status', { method: 'POST', body: { status: btn.dataset.status } })
        .then(function () {
          toast(btn.dataset.status === 'disabled' ? '已封禁，并踢掉了所有登录' : '已解封');
          return loadUsers();
        })
        .then(loadStatus)
        .catch(function (err) { toast(err.message, true); });
    }
    if (btn.dataset.act === 'password') {
      var pw = prompt('输入新密码（至少 8 位）。改完这个用户所有设备都要重新登录。');
      if (!pw) return;
      api('/users/' + id + '/password', { method: 'POST', body: { password: pw } })
        .then(function () { toast('密码已重置'); })
        .catch(function (err) { toast(err.message, true); });
    }
    if (btn.dataset.act === 'logout') {
      api('/users/' + id + '/logout', { method: 'POST', body: {} })
        .then(function () { toast('已踢下线'); return loadStatus(); })
        .catch(function (err) { toast(err.message, true); });
    }
  });

  // ================================================================ 邮件
  var DRIVER_BLOCKS = ['smtp', 'resend', 'sendgrid', 'aliyun'];

  function syncDriverBlocks() {
    var driver = $('mail_driver').value;
    Array.prototype.forEach.call(document.querySelectorAll('[data-driver-block]'), function (el) {
      el.hidden = el.dataset.driverBlock !== driver;
    });
  }
  $('mail_driver').addEventListener('change', syncDriverBlocks);

  function loadMail() {
    return api('/mail').then(function (mail) {
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
      var badge = $('mailState');
      badge.textContent = mail.ready ? '就绪' : '未就绪';
      badge.className = 'badge ' + (mail.ready ? 'ok' : 'warn');
      $('mailReason').textContent = mail.ready ? ('当前通道：' + mail.driver) : ('原因：' + mail.reason);
      syncDriverBlocks();
    });
  }

  $('mailForm').addEventListener('submit', function (e) {
    e.preventDefault();
    var payload = {
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
        rejectUnauthorized: $('smtp_reject').checked
      },
      resend: { apiKey: $('resend_key').value },
      sendgrid: { apiKey: $('sendgrid_key').value },
      aliyun: {
        accessKeyId: $('aliyun_id').value.trim(),
        accessKeySecret: $('aliyun_secret').value,
        accountName: $('aliyun_account').value.trim(),
        region: $('aliyun_region').value.trim() || 'cn-hangzhou'
      },
      codeTtl: Number($('code_ttl').value) || 600,
      codeCooldown: Number($('code_cooldown').value) || 60,
      codeMaxPerEmailHour: Number($('code_email_hour').value) || 10,
      codeMaxPerIpHour: Number($('code_ip_hour').value) || 30,
      codeMaxAttempts: Number($('code_attempts').value) || 5,
      devEchoCode: $('dev_echo').checked,
      tokenTtl: $('token_ttl').value,
      registerCode: $('register_code').checked,
      loginCode: $('login_code').checked
    };
    api('/mail', { method: 'PUT', body: payload })
      .then(function (result) {
        toast(result.mail.ready ? '已保存，通道就绪' : '已保存，但通道还未就绪');
        return loadMail();
      })
      .then(loadStatus)
      .catch(function (err) { toast(err.message, true); });
  });

  $('reloadBtn').addEventListener('click', function () {
    loadMail().catch(function (err) { toast(err.message, true); });
  });

  $('testBtn').addEventListener('click', function () {
    var to = $('test_to').value.trim();
    if (!to) { toast('先填收件地址', true); return; }
    $('testBtn').disabled = true;
    api('/mail/test', { method: 'POST', body: { to: to } })
      .then(function (data) { toast('测试邮件已交给 ' + data.driver + '（' + data.ms + 'ms）'); })
      .catch(function (err) { toast(err.message, true); })
      .finally(function () { $('testBtn').disabled = false; });
  });

  function refreshAll() {
    return loadStatus().then(loadMail).then(loadApps);
  }

  // ---------------- 启动
  if (!ENABLED) {
    showLogin();
  } else {
    api('/status')
      .then(function () { showPanel(); return refreshAll(); })
      .catch(function () { showLogin(); });
  }
})();
</script>
</body>
</html>`;
}

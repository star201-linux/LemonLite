// server/src/admin/ui.js
//
// 管理面板的页面（整块 HTML + CSS + 原生 JS）。
//
// 为什么不引前端框架、不挂 CDN：
//   * 这个面板要在**没有外网**的内网服务器上用 —— 任何外链都是单点故障；
//   * 它一共就六屏（概览 / 应用 / 分类标签 / 用户 / 管理员 / 邮件），
//     引入构建工具只会让「改一行文案」也要重新编译。
// 所以这里是纯静态字符串，浏览器直接吃。
//
// 注意：内层 <script> 里**不用模板字符串**（反引号 + ${}），
// 因为它们会被外层这个 JS 模板字符串先求值。内层一律用拼接。
//
// 页面自己是「空壳」：加载后先请求 /api/session，返回
//   { setup: true }        → 显示「创建第一个管理员」
//   { setup: false, user: null } → 显示登录
//   { setup: false, user: {...} } → 显示面板
// 这样服务端不需要为三种状态渲染三份 HTML，也不会把「有没有账号」
// 写进缓存住的页面里。

/**
 * @param {{version: string}} opts
 * @returns {string} 完整 HTML
 */
export function renderAdminPage({ version }) {
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
    padding: 18px 20px; max-width: 980px; margin: 0 auto; }
  header h1 { font-size: 18px; margin: 0; font-weight: 650; }
  header .spacer { flex: 1 1 auto; }
  .tag { font-size: 12px; padding: 3px 9px; border-radius: 999px;
    background: var(--surface-2); color: var(--muted); }
  main { max-width: 980px; margin: 0 auto; padding: 0 16px 64px; }
  .card { background: var(--surface); border: 1px solid var(--border);
    border-radius: var(--radius); box-shadow: var(--shadow); padding: 18px; margin-bottom: 16px; }
  .tabs { display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; }
  .tab { border: 1px solid var(--border); background: var(--surface); color: var(--text);
    padding: 9px 16px; border-radius: 999px; font-size: 14px; cursor: pointer; transition: .18s ease; }
  .tab[aria-selected="true"] { background: var(--primary); border-color: var(--primary); color: var(--on-primary); }
  h2 { font-size: 15px; margin: 0 0 12px; font-weight: 650; }
  h3 { font-size: 13px; margin: 18px 0 8px; color: var(--primary); font-weight: 650; }
  p.hint { color: var(--muted); font-size: 13px; line-height: 1.6; margin: 6px 0; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 12px; }
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
  .toolbar input[type=text], .toolbar input[type=password] { flex: 1 1 200px; width: auto; }
  .toolbar input.narrow { flex: 0 1 180px; }
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
    max-width: 660px; box-shadow: var(--shadow); }
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
  <span class="spacer"></span>
  <span id="who" class="tag" hidden></span>
  <button id="logoutBtn" class="ghost small" type="button" hidden>退出</button>
</header>
<main>
  <section id="setup" class="card" hidden>
    <h2>第一次使用：创建管理员账号</h2>
    <p class="hint">
      数据库里还没有管理账号。现在创建的账号就是第一个管理员，
      默认属于 <code>admin</code> 组，可以管理应用、分类标签、用户、邮件配置，
      也可以再添加别的管理员。
    </p>
    <p class="hint">这个页面只会在「一个管理账号都没有」时出现，建完就消失。</p>
    <form id="setupForm">
      <div class="field" id="setupTokenField" hidden>
        <label for="setup_token">初始化口令（ADMIN_SETUP_TOKEN）</label>
        <input id="setup_token" type="password" autocomplete="off" placeholder="服务端 .env 里配置的口令" />
      </div>
      <div class="row">
        <div class="field">
          <label for="setup_user">用户名</label>
          <input id="setup_user" type="text" autocomplete="username" placeholder="3~32 位字母数字" />
        </div>
        <div class="field">
          <label for="setup_pass">密码</label>
          <input id="setup_pass" type="password" autocomplete="new-password" placeholder="至少 8 位" />
        </div>
      </div>
      <div class="field">
        <label for="setup_pass2">确认密码</label>
        <input id="setup_pass2" type="password" autocomplete="new-password" />
      </div>
      <div class="actions"><button class="primary" type="submit">创建并进入面板</button></div>
    </form>
  </section>

  <section id="login" class="card" hidden>
    <h2>登录</h2>
    <p class="hint">用管理账号登录。账号存在服务端数据库里，忘了密码就让另一位管理员重置。</p>
    <form id="loginForm">
      <div class="field">
        <label for="login_user">用户名</label>
        <input id="login_user" type="text" autocomplete="username" />
      </div>
      <div class="field">
        <label for="login_pass">密码</label>
        <input id="login_pass" type="password" autocomplete="current-password" />
      </div>
      <div class="actions"><button class="primary" type="submit">登录</button></div>
    </form>
  </section>

  <section id="panel" hidden>
    <div class="tabs">
      <button class="tab" data-tab="overview" aria-selected="true">概览</button>
      <button class="tab" data-tab="apps" aria-selected="false">应用</button>
      <button class="tab" data-tab="taxonomy" aria-selected="false">分类标签</button>
      <button class="tab" data-tab="users" aria-selected="false">用户</button>
      <button class="tab" data-tab="admins" aria-selected="false">管理员</button>
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

    <div id="tab-taxonomy" hidden>
      <div class="card">
        <h2>分类</h2>
        <p class="hint">
          一个应用可以同时属于多个分类。分类 id 会出现在接口参数里（<code>?category=</code>），
          留空就按名字自动生成（中文名会生成 <code>cat_xxxxxxxx</code> 这样的 id）。
        </p>
        <form id="catForm" class="toolbar">
          <input id="cat_name" type="text" placeholder="分类名，如「效率」" />
          <input id="cat_id" type="text" class="narrow" placeholder="id（可留空）" />
          <button class="primary" type="submit">新建分类</button>
        </form>
        <div id="catList"><p class="hint">加载中…</p></div>
      </div>
      <div class="card">
        <h2>标签</h2>
        <p class="hint">标签用于搜索筛选与卡片展示，一个应用可以带多个标签。</p>
        <form id="tagForm" class="toolbar">
          <input id="tag_name" type="text" placeholder="标签名，如「开源」" />
          <button class="primary" type="submit">新建标签</button>
        </form>
        <div id="tagList"><p class="hint">加载中…</p></div>
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

    <div id="tab-admins" hidden>
      <div class="card">
        <h2>管理员账号</h2>
        <p class="hint">
          新账号默认属于 <code>admin</code> 组，能管理应用、分类、用户、邮件配置和其他管理员。
          改密码或停用某个账号，会让它在所有浏览器上的登录立刻失效。
        </p>
        <form id="adminForm" class="toolbar">
          <input id="admin_user" type="text" autocomplete="off" placeholder="用户名（3~32 位字母数字）" />
          <input id="admin_pass" type="password" autocomplete="new-password" placeholder="密码（至少 8 位）" />
          <button class="primary" type="submit">添加管理员</button>
        </form>
        <div style="overflow:auto">
          <table id="adminsTable">
            <thead><tr><th>ID</th><th>用户名</th><th>组</th><th>状态</th><th>最近登录</th><th>操作</th></tr></thead>
            <tbody></tbody>
          </table>
        </div>
      </div>
      <div class="card">
        <h2>修改我的密码</h2>
        <form id="selfPwForm">
          <div class="row">
            <div class="field"><label for="self_old">当前密码</label><input id="self_old" type="password" autocomplete="current-password" /></div>
            <div class="field"><label for="self_new">新密码</label><input id="self_new" type="password" autocomplete="new-password" placeholder="至少 8 位" /></div>
          </div>
          <div class="field"><label for="self_new2">再输一次新密码</label><input id="self_new2" type="password" autocomplete="new-password" /></div>
          <div class="actions"><button class="primary" type="submit">改密码</button></div>
          <p class="hint">改完会保持当前登录，其它浏览器上的旧登录全部失效。</p>
        </form>
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
    <div class="field">
      <label>分类（可多选，在「分类标签」页新建）</label>
      <div id="a_categories" class="chip-list"></div>
    </div>
    <div class="row">
      <div class="field"><label for="a_author">作者</label><input id="a_author" type="text" /></div>
      <div class="field"><label for="a_version">版本（客户端靠它判断升级）</label><input id="a_version" type="text" placeholder="1.0.0" /></div>
    </div>
    <div class="row">
      <div class="field"><label for="a_sort">排序权重（越大越靠前）</label><input id="a_sort" type="number" /></div>
      <div class="field"><label for="a_icon">图标 URL（也可以直接上传，见下）</label><input id="a_icon" type="text" /></div>
    </div>
    <div id="iconBlock" hidden>
      <div class="field"><label for="icon_file">上传图标（PNG / JPEG / WebP / GIF，≤2MB）</label><input id="icon_file" type="file" accept="image/png,image/jpeg,image/webp,image/gif" /></div>
      <button class="ghost" type="button" id="iconUploadBtn">上传图标</button>
    </div>
    <div class="field"><label for="a_home">主页 URL</label><input id="a_home" type="text" /></div>
    <div class="field"><label for="a_shots">截图 URL（每行一个）</label><textarea id="a_shots"></textarea></div>
    <div class="field"><label for="a_perms">声明权限（逗号分隔，如 camera,microphone）</label><input id="a_perms" type="text" /></div>
    <div class="field"><label>标签（可多选）</label><div id="a_tags" class="chip-list"></div></div>

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
  var $ = function (id) { return document.getElementById(id); };
  var toastEl = $('toast');
  var toastTimer = null;
  var appCache = [];        // 当前列表（编辑时按 id 取原始数据）
  var metaCache = { categories: [], tags: [] };
  var currentUser = null;

  function esc(text) {
    return String(text == null ? '' : text).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function toast(message, isError) {
    toastEl.textContent = message;
    toastEl.className = 'toast show' + (isError ? ' err' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.className = 'toast'; }, 3600);
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
          var err = new Error(msg);
          err.code = body && body.error ? body.error.code : '';
          throw err;
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

  // ---------------- 三种页面状态
  function showSetup(setupTokenRequired) {
    $('setup').hidden = false;
    $('login').hidden = true;
    $('panel').hidden = true;
    $('setupTokenField').hidden = !setupTokenRequired;
    $('who').hidden = true;
    $('logoutBtn').hidden = true;
    $('conn').textContent = '等待初始化';
  }

  function showLogin() {
    $('setup').hidden = true;
    $('login').hidden = false;
    $('panel').hidden = true;
    $('who').hidden = true;
    $('logoutBtn').hidden = true;
  }

  function showPanel(user) {
    currentUser = user || currentUser;
    $('setup').hidden = true;
    $('login').hidden = true;
    $('panel').hidden = false;
    $('who').hidden = false;
    $('who').textContent = currentUser
      ? '已登录：' + currentUser.username + ' · ' + currentUser.role
      : '已登录';
    $('logoutBtn').hidden = false;
  }

  // ---------------- 首次建号
  $('setupForm').addEventListener('submit', function (e) {
    e.preventDefault();
    var pass = $('setup_pass').value;
    if (pass !== $('setup_pass2').value) { toast('两次输入的密码不一样', true); return; }
    api('/setup', {
      method: 'POST',
      body: {
        username: $('setup_user').value.trim(),
        password: pass,
        setupToken: $('setup_token').value
      }
    }).then(function (data) {
      $('setup_pass').value = '';
      $('setup_pass2').value = '';
      showPanel(data.user);
      toast('管理员已创建');
      return refreshAll();
    }).catch(function (err) { toast(err.message, true); });
  });

  // ---------------- 登录 / 退出
  $('loginForm').addEventListener('submit', function (e) {
    e.preventDefault();
    api('/login', {
      method: 'POST',
      body: { username: $('login_user').value.trim(), password: $('login_pass').value }
    }).then(function (data) {
      $('login_pass').value = '';
      showPanel(data.user);
      return refreshAll();
    }).catch(function (err) { toast(err.message, true); });
  });

  $('logoutBtn').addEventListener('click', function () {
    api('/logout', { method: 'POST', body: {} }).then(function () {
      currentUser = null;
      showLogin();
      toast('已退出');
    }).catch(function () { showLogin(); });
  });

  // ---------------- Tab
  var TAB_NAMES = ['overview', 'apps', 'taxonomy', 'users', 'admins', 'mail'];
  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (btn) {
    btn.addEventListener('click', function () {
      Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (b) {
        b.setAttribute('aria-selected', String(b === btn));
      });
      TAB_NAMES.forEach(function (name) {
        $('tab-' + name).hidden = name !== btn.dataset.tab;
      });
      if (btn.dataset.tab === 'apps') loadApps();
      if (btn.dataset.tab === 'taxonomy') loadMeta();
      if (btn.dataset.tab === 'users') loadUsers();
      if (btn.dataset.tab === 'admins') loadAdmins();
      if (btn.dataset.tab === 'mail') loadMail();
    });
  });

  // ---------------- 概览
  function loadStatus() {
    return api('/status').then(function (data) {
      $('conn').textContent = '已连接 · 运行 ' + data.uptime;
      var stats = [
        ['用户', data.counts.users],
        ['应用', data.counts.apps],
        ['分类', data.counts.categories],
        ['标签', data.counts.tags],
        ['管理员', data.counts.admins],
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
    }).catch(function (err) { toast(err.message, true); });
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
      var cats = (a.categories && a.categories.length)
        ? a.categories.map(function (c) { return c.name; }).join(' / ')
        : '未分类';
      return '<div class="item">' +
        '<div>' +
          '<div class="item-title">' + esc(a.name) +
            ' <span class="tag">' + esc(a.id) + '</span> ' + state + '</div>' +
          '<div class="item-sub">v' + esc(a.version) + ' · ' + esc(cats) +
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

  // ---------------- 分类 / 标签（下拉与勾选框共用一份数据）
  function loadMeta() {
    return api('/meta').then(function (data) {
      metaCache = data;
      renderTaxonomy();
      renderAppMetaChips();
    }).catch(function (err) { toast(err.message, true); });
  }

  function renderAppMetaChips() {
    var cats = metaCache.categories || [];
    var tags = metaCache.tags || [];
    $('a_categories').innerHTML = cats.length
      ? cats.map(function (c) {
          return '<label class="chip"><input type="checkbox" value="' + esc(c.id) + '" />' +
            esc(c.name) + '</label>';
        }).join('')
      : '<span class="hint">还没有分类，去「分类标签」页新建</span>';
    $('a_tags').innerHTML = tags.length
      ? tags.map(function (t) {
          return '<label class="chip"><input type="checkbox" value="' + esc(t.name) + '" />' +
            esc(t.name) + '</label>';
        }).join('')
      : '<span class="hint">还没有标签，去「分类标签」页新建</span>';
  }

  function renderTaxonomy() {
    var cats = metaCache.categories || [];
    var tags = metaCache.tags || [];
    $('catList').innerHTML = cats.length ? cats.map(function (c, i) {
      return '<div class="item">' +
        '<div>' +
          '<div class="item-title">' + esc(c.name) + ' <span class="tag">' + esc(c.id) + '</span></div>' +
          '<div class="item-sub">' + (c.appCount || 0) + ' 个应用 · 排序 ' + c.sortOrder + '</div>' +
        '</div>' +
        '<div class="item-actions">' +
          '<button class="ghost small" data-cat="' + esc(c.id) + '" data-act="up"' +
            (i === 0 ? ' disabled' : '') + '>上移</button>' +
          '<button class="ghost small" data-cat="' + esc(c.id) + '" data-act="down"' +
            (i === cats.length - 1 ? ' disabled' : '') + '>下移</button>' +
          '<button class="ghost small" data-cat="' + esc(c.id) + '" data-act="rename">重命名</button>' +
          '<button class="ghost small danger" data-cat="' + esc(c.id) + '" data-act="del">删除</button>' +
        '</div>' +
      '</div>';
    }).join('') : '<p class="hint">还没有分类</p>';

    $('tagList').innerHTML = tags.length ? tags.map(function (t) {
      return '<div class="item">' +
        '<div>' +
          '<div class="item-title">' + esc(t.name) + ' <span class="tag">' + esc(t.slug) + '</span></div>' +
          '<div class="item-sub">' + (t.appCount || 0) + ' 个应用</div>' +
        '</div>' +
        '<div class="item-actions">' +
          '<button class="ghost small" data-tag="' + t.id + '" data-act="rename">重命名</button>' +
          '<button class="ghost small danger" data-tag="' + t.id + '" data-act="del">删除</button>' +
        '</div>' +
      '</div>';
    }).join('') : '<p class="hint">还没有标签</p>';
  }

  $('catForm').addEventListener('submit', function (e) {
    e.preventDefault();
    api('/categories', {
      method: 'POST',
      body: { name: $('cat_name').value.trim(), id: $('cat_id').value.trim() }
    }).then(function (data) {
      $('cat_name').value = '';
      $('cat_id').value = '';
      toast('已新建分类 ' + data.category.name);
      return loadMeta();
    }).then(loadApps).catch(function (err) { toast(err.message, true); });
  });

  $('tagForm').addEventListener('submit', function (e) {
    e.preventDefault();
    api('/tags', { method: 'POST', body: { name: $('tag_name').value.trim() } })
      .then(function (data) {
        $('tag_name').value = '';
        toast('已新建标签 ' + data.tag.name);
        return loadMeta();
      }).catch(function (err) { toast(err.message, true); });
  });

  $('catList').addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-cat]');
    if (!btn) return;
    var id = btn.dataset.cat;
    var act = btn.dataset.act;
    var cat = (metaCache.categories || []).find(function (c) { return c.id === id; });

    if (act === 'up' || act === 'down') {
      var ids = metaCache.categories.map(function (c) { return c.id; });
      var index = ids.indexOf(id);
      var target = act === 'up' ? index - 1 : index + 1;
      if (index < 0 || target < 0 || target >= ids.length) return;
      var moved = ids.splice(index, 1)[0];
      ids.splice(target, 0, moved);
      api('/categories/order', { method: 'PUT', body: { ids: ids } })
        .then(loadMeta).catch(function (err) { toast(err.message, true); });
      return;
    }

    if (act === 'rename') {
      var name = prompt('新的分类名', cat ? cat.name : '');
      if (!name) return;
      api('/categories/' + encodeURIComponent(id), { method: 'PUT', body: { name: name.trim() } })
        .then(function () { toast('已改名'); return loadMeta(); })
        .then(loadApps).catch(function (err) { toast(err.message, true); });
      return;
    }

    if (act === 'del') {
      if (!confirm('删除分类「' + (cat ? cat.name : id) + '」？')) return;
      deleteTaxonomy('/categories/' + encodeURIComponent(id), loadMeta);
    }
  });

  $('tagList').addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-tag]');
    if (!btn) return;
    var id = btn.dataset.tag;
    var tag = (metaCache.tags || []).find(function (t) { return String(t.id) === String(id); });

    if (btn.dataset.act === 'rename') {
      var name = prompt('新的标签名', tag ? tag.name : '');
      if (!name) return;
      api('/tags/' + id, { method: 'PUT', body: { name: name.trim() } })
        .then(function () { toast('已改名'); return loadMeta(); })
        .then(loadApps).catch(function (err) { toast(err.message, true); });
      return;
    }
    if (btn.dataset.act === 'del') {
      if (!confirm('删除标签「' + (tag ? tag.name : id) + '」？')) return;
      deleteTaxonomy('/tags/' + id, loadMeta);
    }
  });

  /**
   * 删除分类 / 标签。
   * 还在被应用使用时服务端返回 409 + 人话（还有 N 个应用在用），
   * 这里再问一次，确认后带 ?force=1 重试 —— 一次误点不应该清掉整类应用。
   */
  function deleteTaxonomy(path, done) {
    api(path, { method: 'DELETE' }).then(function () {
      toast('已删除');
      return done();
    }).then(loadApps).catch(function (err) {
      if (err.code !== 'category_in_use' && err.code !== 'tag_in_use') {
        toast(err.message, true);
        return;
      }
      if (!confirm(err.message)) return;
      api(path + '?force=1', { method: 'DELETE' })
        .then(function () { toast('已删除'); return done(); })
        .then(loadApps).catch(function (e2) { toast(e2.message, true); });
    });
  }

  // ---------------- 应用编辑弹窗
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

      var selectedCats = app && app.categoryIds ? app.categoryIds : [];
      Array.prototype.forEach.call($('a_categories').querySelectorAll('input'), function (input) {
        input.checked = selectedCats.indexOf(input.value) >= 0;
      });
      var tagSet = app && app.tagNames ? app.tagNames : [];
      Array.prototype.forEach.call($('a_tags').querySelectorAll('input'), function (input) {
        input.checked = tagSet.indexOf(input.value) >= 0;
      });

      $('pkgBlock').hidden = creating;
      // 图标上传需要一个已存在的 appId（文件名是 <appId>.<ext>）
      $('iconBlock').hidden = creating;
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
    var categories = [];
    Array.prototype.forEach.call($('a_categories').querySelectorAll('input:checked'), function (i) {
      categories.push(i.value);
    });
    var tags = [];
    Array.prototype.forEach.call($('a_tags').querySelectorAll('input:checked'), function (i) {
      tags.push(i.value);
    });
    return {
      id: $('a_id').value.trim(),
      name: $('a_name').value.trim(),
      description: $('a_desc').value.trim(),
      categoryIds: categories,
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
    var creating = !$('a_id').disabled;
    var request = creating
      ? api('/apps', { method: 'POST', body: payload })
      : api('/apps/' + encodeURIComponent(payload.id), { method: 'PUT', body: payload });
    request.then(function () {
      closeAppModal();
      toast(creating ? '已创建' : '已保存');
      return loadApps();
    }).then(loadStatus).catch(function (err) { toast(err.message, true); });
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
    if (!confirm('删除「' + app.name + '」？这是软删除：市场里不再出现，数据还在。')) return;
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

  // ---------------- 图标
  $('iconUploadBtn').addEventListener('click', function () {
    var file = $('icon_file').files[0];
    if (!file) { toast('先选一张图片', true); return; }
    var id = $('a_id').value.trim();
    if (!id) { toast('先保存应用再上传图标', true); return; }
    var form = new FormData();
    form.append('file', file);
    $('iconUploadBtn').disabled = true;
    postForm('/apps/' + encodeURIComponent(id) + '/icon', form)
      .then(function (data) {
        // 直接回填相对地址：保存时原样写回 apps.icon（客户端按服务器地址解析）
        $('a_icon').value = data.icon;
        $('icon_file').value = '';
        var app = appCache.find(function (a) { return a.id === id; });
        if (app) app.icon = data.icon;
        toast('图标已上传（' + Math.max(1, Math.round(data.bytes / 1024)) + ' KB）');
        return loadApps();
      })
      .catch(function (err) { toast(err.message, true); })
      .finally(function () { $('iconUploadBtn').disabled = false; });
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

  // ================================================================ 管理员
  function loadAdmins() {
    return api('/admins').then(function (data) {
      var tbody = $('adminsTable').querySelector('tbody');
      tbody.innerHTML = data.admins.map(function (a) {
        var disabled = a.status === 'disabled';
        var isSelf = currentUser && a.id === currentUser.id;
        return '<tr>' +
          '<td>' + a.id + '</td>' +
          '<td>' + esc(a.username) + (isSelf ? ' <span class="tag">我</span>' : '') + '</td>' +
          '<td>' + esc(a.role) + '</td>' +
          '<td>' + (disabled
            ? '<span class="badge err">已停用</span>'
            : '<span class="badge ok">正常</span>') + '</td>' +
          '<td>' + esc(a.lastLoginAt || '从未登录') + '</td>' +
          '<td><div class="item-actions">' +
            '<button class="ghost small" data-admin="' + a.id + '" data-act="password">改密码</button>' +
            '<button class="ghost small" data-admin="' + a.id + '" data-act="status" data-status="' +
              (disabled ? 'active' : 'disabled') + '">' + (disabled ? '启用' : '停用') + '</button>' +
            '<button class="ghost small danger" data-admin="' + a.id + '" data-act="del">删除</button>' +
          '</div></td>' +
        '</tr>';
      }).join('');
    }).catch(function (err) { toast(err.message, true); });
  }

  $('adminForm').addEventListener('submit', function (e) {
    e.preventDefault();
    api('/admins', {
      method: 'POST',
      body: { username: $('admin_user').value.trim(), password: $('admin_pass').value }
    }).then(function (data) {
      $('admin_user').value = '';
      $('admin_pass').value = '';
      toast('已添加管理员 ' + data.admin.username);
      return loadAdmins();
    }).then(loadStatus).catch(function (err) { toast(err.message, true); });
  });

  $('adminsTable').addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-admin]');
    if (!btn) return;
    var id = btn.dataset.admin;
    var act = btn.dataset.act;

    if (act === 'password') {
      var pw = prompt('给这个管理员设置新密码（至少 8 位）。它现有的登录会立刻失效。');
      if (!pw) return;
      api('/admins/' + id + '/password', { method: 'POST', body: { password: pw } })
        .then(function () { toast('密码已重置'); })
        .catch(function (err) { toast(err.message, true); });
      return;
    }
    if (act === 'status') {
      api('/admins/' + id + '/status', { method: 'POST', body: { status: btn.dataset.status } })
        .then(function () {
          toast(btn.dataset.status === 'disabled' ? '已停用' : '已启用');
          return loadAdmins();
        }).catch(function (err) { toast(err.message, true); });
      return;
    }
    if (act === 'del') {
      if (!confirm('删除这个管理员账号？')) return;
      api('/admins/' + id, { method: 'DELETE' })
        .then(function () { toast('已删除'); return loadAdmins(); })
        .then(loadStatus).catch(function (err) { toast(err.message, true); });
    }
  });

  $('selfPwForm').addEventListener('submit', function (e) {
    e.preventDefault();
    if ($('self_new').value !== $('self_new2').value) {
      toast('两次输入的新密码不一样', true);
      return;
    }
    api('/me/password', {
      method: 'POST',
      body: { oldPassword: $('self_old').value, newPassword: $('self_new').value }
    }).then(function () {
      $('self_old').value = '';
      $('self_new').value = '';
      $('self_new2').value = '';
      toast('密码已修改');
    }).catch(function (err) { toast(err.message, true); });
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
    }).catch(function (err) { toast(err.message, true); });
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

  $('reloadBtn').addEventListener('click', function () { loadMail(); });

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
  api('/session').then(function (data) {
    if (data.setup) { showSetup(data.setupTokenRequired); return; }
    if (!data.user) { showLogin(); return; }
    showPanel(data.user);
    return refreshAll();
  }).catch(function () {
    showLogin();
    toast('连不上服务端', true);
  });
})();
</script>
</body>
</html>`;
}

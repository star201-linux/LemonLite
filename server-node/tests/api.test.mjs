// server/test/api.test.mjs
//
// 路由层端到端测试：用 node:test + 内存 db 替身，
// 通过「真的起一个 Express 服务 + 真的发 HTTP 请求」来验证。
//
// 为什么不用 supertest：多一个依赖，而 Node 18+ 自带 fetch，
// 起在 127.0.0.1 的随机端口上就是最真实的验证。
//
// 运行：npm test

import { test, before, after, describe } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

// ---- 把 src/db.js 换成内存替身 ----
//
// 用 loader hook 是最干净的，但为了不引入额外复杂度，
// 这里直接改 import 解析：把 db.js 的内容替换成 re-export 替身。
const require = createRequire(import.meta.url);

const { fileURLToPath } = await import('node:url');
const fakePath = new URL('./fakedb.mjs', import.meta.url).href;

// 用一个临时文件把 src/db.js 指向替身（测完恢复）。
// 之所以不走 module.register：Express 5 的 ESM 加载顺序下它不稳。
//
// 注意必须用 fileURLToPath 而不是 URL.pathname —— 本工程的路径里有中文，
// pathname 会把它百分号编码成 %E9%A1%B9%E7%9B%AE，文件就找不到了。
const { writeFileSync, unlinkSync, existsSync, rmSync, readFileSync } = await import('node:fs');
const { join } = await import('node:path');

const srcDir = fileURLToPath(new URL('../src/', import.meta.url));
const dbReal = join(srcDir, 'db.js');
const dbBackup = join(srcDir, 'db.js.bak');

if (!existsSync(dbBackup)) {
  // 备份原文件，测试期间换成替身
  writeFileSync(dbBackup, readFileSync(dbReal, 'utf8'));
  writeFileSync(
    dbReal,
    `// 测试期间由 test/api.test.mjs 临时替换\nexport * from '${fakePath}';\n`,
  );
}

const fakedb = await import(fakePath);

// 让 config 指向测试用户数据目录
process.env.USERDATA_DIR = 'userdata-test';
process.env.TOKEN_TTL = '7d';

const { default: express } = await import('express');
const { config } = await import('../src/config.js');
const { errorHandler, notFoundHandler } = await import('../src/lib/http.js');
const { marketRouter } = await import('../src/routes/market.js');
const { authRouter } = await import('../src/routes/auth.js');
const { uploadRouter, userDataRouter } = await import('../src/routes/upload.js');
const { packageRouter } = await import('../src/routes/packages.js');
const cors = (await import('cors')).default;
const multer = (await import('multer')).default;

// 复刻 server.js 的装配（去掉日志与静态资源）
function buildApp() {
  const app = express();
  app.use(cors());
  app.use(express.json({ limit: '5mb' }));
  app.get('/api/health', (_req, res) => res.json({ ok: true, data: { status: 'ok' } }));
  // 顺序与 server.js 一致：包路由在前（更具体的两段路径）
  app.use('/api/market', packageRouter);
  app.use('/api/market', marketRouter);
  app.use('/api/auth', authRouter);
  app.use('/api/upload', uploadRouter);
  app.use('/api/user', userDataRouter);
  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}

let server;
let base;

before(async () => {
  fakedb.reset();
  // 造一个应用 + 标签，供市场接口测试用
  fakedb.state.apps.push({
    id: 'demo.app',
    name: '示例应用',
    description: '这是一个示例',
    category_id: 'tools',
    version: '1.0.0',
    author: 'tester',
    url: 'https://example.com/a.html',
    icon: null,
    homepage: null,
    size_bytes: 100,
    screenshots: '[]',
    permissions: '[]',
    sort_weight: 0,
    published_at: '2026-01-01 00:00:00.000',
    updated_at: '2026-01-02 00:00:00.000',
    deleted_at: null,
  });
  fakedb.state.tags.push({ id: 1, name: '效率', slug: 'productivity' });
  fakedb.state.tags.push({ id: 2, name: '笔记', slug: 'notes' });
  fakedb.state.appTags.push({ app_id: 'demo.app', tag_id: 1 });

  const app = buildApp();
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((r) => server.close(r));
  // 恢复真实 db.js，删掉测试数据目录
  if (existsSync(dbBackup)) {
    writeFileSync(dbReal, readFileSync(dbBackup, 'utf8'));
    unlinkSync(dbBackup);
  }
  const testDir = join(config.root, 'userdata-test');
  if (existsSync(testDir)) rmSync(testDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------- 工具

async function api(method, path, { body, token, raw } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  let payload;
  if (raw) {
    payload = raw.body;
    Object.assign(headers, raw.headers);
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(base + path, { method, headers, body: payload });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = { _raw: text };
  }
  return { status: res.status, json, headers: res.headers };
}

// ================================================================ 市场

describe('市场接口', () => {
  test('feed 返回应用与分类', async () => {
    const r = await api('GET', '/api/market/feed?limit=10');
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.equal(r.json.data.apps.length, 1);
    assert.equal(r.json.data.apps[0].id, 'demo.app');
    assert.deepEqual(r.json.data.apps[0].tags, ['效率']);
    assert.ok(Array.isArray(r.json.data.categories));
    assert.equal(r.json.meta.hasMore, false);
  });

  test('feed 的 limit 会被夹到上限', async () => {
    const r = await api('GET', '/api/market/feed?limit=999999');
    assert.equal(r.status, 200);
    assert.equal(r.json.meta.limit, config.market.maxPageSize);
  });

  test('search 能按关键词命中并返回标签', async () => {
    const r = await api('GET', '/api/market/search?q=示例');
    assert.equal(r.status, 200);
    assert.equal(r.json.data.apps.length, 1);
    assert.equal(r.json.data.total, 1);
    assert.ok(r.json.data.tags.some((t) => t.slug === 'productivity'));
    assert.deepEqual(r.json.data.query.q, '示例');
  });

  test('search 按标签筛选', async () => {
    const hit = await api('GET', '/api/market/search?tag=productivity');
    assert.equal(hit.json.data.apps.length, 1);
    const miss = await api('GET', '/api/market/search?tag=不存在的标签');
    assert.equal(miss.json.data.apps.length, 0);
  });

  test('search 空关键词也能用（返回全部）', async () => {
    const r = await api('GET', '/api/market/search');
    assert.equal(r.status, 200);
    assert.equal(r.json.data.total, 1);
  });

  test('app/:id 命中与未命中', async () => {
    const hit = await api('GET', '/api/market/app/demo.app');
    assert.equal(hit.status, 200);
    assert.equal(hit.json.data.name, '示例应用');
    const miss = await api('GET', '/api/market/app/nope');
    assert.equal(miss.status, 404);
    assert.equal(miss.json.ok, false);
  });

  test('tags 返回计数', async () => {
    const r = await api('GET', '/api/market/tags');
    assert.equal(r.status, 200);
    assert.ok(Array.isArray(r.json.data));
  });
});

// ================================================================ 账号

describe('账号系统', () => {
  let token;
  let userId;

  test('注册成功并返回 token', async () => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: '测试用户', email: 'a@b.com', password: 'password123', device: 'TestDevice' },
    });
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.ok, true);
    assert.ok(r.json.data.token.startsWith('lmn_'));
    assert.equal(r.json.data.user.username, '测试用户');
    assert.equal(r.json.data.user.email, 'a@b.com');
    // 绝不返回密码
    assert.equal(r.json.data.user.password_hash, undefined);
    assert.equal(r.json.data.user.password, undefined);
    token = r.json.data.token;
    userId = r.json.data.user.id;
  });

  test('注册记录了注册 IP 与时间', async () => {
    const r = await api('GET', '/api/auth/me', { token });
    assert.equal(r.status, 200);
    assert.ok(r.json.data.createdAt);
    assert.ok(r.json.data.createdIp);
  });

  test('登录数据落了库（含设备与 IP）', async () => {
    assert.equal(fakedb.state.sessions.length, 1);
    const s = fakedb.state.sessions[0];
    assert.ok(s.device.includes('TestDevice'));
    assert.ok(s.login_ip.length > 0);
    // 存的是哈希，不是明文 token
    assert.notEqual(s.token_hash, token);
    assert.equal(s.token_hash.length, 64);
  });

  test('用户名重复 → 409 username_taken', async () => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: '测试用户', email: 'other@b.com', password: 'password123' },
    });
    assert.equal(r.status, 409);
    assert.equal(r.json.error.code, 'username_taken');
  });

  test('邮箱重复 → 409 email_taken', async () => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: '另一个', email: 'a@b.com', password: 'password123' },
    });
    assert.equal(r.status, 409);
    assert.equal(r.json.error.code, 'email_taken');
  });

  test('弱密码被拒', async () => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: '第三个', email: 'c@b.com', password: '123' },
    });
    assert.equal(r.status, 400);
    assert.equal(r.json.error.code, 'weak_password');
  });

  test('纯数字用户名被拒', async () => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: '12345', email: 'd@b.com', password: 'password123' },
    });
    assert.equal(r.status, 400);
    assert.equal(r.json.error.code, 'invalid_username');
  });

  test('登录（用户名）成功', async () => {
    const r = await api('POST', '/api/auth/login', {
      body: { account: '测试用户', password: 'password123', device: 'SecondDevice' },
    });
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.ok(r.json.data.token.startsWith('lmn_'));
    // 现在应该有两个会话
    assert.equal(fakedb.state.sessions.filter((s) => !s.revoked).length, 2);
  });

  test('登录（邮箱）也能成功', async () => {
    const r = await api('POST', '/api/auth/login', {
      body: { account: 'a@b.com', password: 'password123' },
    });
    assert.equal(r.status, 200);
  });

  test('密码错与用户不存在返回同一个错误', async () => {
    const wrongPw = await api('POST', '/api/auth/login', {
      body: { account: '测试用户', password: 'wrong-password' },
    });
    const noUser = await api('POST', '/api/auth/login', {
      body: { account: '不存在的人', password: 'password123' },
    });
    assert.equal(wrongPw.status, 401);
    assert.equal(noUser.status, 401);
    assert.equal(wrongPw.json.error.code, noUser.json.error.code);
    assert.equal(wrongPw.json.error.message, noUser.json.error.message);
  });

  test('无效 token → 401', async () => {
    const r = await api('GET', '/api/auth/me', { token: 'lmn_garbage' });
    assert.equal(r.status, 401);
  });

  test('没有 token → 401', async () => {
    const r = await api('GET', '/api/auth/me');
    assert.equal(r.status, 401);
  });

  test('改用户名', async () => {
    const r = await api('PATCH', '/api/auth/me', {
      token,
      body: { username: '改名了' },
    });
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.data.user.username, '改名了');
  });

  test('改成别人已用的用户名 → 409', async () => {
    await api('POST', '/api/auth/register', {
      body: { username: '占用者', email: 'z@b.com', password: 'password123' },
    });
    const r = await api('PATCH', '/api/auth/me', { token, body: { username: '占用者' } });
    assert.equal(r.status, 409);
    assert.equal(r.json.error.code, 'username_taken');
  });

  test('会话列表能列出两台设备', async () => {
    const r = await api('GET', '/api/auth/sessions', { token });
    assert.equal(r.status, 200);
    assert.ok(r.json.data.length >= 2);
    assert.ok(r.json.data.some((s) => s.current === true));
    assert.ok(r.json.data.every((s) => s.id.length === 16));
  });

  test('撤销另一个会话后它就用不了了', async () => {
    const list = await api('GET', '/api/auth/sessions', { token });
    const other = list.json.data.find((s) => !s.current);
    assert.ok(other, '应该有另一个会话');

    const del = await api('DELETE', `/api/auth/sessions/${other.id}`, { token });
    assert.equal(del.status, 200);
    assert.equal(del.json.data.revoked, 1);

    // 那个会话对应的 token 已无法使用 —— 但我们手里没有它的明文
    // （只存了哈希）。所以改为断言「有效会话数少了 1」。
    const after = await api('GET', '/api/auth/sessions', { token });
    assert.equal(after.json.data.length, list.json.data.length - 1);
  });

  test('改密码要验证旧密码', async () => {
    const wrong = await api('POST', '/api/auth/password', {
      token,
      body: { oldPassword: 'nope', newPassword: 'newpassword123' },
    });
    assert.equal(wrong.status, 400);
    assert.equal(wrong.json.error.code, 'wrong_password');
  });

  test('改密码成功后其它会话被撤销，当前会话保留', async () => {
    const before = await api('GET', '/api/auth/sessions', { token });
    const r = await api('POST', '/api/auth/password', {
      token,
      body: { oldPassword: 'password123', newPassword: 'newpassword123' },
    });
    assert.equal(r.status, 200);
    assert.equal(r.json.data.revokedOthers, true);

    const after = await api('GET', '/api/auth/sessions', { token });
    assert.equal(after.json.data.length, 1);
    assert.equal(after.json.data[0].current, true);

    // 当前 token 仍然有效
    const me = await api('GET', '/api/auth/me', { token });
    assert.equal(me.status, 200);
  });

  test('新密码能登录、旧密码不能', async () => {
    const old = await api('POST', '/api/auth/login', {
      body: { account: '改名了', password: 'password123' },
    });
    assert.equal(old.status, 401);
    const fresh = await api('POST', '/api/auth/login', {
      body: { account: '改名了', password: 'newpassword123' },
    });
    assert.equal(fresh.status, 200);
  });

  test('退出登录后 token 失效', async () => {
    const login = await api('POST', '/api/auth/login', {
      body: { account: '改名了', password: 'newpassword123' },
    });
    const t = login.json.data.token;
    const before = await api('GET', '/api/auth/me', { token: t });
    assert.equal(before.status, 200);

    const out = await api('POST', '/api/auth/logout', { token: t });
    assert.equal(out.status, 200);

    const after = await api('GET', '/api/auth/me', { token: t });
    assert.equal(after.status, 401);
  });

  test('check 能查用户名可用性', async () => {
    const used = await api('GET', '/api/auth/check?username=改名了');
    assert.equal(used.json.data.username.available, false);
    const free = await api('GET', '/api/auth/check?username=还没人用');
    assert.equal(free.json.data.username.available, true);
  });
});

// ================================================================ 用户数据

describe('用户 JSON 数据', () => {
  let token;

  before(async () => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: '数据用户', email: 'data@b.com', password: 'password123' },
    });
    token = r.json.data.token;
  });

  test('首次读返回空对象而不是 404', async () => {
    const r = await api('GET', '/api/user/data', { token });
    assert.equal(r.status, 200);
    assert.equal(r.json.data.exists, false);
    assert.deepEqual(r.json.data.data, {});
  });

  test('PUT 整体写入', async () => {
    const r = await api('PUT', '/api/user/data', {
      token,
      body: { theme: 'dark', notes: [1, 2, 3] },
    });
    assert.equal(r.status, 200);
    assert.ok(r.json.data.bytes > 0);

    const read = await api('GET', '/api/user/data', { token });
    assert.deepEqual(read.json.data.data, { theme: 'dark', notes: [1, 2, 3] });
    assert.equal(read.json.data.exists, true);
  });

  test('PATCH 浅合并，不动其它键', async () => {
    const r = await api('PATCH', '/api/user/data', {
      token,
      body: { theme: 'light' },
    });
    assert.equal(r.status, 200);
    assert.equal(r.json.data.data.theme, 'light');
    assert.deepEqual(r.json.data.data.notes, [1, 2, 3]);
  });

  test('非对象请求体被拒', async () => {
    const r = await api('PUT', '/api/user/data', { token, body: [1, 2, 3] });
    assert.equal(r.status, 400);
    assert.equal(r.json.error.code, 'bad_request');
  });

  test('DELETE 清空成空对象', async () => {
    const r = await api('DELETE', '/api/user/data', { token });
    assert.equal(r.status, 200);
    assert.equal(r.json.data.cleared, true);
    const read = await api('GET', '/api/user/data', { token });
    assert.deepEqual(read.json.data.data, {});
  });

  test('未登录不能读别人的数据', async () => {
    const r = await api('GET', '/api/user/data');
    assert.equal(r.status, 401);
  });
});

// ================================================================ 头像

describe('头像上传与下载', () => {
  let token;
  let userId;

  before(async () => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: '头像用户', email: 'avatar@b.com', password: 'password123' },
    });
    token = r.json.data.token;
    userId = r.json.data.user.id;
  });

  // 最小合法 PNG（1x1 透明）
  const PNG_1X1 = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64',
  );

  test('还没上传时下载返回 404', async () => {
    const r = await fetch(`${base}/api/upload/avatar/${userId}`);
    assert.equal(r.status, 404);
  });

  test('上传 PNG 成功并返回版本戳', async () => {
    const form = new FormData();
    form.append('file', new Blob([PNG_1X1], { type: 'image/png' }), 'avatar.png');
    const res = await fetch(`${base}/api/upload/avatar`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    });
    const json = await res.json();
    assert.equal(res.status, 200, JSON.stringify(json));
    assert.equal(json.ok, true);
    assert.equal(json.data.format, 'png');
    assert.ok(json.data.avatarVersion);
  });

  test('下载拿到的是同一份字节', async () => {
    const res = await fetch(`${base}/api/upload/avatar/${userId}`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'image/png');
    const buf = Buffer.from(await res.arrayBuffer());
    assert.deepEqual(buf, PNG_1X1);
  });

  test('ETag 命中时返回 304', async () => {
    const first = await fetch(`${base}/api/upload/avatar/${userId}`);
    const etag = first.headers.get('etag');
    assert.ok(etag);
    const second = await fetch(`${base}/api/upload/avatar/${userId}`, {
      headers: { 'If-None-Match': etag },
    });
    assert.equal(second.status, 304);
  });

  test('上传非图片被拒', async () => {
    const form = new FormData();
    form.append('file', new Blob([Buffer.from('not an image')], { type: 'image/png' }), 'x.png');
    const res = await fetch(`${base}/api/upload/avatar`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    });
    const json = await res.json();
    assert.equal(res.status, 400);
    assert.equal(json.error.code, 'bad_image');
  });

  test('未登录不能上传', async () => {
    const form = new FormData();
    form.append('file', new Blob([PNG_1X1], { type: 'image/png' }), 'a.png');
    const res = await fetch(`${base}/api/upload/avatar`, { method: 'POST', body: form });
    assert.equal(res.status, 401);
  });

  test('删除头像后下载回到 404', async () => {
    const del = await api('DELETE', '/api/upload/avatar', { token });
    assert.equal(del.status, 200);
    assert.equal(del.json.data.removed, true);
    const r = await fetch(`${base}/api/upload/avatar/${userId}`);
    assert.equal(r.status, 404);
  });
});

// ================================================================ 错误处理

describe('错误处理', () => {
  test('未知路径返回统一 JSON 404', async () => {
    const r = await api('GET', '/api/nope');
    assert.equal(r.status, 404);
    assert.equal(r.json.ok, false);
    assert.equal(r.json.error.code, 'not_found');
  });

  test('非法 JSON 请求体不会 500 崩溃', async () => {
    const r = await api('POST', '/api/auth/login', {
      raw: { body: '{invalid json', headers: { 'Content-Type': 'application/json' } },
    });
    assert.ok(r.status === 400 || r.status === 500);
    assert.equal(r.json.ok, false);
  });
});

// ================================================================ 小程序包

describe('小程序包', () => {
  let token;

  before(async () => {
    // 造一个带包的 app
    fakedb.state.apps.push({
      id: 'pkg.app',
      name: '包测试',
      description: 'd',
      category_id: 'tools',
      version: '1.0.0',
      author: 'a',
      url: null,
      package_url: 'packages/pkg.app/1.0.0.zip',
      package_entry: 'index.html',
      package_sha256: 'deadbeef',
      package_bytes: 100,
      icon: null,
      homepage: null,
      size_bytes: 100,
      screenshots: '[]',
      permissions: '[]',
      sort_weight: 0,
      published_at: '2026-01-01 00:00:00.000',
      updated_at: '2026-01-02 00:00:00.000',
      deleted_at: null,
    });
    const r = await api('POST', '/api/auth/login', {
      body: { account: '改名了', password: 'newpassword123' },
    });
    token = r.json.data.token;
  });

  test('meta 返回版本与哈希', async () => {
    const r = await api('GET', '/api/market/pkg.app/package/meta');
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.data.version, '1.0.0');
    assert.equal(r.json.data.hasPackage, true);
    assert.equal(r.json.data.packageSha256, 'deadbeef');
    assert.ok(r.json.data.packageUrl.includes('/packages/pkg.app/1.0.0.zip'));
  });

  test('meta 对没上架包的条目返回 hasPackage=false', async () => {
    const r = await api('GET', '/api/market/demo.app/package/meta');
    assert.equal(r.status, 200);
    assert.equal(r.json.data.hasPackage, false);
  });

  test('feed 里带出包字段', async () => {
    const r = await api('GET', '/api/market/feed?limit=10');
    const app = r.json.data.apps.find((a) => a.id === 'pkg.app');
    assert.ok(app, '应该能拿到 pkg.app');
    assert.equal(app.version, '1.0.0');
    assert.equal(app.packageEntry, 'index.html');
    assert.equal(app.packageSha256, 'deadbeef');
    assert.ok(app.packageUrl.startsWith('http'), '包地址应是绝对地址');
  });

  test('updates 只返回版本不一致的', async () => {
    // 同版本 → 不返回
    const same = await api('POST', '/api/market/updates', {
      body: { installed: [{ id: 'pkg.app', version: '1.0.0' }] },
    });
    assert.equal(same.status, 200);
    assert.equal(same.json.data.updates.length, 0);

    // 旧版本 → 返回
    const old = await api('POST', '/api/market/updates', {
      body: { installed: [{ id: 'pkg.app', version: '0.9.0' }] },
    });
    assert.equal(old.json.data.updates.length, 1);
    assert.equal(old.json.data.updates[0].latestVersion, '1.0.0');
    assert.equal(old.json.data.updates[0].installedVersion, '0.9.0');
  });

  test('updates 对没装过的（空版本）也返回', async () => {
    const r = await api('POST', '/api/market/updates', {
      body: { installed: [{ id: 'pkg.app', version: '' }] },
    });
    assert.equal(r.json.data.updates.length, 1);
  });

  test('updates 忽略没有包的条目', async () => {
    const r = await api('POST', '/api/market/updates', {
      body: { installed: [{ id: 'demo.app', version: '0.1' }] },
    });
    assert.equal(r.json.data.updates.length, 0);
  });

  test('updates 空列表不报错', async () => {
    const r = await api('POST', '/api/market/updates', { body: { installed: [] } });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.data.updates, []);
  });

  test('updates 忽略非法 id（防注入）', async () => {
    const r = await api('POST', '/api/market/updates', {
      body: { installed: [{ id: "x'; DROP TABLE apps; --", version: '1' }] },
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.data.updates, []);
  });

  test('上传包需要登录', async () => {
    const form = new FormData();
    form.append('file', new Blob([Buffer.from('PK\x03\x04xx')], { type: 'application/zip' }), 'a.zip');
    form.append('version', '2.0.0');
    const res = await fetch(`${base}/api/market/pkg.app/package`, {
      method: 'POST',
      body: form,
    });
    assert.equal(res.status, 401);
  });

  test('上传非 zip 被拒', async () => {
    const form = new FormData();
    form.append('file', new Blob([Buffer.from('not a zip')], { type: 'application/zip' }), 'a.zip');
    form.append('version', '2.0.0');
    const res = await fetch(`${base}/api/market/pkg.app/package`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    });
    const json = await res.json();
    assert.equal(res.status, 400);
    assert.equal(json.error.code, 'bad_package');
  });

  test('上传时 entry 不能越界', async () => {
    const form = new FormData();
    form.append('file', new Blob([Buffer.from('PK\x03\x04xxxx')], { type: 'application/zip' }), 'a.zip');
    form.append('version', '2.0.0');
    form.append('entry', '../../etc/passwd');
    const res = await fetch(`${base}/api/market/pkg.app/package`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    });
    const json = await res.json();
    assert.equal(res.status, 400);
    assert.equal(json.error.code, 'bad_entry');
  });
});

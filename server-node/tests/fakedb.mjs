// test/fakedb.mjs
//
// 内存版数据库替身，用于在不装 MySQL 的环境里测路由层。
//
// 它**只实现**本项目用到的那些 SQL 模式（见每个 if 分支）。
// 这不是一个通用 SQL 引擎 —— 那不值得写。目的是验证
// 「路由 → 鉴权 → 序列化 → 错误处理」这条链，而不是测 MySQL。
//
// 每个分支都对应 server/src 里一处真实查询；改那边记得同步这里。

export const state = {
  users: [],
  sessions: [],
  categories: [],
  apps: [],
  tags: [],
  appTags: [],
  nextUserId: 1,
  nextTagId: 1,
};

export function reset() {
  state.users = [];
  state.sessions = [];
  state.categories = [
    { id: 'tools', name: '工具', sort_order: 10 },
    { id: 'fun', name: '娱乐', sort_order: 20 },
  ];
  state.apps = [];
  state.tags = [];
  state.appTags = [];
  state.nextUserId = 1;
  state.nextTagId = 1;
}

/** GROUP_CONCAT(... SEPARATOR '\u0001') 的等价物 */
function tagNamesOf(appId) {
  const names = state.appTags
    .filter((at) => at.app_id === appId)
    .map((at) => state.tags.find((t) => t.id === at.tag_id)?.name)
    .filter(Boolean)
    .sort();
  return names.length ? names.join('\u0001') : null;
}

/**
 * 按 WHERE 子句里的模式过滤应用。
 *
 * 只实现本项目实际用到的三种过滤：关键词 LIKE、标签存在性、分类。
 * 参数顺序与 src/routes/market.js 里的 push 顺序一致 ——
 * 改那边记得同步这里。
 */
function matchedApps(sql, params) {
  const q = norm(sql);
  let rows = state.apps.filter((a) => !a.deleted_at);
  let i = 0;

  // 关键词：(a.name LIKE ? OR a.description LIKE ? OR a.author LIKE ? OR EXISTS(...t2.name LIKE ?))
  if (/a\.name LIKE \?/.test(q)) {
    const likes = params.slice(i, i + 4).map((p) => String(p).replace(/%/g, ''));
    i += 4;
    const kw = likes[0];
    rows = rows.filter(
      (a) =>
        a.name.includes(kw) ||
        a.description.includes(kw) ||
        a.author.includes(kw) ||
        state.appTags
          .filter((at) => at.app_id === a.id)
          .some((at) => {
            const tag = state.tags.find((t) => t.id === at.tag_id);
            return tag && tag.name.includes(kw);
          }),
    );
  }

  // 标签：EXISTS (... t3.slug = ? OR t3.name = ?)
  if (/t3\.slug = \?/.test(q)) {
    const [slug, name] = params.slice(i, i + 2);
    i += 2;
    rows = rows.filter((a) =>
      state.appTags
        .filter((at) => at.app_id === a.id)
        .some((at) => {
          const tag = state.tags.find((t) => t.id === at.tag_id);
          return tag && (tag.slug === slug || tag.name === name);
        }),
    );
  }

  // 分类
  if (/a\.category_id = \?/.test(q)) {
    const cat = params[i];
    i += 1;
    rows = rows.filter((a) => a.category_id === cat);
  }

  // 游标分页（feed）：参数里会带 sort_weight / updated_at / id
  // 内存替身不做精确游标，直接跳过 —— 测试里没用到翻页。
  return rows;
}

const norm = (s) => String(s).replace(/\s+/g, ' ').trim();

export async function query(sql, params = []) {
  const q = norm(sql);

  if (/FROM users WHERE username = \? LIMIT 1/.test(q)) {
    return state.users.filter((u) => u.username === params[0]).map((u) => ({ id: u.id }));
  }
  if (/FROM users WHERE email = \? LIMIT 1/.test(q)) {
    return state.users.filter((u) => u.email === params[0]).map((u) => ({ id: u.id }));
  }
  if (/FROM users WHERE username = \? AND id <> \?/.test(q)) {
    return state.users
      .filter((u) => u.username === params[0] && u.id !== params[1])
      .map((u) => ({ id: u.id }));
  }
  if (/FROM users WHERE email = \? AND id <> \?/.test(q)) {
    return state.users
      .filter((u) => u.email === params[0] && u.id !== params[1])
      .map((u) => ({ id: u.id }));
  }
  if (/WHERE email = \? OR username = \?/.test(q)) {
    const [email, name] = params;
    return state.users
      .filter((u) => u.email === email || u.username === name)
      .slice(0, 1)
      .map((u) => ({ ...u }));
  }
  if (/FROM users WHERE id = \?/.test(q)) {
    return state.users.filter((u) => u.id === params[0]).map((u) => ({ ...u }));
  }

  // ---- sessions
  if (/FROM login_sessions s JOIN users u/.test(q)) {
    const s = state.sessions.find((x) => x.token_hash === params[0]);
    if (!s) return [];
    const u = state.users.find((x) => x.id === s.user_id);
    if (!u) return [];
    return [{ ...s, username: u.username, status: u.status }];
  }
  if (/FROM login_sessions\s+WHERE user_id = \? AND revoked = 0 AND expires_at > UTC_TIMESTAMP/.test(q)) {
    return state.sessions
      .filter((s) => s.user_id === params[0] && !s.revoked)
      .sort((a, b) => String(a.last_seen_at).localeCompare(String(b.last_seen_at)))
      .map((s) => ({ token_hash: s.token_hash }));
  }
  if (/FROM login_sessions\s+WHERE user_id = \? AND revoked = 0/.test(q)) {
    return state.sessions
      .filter((s) => s.user_id === params[0] && !s.revoked)
      .map((s) => ({ ...s }));
  }

  // ---- market
  //
  // 这里的顺序很重要：/api/market/search 的「标签聚合」查询是
  //   FROM apps a JOIN app_tags ... JOIN tags t ...
  // 它同时匹配 "FROM apps a" 与 "JOIN tags"，所以必须先判它。
  // 之前把 /FROM apps a/ 放前面，导致 search 拿到了应用列表而不是标签，
  // 测试报「tags 里没有 productivity」—— 那是替身的 bug，不是产品的。

  if (/FROM tags t\s+LEFT JOIN app_tags/.test(q)) {
    return state.tags.map((t) => ({
      name: t.name,
      slug: t.slug,
      count: state.appTags.filter((at) => at.tag_id === t.id).length,
    }));
  }

  // search 的标签聚合：FROM apps a JOIN app_tags at ... JOIN tags t ...
  // 注意中间有 ON 子句，所以用 .*? 而不是 \s+ —— 儿 之前写成 \s+JOIN tags ，
  // 结果一次都没匹配上，search 的 tags 永远是空数组。
  if (/FROM apps a\s+JOIN app_tags at\b.*?JOIN tags t\b/.test(q) && /GROUP BY t\.id/.test(q)) {
    return matchedApps(q, params).map((app) => {
      const tagIds = state.appTags
        .filter((at) => at.app_id === app.id)
        .map((at) => at.tag_id);
      return tagIds.map((id) => state.tags.find((t) => t.id === id)).filter(Boolean);
    }).flat()
      // 去重后计数（COUNT(DISTINCT a.id) 的近似：这里每个 app 每条 tag 只出现一次）
      .reduce((acc, tag) => {
        const found = acc.find((x) => x.slug === tag.slug);
        if (found) found.count += 1;
        else acc.push({ name: tag.name, slug: tag.slug, count: 1 });
        return acc;
      }, []);
  }

  if (/FROM categories c/.test(q)) {
    return state.categories.map((c) => ({ ...c, app_count: 0 }));
  }

  // COUNT(*) AS n FROM apps a WHERE ...
  if (/COUNT\(\*\)/.test(q) && /FROM apps a/.test(q)) {
    return [{ n: matchedApps(q, params).length }];
  }

  // 应用列表（feed / search / app/:id）
  // 升级检查：WHERE id IN (...) AND package_url IS NOT NULL
  if (/FROM apps\s+WHERE id IN/.test(q)) {
    const ids = params;
    return state.apps
      .filter((a) => ids.includes(a.id) && !a.deleted_at && a.package_url)
      .map((a) => ({ ...a }));
  }
  // 单条：package/meta 与 package 下载都用 WHERE id = ?
  if (/FROM apps WHERE id = \? AND deleted_at IS NULL/.test(q)) {
    return state.apps.filter((a) => a.id === params[0] && !a.deleted_at).map((a) => ({ ...a }));
  }
  if (/FROM apps a/.test(q)) {
    let rows = matchedApps(q, params);
    // app/:id 的情况：params 里是 id
    if (/WHERE a\.id = \?/.test(q)) {
      rows = rows.filter((a) => a.id === params[0]);
    }
    return rows.map((a) => ({ ...a, tag_names: tagNamesOf(a.id) }));
  }

  if (/^\s*SELECT 1/.test(q)) return [{ 1: 1 }];

  throw new Error(`fakedb: 未实现的查询 → ${q.slice(0, 120)}`);
}

export async function queryOne(sql, params = []) {
  const rows = await query(sql, params);
  return rows.length > 0 ? rows[0] : null;
}

export async function execute(sql, params = []) {
  const q = norm(sql);

  if (/^INSERT INTO users/.test(q)) {
    const [username, email, password_hash, created_ip] = params;
    const user = {
      id: state.nextUserId++,
      username,
      email,
      password_hash,
      avatar_ver: '',
      status: 'active',
      created_at: new Date().toISOString().slice(0, 23).replace('T', ' '),
      created_ip: created_ip ?? '',
      updated_at: new Date().toISOString().slice(0, 23).replace('T', ' '),
    };
    state.users.push(user);
    return { insertId: user.id, affectedRows: 1 };
  }

  if (/^INSERT INTO login_sessions/.test(q)) {
    const [token_hash, user_id, expires_at, login_ip, device] = params;
    const now = new Date().toISOString().slice(0, 23).replace('T', ' ');
    state.sessions.push({
      token_hash,
      user_id,
      created_at: now,
      last_seen_at: now,
      expires_at:
        expires_at instanceof Date
          ? expires_at.toISOString().slice(0, 23).replace('T', ' ')
          : String(expires_at),
      login_ip,
      device,
      revoked: 0,
    });
    return { affectedRows: 1 };
  }

  if (/^UPDATE login_sessions SET last_seen_at/.test(q)) {
    const s = state.sessions.find((x) => x.token_hash === params[0]);
    if (s) s.last_seen_at = new Date().toISOString().slice(0, 23).replace('T', ' ');
    return { affectedRows: s ? 1 : 0 };
  }
  if (/^UPDATE login_sessions SET revoked = 1 WHERE token_hash = \?/.test(q)) {
    const s = state.sessions.find((x) => x.token_hash === params[0]);
    if (s) s.revoked = 1;
    return { affectedRows: s ? 1 : 0 };
  }
  if (/^UPDATE login_sessions SET revoked = 1 WHERE user_id = \? AND token_hash <> \?/.test(q)) {
    let n = 0;
    for (const s of state.sessions) {
      if (s.user_id === params[0] && s.token_hash !== params[1] && !s.revoked) {
        s.revoked = 1;
        n++;
      }
    }
    return { affectedRows: n };
  }
  if (/token_hash LIKE CONCAT/.test(q)) {
    const s = state.sessions.find(
      (x) => x.user_id === params[0] && x.token_hash.startsWith(params[1]) && !x.revoked,
    );
    if (s) s.revoked = 1;
    return { affectedRows: s ? 1 : 0 };
  }
  if (/^UPDATE login_sessions SET revoked = 1 WHERE user_id = \?/.test(q)) {
    let n = 0;
    for (const s of state.sessions) {
      if (s.user_id === params[0] && !s.revoked) {
        s.revoked = 1;
        n++;
      }
    }
    return { affectedRows: n };
  }
  // 前缀匹配撤销：真实 SQL 是 `token_hash LIKE 'handle%'`，
  // 16 位十六进制句柄在实践中唯一，所以一次只会命中一行。
  // 之前这里用 find 是对的，但它被上面更宽的
  // `/^UPDATE login_sessions SET revoked = 1 WHERE user_id = \?/` 分支先吃掉了，
  // 于是把该用户所有会话都撤了 —— 那是替身的分支顺序问题。

  if (/^UPDATE apps\s+SET version = \?/.test(q)) {
    const [version, packageUrl, entry, sha, bytes, id] = params;
    const app = state.apps.find((a) => a.id === id);
    if (!app) return { affectedRows: 0 };
    app.version = version;
    app.package_url = packageUrl;
    app.package_entry = entry;
    app.package_sha256 = sha;
    app.package_bytes = bytes;
    return { affectedRows: 1 };
  }
  if (/^UPDATE users SET avatar_ver = \?/.test(q)) {
    const u = state.users.find((x) => x.id === params[1]);
    if (u) u.avatar_ver = params[0];
    return { affectedRows: u ? 1 : 0 };
  }
  if (/^UPDATE users SET avatar_ver = ''/.test(q)) {
    const u = state.users.find((x) => x.id === params[0]);
    if (u) u.avatar_ver = '';
    return { affectedRows: u ? 1 : 0 };
  }
  if (/^UPDATE users SET password_hash = \?/.test(q)) {
    const u = state.users.find((x) => x.id === params[1]);
    if (u) u.password_hash = params[0];
    return { affectedRows: u ? 1 : 0 };
  }
  if (/^UPDATE users SET/.test(q)) {
    const u = state.users.find((x) => x.id === params[params.length - 1]);
    if (!u) return { affectedRows: 0 };
    const sets = q.slice(q.indexOf('SET') + 3, q.indexOf('WHERE')).split(',');
    sets.forEach((s, i) => {
      const key = s.split('=')[0].trim();
      u[key] = params[i];
    });
    return { affectedRows: 1 };
  }

  if (/^DELETE FROM login_sessions/.test(q)) return { affectedRows: 0 };

  throw new Error(`fakedb: 未实现的写入 → ${q.slice(0, 120)}`);
}

export async function ping() {
  return true;
}

export const pool = { end: async () => {}, getConnection: async () => {
  throw new Error('fakedb: 不支持事务测试');
} };

export async function transaction(fn) {
  return fn(pool);
}

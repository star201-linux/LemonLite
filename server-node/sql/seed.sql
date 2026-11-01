-- server/sql/seed.sql
--
-- 演示数据：分类 + 标签 + 8 个示例应用。
--
-- 全部用 INSERT ... ON DUPLICATE KEY UPDATE，所以 `npm run init -- --seed`
-- 可以反复执行而不会产生重复行（也不会清掉你手工加的数据）。
--
-- 这些应用对应仓库里 docs/apps/ 下的示例小程序 —— 客户端装上后
-- 把服务器地址指向这个服务，主页就能直接拉到它们。

SET NAMES utf8mb4;

-- ---------------------------------------------------------------- 分类

INSERT INTO categories (id, name, sort_order) VALUES
  ('tools', '工具',    10),
  ('life',  '生活',    20),
  ('fun',   '娱乐',    30),
  ('dev',   '开发',    40)
ON DUPLICATE KEY UPDATE name = VALUES(name), sort_order = VALUES(sort_order);

-- ---------------------------------------------------------------- 标签
--
-- 标签是搜索的抓手。命名尽量短（chip 上要放得下）。

INSERT INTO tags (name, slug) VALUES
  ('效率',   'productivity'),
  ('笔记',   'notes'),
  ('天气',   'weather'),
  ('计时',   'timer'),
  ('文本',   'text'),
  ('二维码', 'qrcode'),
  ('配色',   'color'),
  ('游戏',   'game'),
  ('示例',   'demo'),
  ('离线可用', 'offline')
ON DUPLICATE KEY UPDATE name = VALUES(name);

-- ---------------------------------------------------------------- 应用

INSERT INTO apps
  (id, name, description, category_id, version, author,
   package_url, package_entry, package_sha256, package_bytes,
   icon, homepage, screenshots, permissions, sort_weight)
VALUES
  (
    'lemonlite.demo',
    'LemonLite 示例',
    '框架自带的示例小程序：演示 getSystemInfo / getTheme / setTitle / showToast / navigateBack / openUrl / request / storage 全部浏览器基础 API，并通过 --md-* 变量自动继承宿主主题。',
    'dev', '1.0.0', 'LemonLite',
    'packages/lemonlite.demo/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/lemonlite-demo.png',
    'https://star201-linux.github.io',
    18432,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/lemonlite-demo-preview.png'),
    JSON_ARRAY(),
    10
  ),
  (
    'todo.lite',
    '轻记事',
    '极简待办清单。数据存在宿主本地（storage），打开即用，不联网也能记。读到旧版本留下的脏数据会先过一遍清洗，不会因为一个坏字段整页渲染不出来。',
    'tools', '1.0.0', 'LemonLite',
    'packages/todo.lite/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/todo.png',
    NULL,
    12288,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/todo-preview.png'),
    JSON_ARRAY(),
    8
  ),
  (
    'weather.lite',
    '天气卡片',
    '拉 Open-Meteo 的真实天气数据（走宿主请求，不受 CORS 限制）。深色主题或当地夜间时自动切成夜间形态，结果缓存在本地，断网还能看上一次的。',
    'life', '1.0.0', 'LemonLite',
    'packages/weather.lite/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/weather.png',
    NULL,
    16384,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/weather-preview.png'),
    JSON_ARRAY('geolocationCoarse'),
    6
  ),
  (
    'pomodoro.lite',
    '番茄钟',
    '计时按真实经过的秒数推进，不是「每秒减一」—— WebView 在后台会被降频，固定减一的写法会让计时越走越慢。溢出到下一阶段的时间会被带过去。',
    'tools', '1.0.0', 'LemonLite',
    'packages/pomodoro.lite/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/pomodoro.png',
    NULL,
    14336,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/pomodoro-preview.png'),
    JSON_ARRAY(),
    5
  ),
  (
    'markdown.lite',
    'Markdown 预览',
    '自写的渲染器：先转义 HTML 再做格式，所以 <img onerror=…> 这类输入不会被当成标签执行。链接由页面接管交给系统浏览器，不会把 WebView 导航走。',
    'tools', '1.0.0', 'LemonLite',
    'packages/markdown.lite/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/markdown.png',
    NULL,
    20480,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/markdown-preview.png'),
    JSON_ARRAY('clipboard'),
    4
  ),
  (
    'qrcode.lite',
    '二维码生成',
    '自写的 QR 编码器：Byte 模式 / 纠错等级 M / 版本 1–40 自动选择。不引任何 CDN —— 市场服务器可能在内网或离线，引外部脚本等于把「能不能用」押在别人身上。',
    'tools', '1.0.0', 'LemonLite',
    'packages/qrcode.lite/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/qrcode.png',
    NULL,
    26500,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/qrcode-preview.png'),
    JSON_ARRAY('clipboard'),
    3
  ),
  (
    'palette.lite',
    '配色实验室',
    '把 tone 当作 CIELAB 的 L*，二分反解 HSL 的 lightness —— 亮度是按规范来的。页面会实时算出各组的 WCAG 对比度，不达标的标红。',
    'dev', '1.0.0', 'LemonLite',
    'packages/palette.lite/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/palette.png',
    NULL,
    17400,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/palette-preview.png'),
    JSON_ARRAY('clipboard'),
    2
  ),
  (
    'minigame.2048',
    '2048',
    '纯规则层（一维数组 + 四向滑动），方块颜色全部映射到 --md-* 角色，所以跟着宿主主题走。最高分存在宿主存储里，跨局保留。',
    'fun', '1.0.0', 'LemonLite',
    'packages/minigame.2048/1.0.0.zip',
    'index.html',
    NULL,   -- sha256：由 `npm run seed:packages` 生成包后回填
    0,      -- package_bytes：同上
    'https://star201-linux.github.io/icons/2048.png',
    NULL,
    22100,
    JSON_ARRAY('https://star201-linux.github.io/screenshots/2048-preview.png'),
    JSON_ARRAY(),
    1
  )
ON DUPLICATE KEY UPDATE
  name         = VALUES(name),
  description  = VALUES(description),
  category_id  = VALUES(category_id),
  version      = VALUES(version),
  author       = VALUES(author),
  url          = VALUES(url),
  icon         = VALUES(icon),
  homepage     = VALUES(homepage),
  size_bytes   = VALUES(size_bytes),
  screenshots  = VALUES(screenshots),
  permissions  = VALUES(permissions),
  sort_weight  = VALUES(sort_weight);

-- ---------------------------------------------------------------- 应用 ↔ 标签

-- 用 SELECT 拿 tag_id，避免把自增 id 写死
INSERT IGNORE INTO app_tags (app_id, tag_id)
SELECT v.app_id, t.id
  FROM (
    SELECT 'lemonlite.demo' AS app_id, 'demo'         AS slug UNION ALL
    SELECT 'lemonlite.demo',            'productivity'      UNION ALL
    SELECT 'todo.lite',                 'notes'             UNION ALL
    SELECT 'todo.lite',                 'productivity'      UNION ALL
    SELECT 'todo.lite',                 'offline'           UNION ALL
    SELECT 'weather.lite',              'weather'           UNION ALL
    SELECT 'weather.lite',              'offline'           UNION ALL
    SELECT 'pomodoro.lite',             'timer'             UNION ALL
    SELECT 'pomodoro.lite',             'productivity'      UNION ALL
    SELECT 'markdown.lite',             'text'              UNION ALL
    SELECT 'markdown.lite',             'offline'           UNION ALL
    SELECT 'qrcode.lite',               'qrcode'            UNION ALL
    SELECT 'qrcode.lite',               'offline'           UNION ALL
    SELECT 'palette.lite',              'color'             UNION ALL
    SELECT 'minigame.2048',             'game'              UNION ALL
    SELECT 'minigame.2048',             'offline'
  ) AS v
  JOIN tags t ON t.slug = v.slug;

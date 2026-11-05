-- server/sql/seed.sql
--
-- 基础数据：**只有分类与标签，没有任何小程序**。
--
-- 为什么不再灌示例应用：
--   以前 `npm run init -- --seed` 会顺带插入 8 个演示小程序。结果是
--   「服务端刚部署好，市场里就有一堆别人用不到的东西」，而删它们还要
--   一个个下架。现在默认是**空市场**：分类与标签是基础词典（管理员建应用
--   时要选分类），应用本身只能由管理员在 /admin 里添加。
--
-- 全部用 INSERT ... ON DUPLICATE KEY UPDATE，所以可以反复执行，不会重复，
-- 也不会清掉管理员手工添加的数据。

SET NAMES utf8mb4;

-- ---------------------------------------------------------------- 分类
--
-- 分类是客户端的筛选项与管理员建应用时的必选项。默认给四个通用的，
-- 管理员可以在 /admin → 分类标签 里增删。

INSERT INTO categories (id, name, sort_order) VALUES
  ('tools', '工具',    10),
  ('life',  '生活',    20),
  ('fun',   '娱乐',    30),
  ('dev',   '开发',    40)
ON DUPLICATE KEY UPDATE name = VALUES(name), sort_order = VALUES(sort_order);

-- ---------------------------------------------------------------- 标签
--
-- 标签是搜索的抓手，命名尽量短（chip 上要放得下）。
-- 这里只放通用标签；具体某个应用用什么标签，由管理员在应用编辑里勾选。

INSERT INTO tags (name, slug) VALUES
  ('效率',     'productivity'),
  ('笔记',     'notes'),
  ('天气',     'weather'),
  ('计时',     'timer'),
  ('文本',     'text'),
  ('二维码',   'qrcode'),
  ('配色',     'color'),
  ('游戏',     'game'),
  ('离线可用', 'offline')
ON DUPLICATE KEY UPDATE name = VALUES(name);

-- 说明：apps / app_tags 两张表**故意留空**。
-- 默认没有任何小程序，管理员在 /admin 里新建应用并上传 zip 后才会出现。

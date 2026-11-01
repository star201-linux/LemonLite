-- server/sql/schema.sql
--
-- LemonLite 服务端数据模型（MySQL 8.0+）。
--
-- 由 `npm run init`（src/init.js）执行，**不是**手工跑。
-- init.js 会先建库（如果不存在）再切过去执行本文件，
-- 所以这里不要写 CREATE DATABASE / USE。
--
-- 0.4 起账号相关的表**只有两张**：
--   users          —— 用户信息（含注册时间、注册 IP）
--   login_sessions —— 登录数据（token、登录时间、设备、登录 IP）
-- 邮箱验证码一张（email_codes），市场数据另有三张（categories / apps / tags + app_tags）。
--
-- 为什么登录状态要落库而不是纯 JWT：
--   纯 JWT 是「自证」的 —— 签出去就没法收回。用户点了「退出所有设备」、
--   或者 token 被偷了，服务端只能干等到过期。落到 login_sessions 之后，
--   每次请求都能查一次「这个 token 还在不在有效列表里」，可以立刻撤销。
--
-- 用户数据（JSON + 头像）**不入库**，放在磁盘 userdata/<id>/ 下：
--   userdata/<id>/data.json    用户私有 JSON（小程序/客户端自己的数据）
--   userdata/<id>/avatar.png   头像（固定文件名，覆盖式更新）
--   理由：这类东西是「一整块不透明数据」，塞进 MySQL 只会让每次读写
--   都变成「读一行 → 解析 JSON → 改 → 再序列化」。放磁盘则是原子的文件替换，
--   而且用户要备份/迁移时直接拷目录就行。

SET NAMES utf8mb4;

-- ============================================================ 1. 用户信息

CREATE TABLE IF NOT EXISTS users (
  -- 数据库自增 id，对外也用它（同时是 userdata/<id>/ 的目录名）
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,

  -- 用户名：注册时起，可以随时改。唯一。
  -- 排序规则是 utf8mb4_0900_ai_ci（大小写不敏感），所以 "Alice" 与 "alice"
  -- 会被判为重复 —— 这是刻意的：用户不会因为大小写不同就认成两个账号。
  username      VARCHAR(32)     NOT NULL,

  -- 邮箱：登录用，唯一。
  email         VARCHAR(255)    NOT NULL,

  -- 密码：只存 bcrypt hash。
  -- **永远不存明文，永远不在任何接口里返回这个字段**
  password_hash VARCHAR(100)    NOT NULL,

  -- 头像：固定放在 userdata/<id>/avatar.png，所以这里只存一个版本戳
  -- （上传时写入时间戳），客户端拿它做缓存键：变了就重新下载。
  -- 空串表示还没上传过头像，客户端用用户名首字画占位图。
  avatar_ver    VARCHAR(32)     NOT NULL DEFAULT '',

  -- 账号状态：disabled 用于封禁，登录与鉴权都直接拒绝
  status        ENUM('active','disabled') NOT NULL DEFAULT 'active',

  -- 注册时间 / 注册 IP（需求明确要求的两个字段）
  -- IPv6 最长 45 字符，VARCHAR(45) 够用；用字符串而不是 INT 是因为
  -- 将来可能记 IPv6 或经过代理的真实 IP。
  created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  created_ip    VARCHAR(45)     NOT NULL DEFAULT '',

  updated_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                                ON UPDATE CURRENT_TIMESTAMP(3),

  PRIMARY KEY (id),
  UNIQUE KEY uk_users_username (username),
  UNIQUE KEY uk_users_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ============================================================ 2. 登录数据

-- 一次登录 = 一行。token 就是这里的主键。
--
-- 为什么用 token 做主键而不是自增 id：
--   每一次鉴权都要按 token 查（`WHERE token_hash = ?`），
--   主键查询是唯一能做到「一次 B 树查找」的方式。
--
-- ⚠ 存的是 token 的 **SHA-256**，不是 token 明文。
--   数据库被拖走时，明文 token 等于把所有人的登录态直接送出去；
--   哈希之后攻击者还得反过来猜（而 token 是 32 字节随机串，猜不出来）。
--   校验时对收到的 token 做同样的哈希再比对即可 —— 不需要盐，
--   因为输入本身就是高熵随机值，彩虹表在这里没有意义。
CREATE TABLE IF NOT EXISTS login_sessions (
  token_hash    CHAR(64)        NOT NULL,          -- SHA-256 十六进制
  user_id       BIGINT UNSIGNED NOT NULL,

  -- 登录时间（这一次会话的建立时间 / 最近活跃时间）
  created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  last_seen_at  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

  -- 过期时间：客户端拿到的 JWT 也带同样的 exp，两边一致。
  -- 落库是为了「到期清理」与「提前撤销」都能一句话做到。
  expires_at    DATETIME(3)     NOT NULL,

  -- 登录 IP 与设备标识。设备由客户端上报（Android 用
  --「品牌 型号 · Android 版本」这种可读串），不做严格校验 ——
  -- 它只用于「我的登录设备列表」展示与让人自己识别异常登录。
  login_ip      VARCHAR(45)     NOT NULL DEFAULT '',
  device        VARCHAR(128)    NOT NULL DEFAULT '',

  -- 主动撤销（退出登录 / 退出所有设备）时置 1。
  -- 不物理删行：登录记录本身就是审计线索，删了就查不到「谁在什么时候登过」。
  revoked       TINYINT(1)      NOT NULL DEFAULT 0,

  PRIMARY KEY (token_hash),
  -- 「查这个用户的所有会话」按 user + 时间倒序
  KEY idx_sessions_user (user_id, created_at),
  -- 过期清理：`DELETE FROM login_sessions WHERE expires_at < NOW()`
  KEY idx_sessions_expiry (expires_at),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id)
    REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ============================================================ 3. 邮箱验证码

-- 注册要过邮箱验证码，这张表就是「谁在什么时候跟我要过验证码」。
--
-- 几个刻意的设计：
--   * 存 **SHA-256(email|purpose|code)** 而不是验证码明文。
--     库里有一列 6 位数字会比想象中危险：泄露一次就能拿去撞所有还没用掉的码。
--     加 email/purpose 进哈希是为了让「同一个码发给不同人」不会撞出同一行哈希。
--   * 不物理删行，靠 consumed / expires_at 标记，顺带留下审计线索；
--     `npm run prune` 会清掉过期一天以上的记录。
--   * 带 ip 列：同一台机器刷验证码是常见的滥用手法，没有它就没法限流。
CREATE TABLE IF NOT EXISTS email_codes (
  id         BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
  email      VARCHAR(255)     NOT NULL,
  -- 用途：register / reset（后者留给「邮箱重置密码」，表结构先留好）
  purpose    VARCHAR(16)      NOT NULL DEFAULT 'register',
  code_hash  CHAR(64)         NOT NULL,
  ip         VARCHAR(45)      NOT NULL DEFAULT '',
  -- 已输错的次数：超过上限就作废，必须重新获取
  attempts   TINYINT UNSIGNED NOT NULL DEFAULT 0,
  consumed   TINYINT(1)       NOT NULL DEFAULT 0,
  created_at DATETIME(3)      NOT NULL,
  expires_at DATETIME(3)      NOT NULL,
  PRIMARY KEY (id),
  -- 「取这个邮箱最近一条验证码」：验证与冷却检查都走它
  KEY idx_codes_email (email, purpose, created_at),
  -- 按 IP 限流
  KEY idx_codes_ip (ip, created_at),
  -- 过期清理
  KEY idx_codes_expiry (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ============================================================ 3. 应用市场

-- 分类（主页/搜索的筛选项）
CREATE TABLE IF NOT EXISTS categories (
  id         VARCHAR(32)  NOT NULL,
  name       VARCHAR(64)  NOT NULL,
  sort_order INT          NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 应用主表
--
-- 与客户端 index.json 的字段一一对应，但多了两处服务端才有的东西：
--   * sort_weight  —— 人工置顶（默认 0，越大越靠前）
--   * deleted_at   —— 软删除
CREATE TABLE IF NOT EXISTS apps (
  id           VARCHAR(64)  NOT NULL,          -- 稳定 id，同时是小程序 storage 命名空间
  name         VARCHAR(128) NOT NULL,
  description  TEXT         NOT NULL,
  category_id  VARCHAR(32)      NULL,
  version      VARCHAR(32)  NOT NULL DEFAULT '1.0.0',
  author       VARCHAR(128) NOT NULL DEFAULT '',
  -- ---------------------------------------------------------------- 包
  --
  -- 0.6 起小程序是**下载到本机再打开的 zip 包**，不再是远程网页。
  --
  -- package_url 指向一个 zip：客户端下载 → 校验 sha256 → 解压到
  --   <应用私有目录>/miniapps/<id>/<version>/
  -- 然后 WebView 用 file:// 打开其中的 index.html。
  --
  -- 为什么不再用远程 url：
  --   * 断网就用不了；
  --   * 每次打开都要重新拉页面，慢；
  --   * 没法做「版本升级」——远程页面永远是服务端当前那份，
  --     用户没法知道「我装的是哪一版」，也没法回滚。
  --
  -- entry 是包内入口文件的相对路径（默认 index.html）。
  package_url  VARCHAR(1024)    NULL,           -- NULL = 还没上架包（不可打开）
  package_entry VARCHAR(255)    NOT NULL DEFAULT 'index.html',
  -- 包的 SHA-256（十六进制）。客户端下载后必须校验 —— 这是唯一的
  -- 完整性保证：解压前先确认字节没错，避免半个包被解到磁盘上。
  package_sha256 CHAR(64)       NULL,
  -- 包体积（字节），客户端用它显示下载进度
  package_bytes BIGINT UNSIGNED NOT NULL DEFAULT 0,

  icon         VARCHAR(1024)    NULL,
  homepage     VARCHAR(1024)    NULL,
  screenshots  JSON             NULL,           -- string[]
  permissions  JSON             NOT NULL,       -- string[]，受控资源 id

  -- 排序用：主页推荐按「更新时间倒序」，这里再加一个权重，
  -- 让运营能把某个应用提到最前面而不必改它的 updated_at（那是给用户看的）
  sort_weight  INT          NOT NULL DEFAULT 0,

  published_at DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at   DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                            ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at   DATETIME(3)      NULL,

  PRIMARY KEY (id),
  -- 主页推荐接口的排序键：(sort_weight DESC, updated_at DESC, id)
  -- 这个复合索引让「按权重+时间分页」走索引而不是 filesort
  KEY idx_apps_feed (deleted_at, sort_weight, updated_at, id),
  KEY idx_apps_category (category_id),
  -- 包地址只取前 255 字符建索引：utf8mb4 下 VARCHAR(1024) 全长索引
  -- 是 4096 字节，超过 InnoDB 的 3072 字节上限，建表会直接失败。
  -- 前缀索引对「按包地址查」这种场景完全够用。
  KEY idx_apps_package (package_url(255)),
  CONSTRAINT fk_apps_category FOREIGN KEY (category_id)
    REFERENCES categories (id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 标签
--
-- 搜索接口要「返回命中的标签」，所以标签是独立表而不是 apps 里的 JSON 数组：
--   * 需要按标签反查应用（JOIN 比 JSON_CONTAINS 快，也能走索引）
--   * 需要统计「每个标签下有多少应用」（给搜索页做筛选项）
CREATE TABLE IF NOT EXISTS tags (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name       VARCHAR(32)  NOT NULL,   -- 展示名，如「效率」
  slug       VARCHAR(32)  NOT NULL,   -- 稳定标识，如 efficiency（URL / API 用）
  PRIMARY KEY (id),
  UNIQUE KEY uk_tags_slug (slug),
  UNIQUE KEY uk_tags_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS app_tags (
  app_id VARCHAR(64) NOT NULL,
  tag_id INT UNSIGNED NOT NULL,
  PRIMARY KEY (app_id, tag_id),
  KEY idx_app_tags_tag (tag_id),
  CONSTRAINT fk_app_tags_app FOREIGN KEY (app_id)
    REFERENCES apps (id) ON DELETE CASCADE,
  CONSTRAINT fk_app_tags_tag FOREIGN KEY (tag_id)
    REFERENCES tags (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ============================================================ 4. 管理账号

-- 面板账号和普通用户（users）**完全分开**：
--   * 普通用户是市场里的「消费者」，管理账号是运维身份；
--   * 混在一张表里意味着任何一个注册成功的用户都可能被提权成管理员，
--     而这里出一次 bug 就是「整台服务器」级别的。
--
-- 口令只存 bcrypt hash。首次部署时表是空的，/admin 会让访问者**自己建**
-- 第一个管理员账号（admin 组），之后只能由已有管理员新增管理员。
-- 这条链路唯一的空窗期是「部署完还没建号」的那几分钟 ——
-- 公网部署建议同时设 ADMIN_SETUP_TOKEN，建号时必须填那个口令。
CREATE TABLE IF NOT EXISTS admin_users (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  username      VARCHAR(32)     NOT NULL,
  password_hash VARCHAR(100)    NOT NULL,
  -- 组：现在只有 admin（全权）。
  -- 用 VARCHAR 而不是 ENUM，是为了将来加只读/运营角色时不用 ALTER 表；
  -- 合法值由代码校验（ROLE_ADMIN）。
  role          VARCHAR(16)     NOT NULL DEFAULT 'admin',
  status        ENUM('active','disabled') NOT NULL DEFAULT 'active',
  created_at    DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  created_ip    VARCHAR(45)     NOT NULL DEFAULT '',
  last_login_at DATETIME(3)     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_admin_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- ============================================================ 5. 应用 ↔ 分类

-- 一个应用可以挂在多个分类下。
--
-- apps.category_id 保留为「主分类」：客户端详情页只认识一个分类字段，
-- 主页的分类 chip 也按它兜底。真正的归类关系在这张表里。
-- 两个地方都要维护，写入时由 replaceAppCategories() 一次做完。
CREATE TABLE IF NOT EXISTS app_categories (
  app_id      VARCHAR(64) NOT NULL,
  category_id VARCHAR(32) NOT NULL,
  PRIMARY KEY (app_id, category_id),
  KEY idx_app_categories_cat (category_id),
  CONSTRAINT fk_app_categories_app FOREIGN KEY (app_id)
    REFERENCES apps (id) ON DELETE CASCADE,
  CONSTRAINT fk_app_categories_cat FOREIGN KEY (category_id)
    REFERENCES categories (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

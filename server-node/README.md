# LemonLite 服务端（Node.js 版）

市场推荐 + 搜索 + 账号系统 + 用户数据。Node.js + Express + MySQL 8。

## 快速开始

```bash
cd server
cp .env.example .env        # 改掉 DB_PASSWORD
npm install
npm run init -- --seed      # 建库建表 + 基础分类/标签（**不含任何小程序**）
npm start
```

默认市场是**空的**：没有任何预置小程序。打开管理面板 `/admin`
（第一次访问时创建管理员账号），在「应用」页新建应用、上传 zip 包与图标，
客户端主页才会出现它。没有包的应用在 App 里会显示「暂不可用」。

跑起来之后：

```
本机   http://127.0.0.1:3000
局域网 http://<本机IP>:3000
```

在 App 的「设置 →（连点 8 次版本号）→ 开发者选项 → 自定义服务器地址」里填这个地址。

验证：

```bash
curl http://127.0.0.1:3000/api/health
curl 'http://127.0.0.1:3000/api/market/feed?limit=3'
npm test                    # 邮件 / SMTP / 验证码等单元测试，不需要 MySQL
node --test tests/api.test.mjs   # 路由层端到端测试（内存数据库替身）
```

## init 脚本做什么

`npm run init` 做三件事，**幂等**（可以反复跑，不会清数据）：

1. 建库 `lemonlite`（不存在时）
2. 执行 `sql/schema.sql` 建表（`CREATE TABLE IF NOT EXISTS`）
3. 可选 `--seed` 灌基础分类与标签（`INSERT ... ON DUPLICATE KEY UPDATE`）。
   **不会插入任何小程序** —— 默认市场是空的，应用由管理员在 `/admin` 里添加。

```bash
npm run init              # 只建库建表
npm run init -- --seed    # 顺便灌基础分类 + 标签（没有小程序）
npm run init -- --reset   # ⚠ 删库重建（要输入 DELETE 确认）
```

## 数据模型

**账号只有三张表**（按需求）：

| 表 | 存什么 |
| --- | --- |
| `users` | id（自增）、用户名、邮箱、密码哈希、头像版本戳、状态、**注册时间**、**注册 IP** |
| `login_sessions` | token 哈希（主键）、用户 id、**登录时间**、最近活跃、过期时间、**登录 IP**、**设备**、是否已撤销 |
| `email_codes` | 邮箱、用途、**验证码的 SHA-256**（不存明文）、来源 IP、已试错次数、是否已用、签发/过期时间 |

**从旧版本升级**：重跑一次 `npm run init` 就会建出 `email_codes`
（`CREATE TABLE IF NOT EXISTS`，不会动已有数据）。不建表的话注册接口会 500。

`email_codes` 是注册要邮箱验证带来的：没有它就等于「谁都能拿别人的邮箱注册」。
散列而不是明文存的原因很实际 —— 6 位纯数字一旦明文泄露，可以直接拿去撞
所有还没用掉的验证码。

市场三张：`categories` / `apps` / `tags` + `app_tags`（多对多）。

### 为什么登录态要落库

纯 JWT 签出去就收不回。用户点「退出所有设备」、或者手机丢了要踢掉某台，
服务端只能干等到过期。落库之后撤销是一条 UPDATE，立刻生效。

**token 存的是 SHA-256，不是明文。** 数据库被拖走时，明文 token 等于把
所有人的登录态送出去；哈希之后攻击者还得反推 32 字节随机串（不可能）。

### 小程序包

```
packages/<appId>/<version>.zip
```

包由服务端托管（不是让作者自己放 CDN），因为：

* 客户端要校验 SHA-256，哈希必须有一个可信来源；
* 版本号与包必须原子地一起写，否则会出现「版本号变了但包没变」。

`apps` 表里的相关字段：`package_url` / `package_entry` / `package_sha256` /
`package_bytes` / `version`。

### 用户文件不在数据库

```
userdata/<id>/data.json     用户私有 JSON（客户端任意结构）
userdata/<id>/avatar.png    头像（固定文件名，覆盖式更新）
```

头像固定叫 `avatar.png`（需求原文），上传就是覆盖；缓存失效靠
`users.avatar_ver` 这个版本戳。

## 接口

### 市场（不需要登录）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/market/feed?limit=20&cursor=&category=` | 主页推荐，**游标分页** |
| GET | `/api/market/search?q=&tag=&limit=20&offset=0` | 搜索，**返回命中的标签** |
| GET | `/api/market/app/:id` | 单个应用 |
| GET | `/api/market/tags` | 全量标签 + 计数 |
| GET | `/api/market/:appId/package/meta` | 当前上架版本、大小、哈希 |
| GET | `/api/market/:appId/version` | 单个应用的最新版本（**每次打开小程序前查它**） |
| GET | `/api/market/:appId/package?version=` | 下载包（带 ETag） |
| POST | `/api/market/updates` | 批量检查升级（传已装版本列表） |
| GET | `/icons/:appId.(png\|jpg\|webp\|gif)` | 小程序图标（管理员上传，客户端本地缓存） |
| POST | `/api/market/:appId/package` | **上传**包（需登录，multipart） |

`feed` 排序：`sort_weight DESC, updated_at DESC, id ASC`（默认就是按更新时间）。
用游标而不是 offset：offset 分页时列表顶部新增一条会让下一页重复返回旧条目。

`search` 返回的 `tags` 是**命中结果里实际出现过的**标签 —— 点了不会没结果。

### 账号

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/auth/config` | 服务端策略：注册/登录要不要验证码、token 有效期 |
| POST | `/api/auth/email-code` | 发注册验证码（body: `{email}`） |
| POST | `/api/auth/register` | 注册（开启注册验证码时**必须带 `code`**，返回 token） |
| POST | `/api/auth/login-code` | 发**登录**验证码（body: `{account, password}`，先核对密码） |
| POST | `/api/auth/login` | 登录，account 可以是用户名或邮箱；开了登录验证码时要带 `code` |
| GET | `/api/auth/me` | 当前用户 |
| PATCH | `/api/auth/me` | 改用户名 / 邮箱 |
| POST | `/api/auth/password` | 改密码（撤销其它会话） |
| GET | `/api/auth/sessions` | 我的登录设备 |
| DELETE | `/api/auth/sessions/:id` | 踢掉某台设备 |
| POST | `/api/auth/logout` | 退出当前 |
| POST | `/api/auth/logout-all` | 退出所有 |
| GET | `/api/auth/check?username=` | 用户名可用性 |

### 邮件通道（注册验证码）

注册流程是：`POST /api/auth/email-code` 让服务端发一封带 6 位码的邮件 →
用户把码填进注册页 → `POST /api/auth/register` 带上 `code`，服务端核销。

**两个开关**（都在 `.env` 里，客户端启动时读 `/api/auth/config` 跟着变）：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `AUTH_REGISTER_CODE` | `on` | 注册要不要邮箱验证码 |
| `AUTH_LOGIN_CODE` | `off` | 登录要不要再来一次邮箱验证码（两步验证） |

开登录验证码后，登录流程变成：密码先核对 → `POST /api/auth/login-code` 发信 →
`POST /api/auth/login` 同时带密码与 `code`。**发码接口必须先给对密码**，
否则它会变成「知道邮箱就能轰炸对方」的工具，也会被拿来枚举账号。

邮件从哪发出去**由配置决定，不需要改代码**，改完重启即可：

| `MAIL_DRIVER` | 适用场景 | 必填 |
| --- | --- | --- |
| `smtp` | 自建 Postfix、企业邮箱、QQ/163 授权码 | `SMTP_HOST` `SMTP_PORT` `SMTP_USER` `SMTP_PASSWORD` `MAIL_FROM` |
| `resend` | 海外、最省事（免费额度够小站） | `RESEND_API_KEY` `MAIL_FROM` |
| `sendgrid` | 已经在用 Twilio 的 | `SENDGRID_API_KEY` `MAIL_FROM` |
| `aliyun` | 国内送达率最好 | `ALIYUN_DM_*`（AK/SK + 控制台配好的发信地址） |
| `console` | **仅开发**：不发信，把码打到服务端日志 | — |

启动日志会明确打印当前通道与「就绪 / 未就绪」，没配好时注册接口会回 503
并说明缺哪一项，而不是静默失败。

防滥用（都可配）：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `MAIL_CODE_TTL` | 600 | 验证码有效期（秒） |
| `MAIL_CODE_COOLDOWN` | 60 | 同一邮箱两次索要的最小间隔 |
| `MAIL_CODE_MAX_PER_EMAIL` | 10 | 单邮箱每小时上限 |
| `MAIL_CODE_MAX_PER_IP` | 30 | 单 IP 每小时上限 |
| `MAIL_CODE_MAX_ATTEMPTS` | 5 | 同一个码允许输错几次 |

登录验证码与注册验证码共用这张表、这套配额：分开算的话，
「注册 10 封 + 登录 10 封 = 20 封」就成了绕过限流的口子。

细的配置步骤（含 QQ 邮箱授权码、阿里云发信地址怎么开）见
[`../docs/邮件通道配置.md`](../docs/邮件通道配置.md)。

### 头像与用户数据

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/upload/avatar` | 上传头像（multipart，字段名 `file`） |
| GET | `/api/upload/avatar/:id` | 下载头像（公开，支持 ETag / 304） |
| DELETE | `/api/upload/avatar` | 删除头像 |
| GET | `/api/user/data` | 读 data.json（首次返回空对象，不是 404） |
| PUT | `/api/user/data` | 整体替换 |
| PATCH | `/api/user/data` | 浅合并 |
| DELETE | `/api/user/data` | 清空 |

**裁剪在客户端做**（见 `lib/pages/account/avatar_cropper.dart`），
服务端只校验格式（PNG/JPEG/WebP 魔数）与大小（默认 2MB）。

## 响应格式

```json
成功：{ "ok": true,  "data": ..., "meta": { ... } }
失败：{ "ok": false, "error": { "code": "xxx", "message": "人话" } }
```

`ok` 字段是必须的：裸数据无法区分「成功返回 null」和「失败了」，
而 HTTP 状态码在代理/CDN 那层经常被改写。

## 管理面板

```
http://<本机IP>:<端口>/admin
```

**第一次打开时还没有账号**：页面会让你创建第一个管理员（默认 `admin` 组），
建完直接进入面板。之后访问同一个地址就是普通登录 —— 账号存在数据库表
`admin_users` 里，不再是 `.env` 里一个全服共用的口令。

新增管理员只有一个入口：已登录的 admin 在「管理员」页添加（同样是 admin 组）。
可以停用、重置密码、删除账号；停用 / 改密 / 删除都会让那个账号现有的登录立刻失效。
「至少要保留一个可用管理员」由服务端兜住 —— 不会出现把最后一个 admin 删掉之后谁也进不去。

公网部署建议在 `.env` 里设 `ADMIN_SETUP_TOKEN`：设了之后创建第一个账号必须填它，
避免「部署完还没建号」那几分钟被别人抢注。

| 页面 | 能做什么 |
| --- | --- |
| 概览 | 用户 / 应用 / 分类 / 标签 / 管理员 / 活跃会话 / 24h 验证码、当前策略、运行时长 |
| 应用 | 列表（含已下架）、新建、编辑、上架/下架、软删除；**上传 zip 包**（自动算 sha256 与大小、原子写库）、查看本机已有版本 |
| 分类标签 | 新建 / 改名 / 删除分类与标签、分类排序；删除仍在被使用的分类或标签会先提示有几个应用在用，确认后才删 |
| 用户 | 搜索、封禁/解封（立刻踢掉该用户所有登录）、重置密码、单独踢下线 |
| 管理员 | 添加 admin 账号、重置密码、停用/启用、删除；以及修改自己的密码 |
| 邮件 | smtp / resend / sendgrid / aliyun / console 五个通道、测试发信、验证码限流、token 有效期、注册/登录验证码开关 |

**一个应用可以挂多个分类、多个标签。** 分类在面板里创建，id 会出现在接口参数里
（`/api/market/feed?category=tools`）：填了就用填的，留空按名字生成，
中文名会生成 `cat_xxxxxxxx` 这样的随机 id。

应用编辑里能改的字段就是 `apps` 表的那一套：名称、简介、分类（多选）、版本、作者、
入口文件、图标、主页、截图、声明权限、标签、排序权重。

实现上的几个要点：

- **账号与会话**：口令 bcrypt 哈希落库；登录态是 HMAC 签名 cookie，签名密钥里混了
  该账号的 `password_hash` —— 改密码就等于踢掉这个账号的所有旧 cookie。
  签名密钥是 `.env` 里的 `ADMIN_SECRET`（没有就启动时自动生成）。
- **首次建号是串行化的**：用 MySQL 命名锁 + 表内计数，两个请求同时打过来也只会建一个。
- **改完立即生效**：邮件配置同时写 `.env`（重启后仍有效）和进程内 `config`（不用重启）。
  写文件是「逐行替换 KEY、不重排、不删注释」。
- **密钥不回显**：口令 / API Key 类字段只返回「有没有设置」，留空提交表示「不修改」。
- 面板是服务端直出的单页 HTML，**不引任何 CDN** —— 内网没外网也能用。

接口。公开的（不需要登录）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/admin/api/session` | `{setup, user}` —— 页面据此决定显示 建号 / 登录 / 面板 |
| POST | `/admin/api/setup` | `{username, password, setupToken?}`，仅当还没有任何管理账号时可用 |
| POST | `/admin/api/login` | `{username, password}` → 种 cookie |
| POST | `/admin/api/logout` | 清 cookie |

以下都要先登录：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/admin/api/me` | 当前管理员 |
| POST | `/admin/api/me/password` | `{oldPassword, newPassword}` 改自己的密码 |
| GET | `/admin/api/admins` | 管理员列表 |
| POST | `/admin/api/admins` | `{username, password}` 新增 admin 组成员 |
| POST | `/admin/api/admins/:id/password` | 重置别人的密码 |
| POST | `/admin/api/admins/:id/status` | `{status: active\|disabled}` 停用/启用 |
| DELETE | `/admin/api/admins/:id` | 删除账号（不能删自己、不能删最后一个） |
| GET | `/admin/api/status` | 概况与当前策略 |
| GET | `/admin/api/meta` | 分类 + 标签 + 每个下面的应用数 |
| POST | `/admin/api/categories` | `{name, id?, sortOrder?}` 新建分类 |
| PUT | `/admin/api/categories/order` | `{ids:[...]}` 批量排序 |
| PUT | `/admin/api/categories/:id` | `{name?, sortOrder?}` 改名 / 调序 |
| DELETE | `/admin/api/categories/:id[?force=1]` | 删除；被应用使用时需 `force=1` |
| POST | `/admin/api/tags` | `{name, slug?}` 新建标签 |
| PUT | `/admin/api/tags/:id` | `{name}` 改名 |
| DELETE | `/admin/api/tags/:id[?force=1]` | 删除；被应用使用时需 `force=1` |
| GET | `/admin/api/mail` | 邮件配置（密钥类只报「已设置」） |
| PUT | `/admin/api/mail` | 保存并立即生效，同时写回 `.env` |
| POST | `/admin/api/mail/test` | `{to}` 发一封测试信 |
| GET | `/admin/api/apps?q=` | 应用列表（含已下架、分类、标签） |
| POST | `/admin/api/apps` | 新建应用（`categoryIds[]`、`tagNames[]`） |
| PUT | `/admin/api/apps/:id` | 编辑应用；只传 `{deleted}` 时就是上架/下架 |
| DELETE | `/admin/api/apps/:id` | 软删除（可恢复） |
| POST | `/admin/api/apps/:id/package` | multipart 上传 zip（`file` / `version` / `entry`） |
| GET | `/admin/api/apps/:id/packages` | 本机已有的版本包 |
| DELETE | `/admin/api/apps/:id/package/:version` | 删某个版本包 |
| GET | `/admin/api/users?q=` | 用户列表（可搜索） |
| POST | `/admin/api/users/:id/status` | `{status: active\|disabled}` 封禁 / 解封 |
| POST | `/admin/api/users/:id/password` | 重置密码 |
| POST | `/admin/api/users/:id/logout` | 踢掉该用户所有会话 |

## 运维

```bash
npm run prune    # 清理过期 30 天以上的会话行 + 过期 1 天以上的验证码
```

建议 crontab：

```
0 4 * * * cd /path/to/server && npm run prune >> prune.log 2>&1
```

## 安全清单

上线前务必确认：

- [ ] `.env` 里 `DB_PASSWORD` 不是空
- [ ] MySQL 不监听公网（或只允许内网）
- [ ] 前面挂 HTTPS（token 是 Bearer，明文 HTTP 等于公开）
- [ ] `CORS_ORIGIN` 收紧到你的域名，不要留 `*`
- [ ] `TRUST_PROXY=true` 如果放在 Nginx 后面（否则日志里全是代理 IP）
- [ ] `userdata/` 目录权限只给运行服务的用户
- [ ] `TOKEN_TTL` 若不是 `never`，确认你能接受「到点要重新登录」
      （默认 `never` = 永不过期；撤销仍然随时生效）
- [ ] `AUTH_LOGIN_CODE=on` 时确认邮件通道稳定 —— 发不出信等于谁都登不进去
- [ ] `MAIL_DEV_ECHO_CODE=false`（**开着等于验证码直接送给请求方**）
- [ ] `MAIL_DRIVER` 不是 `console`（那样谁都能注册，因为码只在服务端日志里）
- [ ] SMTP 用 587/465 这类加密端口，别在公网上跑明文 25

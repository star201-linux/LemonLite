# 轻柠 LemonLite

Flutter + Android 的小程序宿主框架。跑小程序的方式是**下载 zip 包、
解压、用本地 `file://` 打开**，而不是加载远程网页 —— 这样能校验
SHA-256、能离线用、页面也不会随时变。

```
main/
├── repo/                    ← 本仓库（git 根在这里）
│   ├── client/              Flutter 客户端（Android）
│   ├── server-node/         Node.js 服务端（纯 API）
│   ├── docs/                开发技术文档 + 邮件通道配置
│   ├── scripts/             本地出包脚本
│   ├── dist/                构建产物 APK（不入库）
│   └── build.md             构建说明（从这里开始）
└── 证书信息.txt              签名证书的全部信息（不入库，在仓库外）
```

## 功能一览

| 能力 | 状态 |
| --- | --- |
| 应用市场（分页 / 分类 / 搜索 / 标签） | ✅ |
| 小程序 zip 包下载、SHA-256 校验、解压、`file://` 运行 | ✅ |
| JSBridge（Storage / 网络 / 权限 / 原生能力） | ✅ |
| 后台运行（页面保活，后台期间 JS 定时器挂起） | ✅ |
| 账号：注册 / 登录 / 改资料 / 改密码 / 多设备会话管理 | ✅ |
| **服务端管理面板**（`/admin`：概况 / 应用上架与传包 / 用户封禁 / 邮件通道） | ✅ |
| **注册邮箱验证码**（服务端可切换自建 SMTP / 第三方通道） | ✅ |
| **登录二次验证**（服务端开关，客户端自动跟随） | ✅ |
| token 持久登录（默认永不过期，可随时撤销） | ✅ |
| 动态取色（Material You）+ 深色模式 | ✅ |
| 页面转场、列表错峰入场、按压反馈、Tab 切换动效 | ✅ |

## 快速开始

**只想装 App**：见仓库根目录 `dist/` 里的 APK（构建产物，不入库）。

**要出测试包**：本机没有 Flutter SDK（或不想装）时用 GitHub Actions ——
推送 `client/` 的改动会自动跑，也可以手动触发：

```
Actions → build-apk → Run workflow → 下载 Artifacts 里的 lemonlite-apk-<run>
```

有 Flutter 的机器上直接：

```bash
./scripts/build-apk.sh            # release，arm64，产物进 dist/
./scripts/build-apk.sh debug      # debug 包
```

> 没配 `client/android/key.properties` 时构建会回落到 debug 签名，
> 装到已有正式签名的手机上需要先卸载旧版（签名不同，不能覆盖安装）。

**要改客户端**：

```bash
cd client
flutter pub get
flutter build apk --release
```

**要部署服务端**（Node.js）：

```bash
cd server-node
cp .env.example .env     # 编辑 DB_* 与 MAIL_*（注册要发验证码，必配）
npm install
npm run init -- --seed   # 建库建表 + 灌演示数据
npm start                # 启动（默认 3000）
```

注册要邮箱验证码，**邮件通道不配就注册不了**。五种通道（自建 SMTP /
QQ 邮箱 / Resend / SendGrid / 阿里云 DirectMail）都在
[`docs/邮件通道配置.md`](docs/邮件通道配置.md) 里写清了步骤；
只想先跑通流程可以把 `MAIL_DRIVER=console` 并开 `MAIL_DEV_ECHO_CODE=true`，
验证码会直接打到服务端日志、并自动填进客户端输入框。

## 文档

| 文档 | 内容 |
| --- | --- |
| [`build.md`](build.md) | 构建、签名、部署、常见问题 |
| [`docs/开发技术文档.md`](docs/开发技术文档.md) | 架构、设计取舍、踩坑记录 |
| [`docs/邮件通道配置.md`](docs/邮件通道配置.md) | 五种邮件通道的配置步骤与排错 |
| `../证书信息.txt`（仓库**外**的本地文件） | 签名证书的全部信息（含口令），只在本机保管 |
| [`server-node/README.md`](server-node/README.md) | Node.js 服务端 |

## 测试

```bash
cd server-node && npm test     # 邮件 MIME / SMTP 对话 / 验证码哈希，无需数据库
```

## 技术栈

| | |
| --- | --- |
| 客户端 | Flutter 3.47 / Dart 3.13，Android SDK 36，JDK 17 |
| 小程序容器 | flutter_inappwebview 6.2.0-beta.3 |
| 服务端 | Node.js 20+，MySQL 8.0+ |
| 客户端 HTTP | dio 5.7 |
| 本地存储 | shared_preferences 2.3 |
| 邮件 | 自建 SMTP（自带极简客户端，零依赖）/ Resend / SendGrid / 阿里云 |

## 许可

[Apache License 2.0](LICENSE)。

# 轻柠 LemonLite

Flutter + Android 的小程序宿主。小程序以 **zip 包**分发：下载 → 校验 SHA-256 → 解压 → 用本地 `file://` 打开。离线可用，版本可查，页面不会随时变。

```
repo/
├── client/                Flutter 客户端（Android）
├── server-node/           Node.js 服务端（纯 API + 管理面板）
├── docs/                  小程序开发文档、邮件通道配置
├── scripts/               本地出包脚本
├── dist/                  构建产物 APK（不入库）
└── build.md               构建、签名、部署
```

## 功能

| 能力 | 状态 |
| --- | --- |
| 应用市场（分页 / 分类 / 搜索 / 标签） | ✅ |
| 小程序 zip：下载、SHA-256 校验、解压、`file://` 运行 | ✅ |
| **小程序包 `metadata.json`**（名称、版本、入口、声明权限，类似 AndroidManifest） | ✅ |
| **更新检查**（启动查全部 + 打开前查单个；应用管理小红点、详情页「更新 / 打开」） | ✅ |
| **应用管理**（本地图标缓存、详情页、扳手进权限 / 数据、移除） | ✅ |
| **权限按声明展示**（只列 `metadata.json` 声明的 + 运行时真请求过的） | ✅ |
| **浏览器标准权限集**（媒体/显示、传感器、输入、连接、身份、存储、系统共 26 项，id 与浏览器权限名一致） | ✅ |
| **定位两轴授权**（前台/后台 × 精确/近似；后台精度不超过前台，近似模糊到约 3 km²） | ✅ |
| JSBridge：Storage / 网络 / 文件 / 下载 / 设备状态 / 蓝牙 / NFC | ✅ |
| **蓝牙**（BLE + 经典扫描、连接、GATT 读写、notify、RSSI/MTU）与 **NFC**（读卡 / 写 Text） | ✅ |
| **MD3E 样式拦截**（WebView 文档拦截 + DOM 拦截，只写原生 HTML 也自动变成 MD3） | ✅ |
| **小程序独立窗口**（在系统最近任务里是一张独立卡片，宿主那张保持「轻柠」） | ✅ |
| 下载管理（交给系统下载器，存 `Download/`） | ✅ |
| **插件体系**（给宿主加能力，多平台声明，ZIP 导入 / 停用 / 卸载） | ✅ |
| 后台运行（页面保活，后台期间 JS 定时器挂起） | ✅ |
| 账号：注册 / 登录 / 改资料 / 改密码 / 多设备会话 | ✅ |
| **下线即登出**（启动与请求时校验 token，被踢 / 过期就弹「账号已下线」并回到可登录状态） | ✅ |
| 服务端管理面板（`/admin`：上架、传包、分类标签、用户、邮件通道） | ✅ |
| 注册邮箱验证码 / 登录二次验证 | ✅ |
| 动态取色（Material You）+ 深色模式 | ✅ |
| **M3 Expressive 加载指示器**（形状蠕动圆环 + 波浪进度条，手机/手表两档尺寸） | ✅ |
| 量产加固（安全响应头、限流、请求超时、全局错误上报） | ✅ |

## 插件与模块

两者都叫 bundle、都是 zip + `lemonlite.json`，但**改的东西不一样**：

| | 模块（module） | 插件（plugin） |
| --- | --- | --- |
| 作用对象 | **页面** | **宿主** |
| 做什么 | 往匹配的小程序注入 JS / CSS | 给宿主增加一项能力，所有页面可用 |
| 声明方式 | `matches` + `js` / `css` + `bridge` | `platforms` + `capabilities` |
| 能否新增 API | 能，但是**声明式**的（`bridge` 组合宿主已有能力） | 能，能力由宿主版本实现 |
| 多平台 | 不区分 | 必须声明，宿主只在匹配平台启用 |
| 入口 | 开发者选项 → 模块 | 设置 → 插件 |

- **模块**适合：给某类页面加样式、改标题、包一层调试工具、把几个已有 API 组合成业务快捷方式。
- **插件**适合：新硬件 / 新平台能力，需要跟随宿主实现、单独升级或按平台裁剪。

> 插件当前**不内置任何能力实现**：`capabilities` 只是声明，`lemonlite.plugins.has()` 会如实回答。
> 不要把它当成「装上就能用」的扩展点 —— 真正的实现要随宿主版本落地。

包格式见 [`client/docs/bundles/README.md`](client/docs/bundles/README.md)。

## 快速开始

**只要装 App**：`dist/` 里的 APK（构建产物，不入库）。

**要出包**：没有 Flutter 环境就用 GitHub Actions（推 `client/` 自动跑，也可手动触发）；
有环境就直接：

```bash
./scripts/build-apk.sh            # release，arm64，产物进 dist/
./scripts/build-apk.sh debug      # debug
```

> 没配 `client/android/key.properties` 时会回落到 debug 签名；换签名安装需先卸载旧版。

**要改客户端**：

```bash
cd client && flutter pub get && flutter build apk --release
```

**要部署服务端**：

```bash
cd server-node
cp .env.example .env     # DB_* 与 MAIL_*（注册发验证码，必配）
npm install
npm run init -- --seed   # 建库建表（默认没有任何小程序）
npm start
```

市场默认是空的，管理员在 `/admin` 新建应用并上传 zip 后才会有内容。
邮件通道不配就注册不了；想先跑通流程可把 `MAIL_DRIVER=console` 并开
`MAIL_DEV_ECHO_CODE=true`，验证码会打到日志并自动填进客户端。

## 开发小程序

从 [`docs/开发文档.md`](docs/开发文档.md) 开始：包结构、`metadata.json`、
权限声明、JSBridge、MD3E 样式接管、调试与上架。

## 文档

| 文档 | 内容 |
| --- | --- |
| [`docs/开发文档.md`](docs/开发文档.md) | **写小程序看这个**：包结构、metadata、API、样式、上架 |
| [`client/docs/bundles/README.md`](client/docs/bundles/README.md) | 模块 / 插件包格式 |
| [`build.md`](build.md) | 构建、签名、部署、常见问题 |
| [`docs/邮件通道配置.md`](docs/邮件通道配置.md) | 五种邮件通道的配置与排错 |
| [`server-node/README.md`](server-node/README.md) | 服务端接口与运维 |

## 开发者模式

设置页最底部连点版本号 **8 次**（间隔不超过 2 秒）解锁。解锁后才会出现
「开发者选项」：市场服务器地址、本地包调试、模块管理、运行日志。

## 测试

```bash
cd client && flutter test          # 客户端
cd server-node && npm test         # 邮件 MIME / SMTP / 验证码（无需数据库）
```

## 技术栈

| | |
| --- | --- |
| 客户端 | Flutter 3.47 / Dart 3.13，Android SDK 36，JDK 17 |
| 小程序容器 | flutter_inappwebview 6.2.0-beta.3 |
| 服务端 | Node.js 20+，MySQL 8.0+ |
| 客户端 HTTP | dio 5.7 |
| 本地存储 | shared_preferences 2.3 |
| 邮件 | 自建 SMTP（零依赖）/ Resend / SendGrid / 阿里云 |

## 许可

[Apache License 2.0](LICENSE)。

# 轻柠 LemonLite

Flutter + Android 的小程序宿主。小程序以 **zip 包**分发：下载 → 校验 SHA-256 → 解压 → 通过本地虚拟源（`https://miniapp.lemonlite.local/…`，由宿主从磁盘喂内容）打开。离线可用，版本可查，页面不会随时变。

```
repo/
├── client/                Flutter 客户端（Android）
├── server-node/           Node.js 服务端（纯 API + 管理面板）
├── docs/                  小程序开发文档、邮件通道配置、账号与站点策略
├── scripts/               本地出包脚本
├── dist/                  构建产物 APK（不入库）
└── build.md               构建、签名、部署
```

## 功能

| 能力 | 状态 |
| --- | --- |
| 应用市场（分页 / 分类 / 搜索 / 标签；名称、图标、简介**全部来自服务端 API**） | ✅ |
| 小程序 zip：下载、SHA-256 校验、解压、虚拟 https 源运行（支持 ES module） | ✅ |
| **安装布局**（解到 `/data/data/<包名>/app/<appId>/`，平铺；原包留一份 `app.zip`，版本与入口记在 `.install.json`） | ✅ |
| **原子换入**（新版本先解到暂存目录再 rename，升级中断不留半个包；旧布局自动迁移） | ✅ |
| **小程序包 `metadata.json`**（名称、版本、入口、声明权限，类似 AndroidManifest） | ✅ |
| **更新检查**（启动查全部 + 打开前查单个；应用管理小红点、详情页「更新 / 打开」） | ✅ |
| **应用管理**（名称 / 图标 / 版本**全部读包内 `metadata.json`**，与市场缓存互不覆盖；详情页、扳手进权限 / 数据、移除） | ✅ |
| **权限按声明 ∪ 使用展示**（未声明但运行时真请求过的，也留痕标「运行时请求」） | ✅ |
| **浏览器标准权限集**（媒体/显示、传感器、输入、连接、身份、存储、系统共 26 项，id 与浏览器权限名一致） | ✅ |
| **定位两轴授权**（前台/后台 × 精确/近似；后台精度不超过前台，近似模糊到约 3 km²） | ✅ |
| JSBridge：Storage / 网络 / 文件 / 下载 / 设备状态 / 蓝牙 / NFC | ✅ |
| **蓝牙**（BLE + 经典扫描、连接、GATT 读写、notify、RSSI/MTU）与 **NFC**（读卡 / 写 Text） | ✅ |
| **MD3E 样式拦截**（WebView 文档拦截 + DOM 拦截，只写原生 HTML 也自动变成 MD3） | ✅ |
| **小程序独立窗口**（独立任务 + 独立 `taskAffinity`：最近任务里宿主一张、小程序一张，各自的卡片用各自的图标；宿主那张保持「轻柠」） | ✅ |
| 下载管理（交给系统下载器，存 `Download/`） | ✅ |
| **插件体系**（给宿主加能力，多平台声明，ZIP 导入 / 停用 / 卸载） | ✅ |
| 后台运行（页面保活，后台期间 JS 定时器挂起） | ✅ |
| 账号：注册 / 登录 / 改资料 / 改密码 / 多设备会话 | ✅ |
| **邮箱强绑定**（邮箱不能在资料页直接改；更换需当前密码 + 新邮箱验证码，旧邮箱立刻失效） | ✅ |
| **登录设备二级页**（当前设备 / 其它在线 / 历史登录，可分条踢下线） | ✅ |
| **注销账号**（冷静期可撤销，到期自动删除账号与私有数据；面板可设天数或立即删除） | ✅ |
| **市场分段加载**（每页条数由服务端面板配置，主页与搜索按需下拉加载） | ✅ |
| **本地分页缓存**（冷启动先显示上次列表再静默刷新；退出登录 / 退出 App 清空） | ✅ |
| **下线即登出**（启动与请求时校验 token，被踢 / 过期就弹「账号已下线」并回到可登录状态） | ✅ |
| **封禁**（面板按「x 天 x 小时」选时长，可预设也可自定义；`-1` 为永久；原因可选；到期自动解封，封禁立刻踢下线） | ✅ |
| **公告四级**（红点 / 市场页横幅 / 弹窗一次 / 每次启动弹；面板可改级别与发布时间做定时发布） | ✅ |
| 服务端管理面板（`/admin`：上架、传包、分类标签、用户详情、公告、邮件通道、站点策略） | ✅ |
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
cp config.example.yaml config.yaml   # 改 db.password；邮件段按需填
npm install
npm run init -- --seed               # 建库建表（默认没有任何小程序）
npm start
```

配置只有一个 `config.yaml`（带完整注释的模板是 `config.example.yaml`，
首次启动会自动复制一份）。它不入库 —— 里面有数据库密码与邮件密钥。

市场默认是空的，管理员在 `/admin` 新建应用并上传 zip 后才会有内容。
邮件通道不配就注册不了；想先跑通流程可把 `mail.driver` 设成 `console`
并开 `mail.devEchoCode: true`，验证码会打到日志并自动填进客户端。

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
| [`docs/账号与站点设置.md`](docs/账号与站点设置.md) | 注销冷静期、更换邮箱、登录设备、封禁、面板改资料、公告四级、市场分页与缓存 |
| [`server-node/config.example.yaml`](server-node/config.example.yaml) | **服务端全部可配项**，每项都带说明（复制成 `config.yaml` 再改） |
| [`server-node/README.md`](server-node/README.md) | 服务端接口与运维 |

## 开发者模式

设置页最底部连点版本号 **8 次**（间隔不超过 2 秒）解锁。解锁后才会出现
「开发者选项」：市场服务器地址、小程序测试（选本地 **ZIP 包**直接打开）、
模块管理、运行日志。

## 测试

```bash
cd client && flutter test          # 客户端（303 条）
cd server-node && npm test         # 单元 + 路由层端到端（145 条，无需 MySQL）
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

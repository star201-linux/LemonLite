# 构建说明

轻柠（LemonLite）的完整构建方式。本文档面向「拿到这份代码、要自己出包/部署」的人。

```
main/
├── repo/                    ← 本仓库
│   ├── client/              Flutter 客户端（Android）
│   ├── server-node/         Node.js 服务端（纯 API）
│   ├── docs/                开发技术文档
│   └── build.md             本文件
└── 证书信息.txt              签名证书的全部信息（不入库，在仓库外）
```

---

## 一、客户端（Flutter）

### 环境要求

| 项 | 版本 | 说明 |
| --- | --- | --- |
| Flutter | 3.47.x | Dart 3.13.x |
| JDK | 17 | AGP 9 要求 |
| Android SDK | 36 | compileSdk 36 |
| Gradle | 9.3.1 | 由 wrapper 管理，不用手装 |

> ⚠️ **Flutter 版本不要低于 3.38**：`file_picker 12.x` 要求 Dart ≥ 3.10。
> 如果只能用旧 Flutter，把 `file_picker` 降回 11.x（详见 `pubspec.yaml` 里的注释）。

### 首次构建

```bash
cd main/repo/client

flutter pub get

# 出包（正式签名）
flutter build apk --release

# 产物
# build/app/outputs/flutter-apk/app-release.apk
```

### 在 GitHub 上出测试包（本机没有 Flutter 时）

开发环境如果只有一台手机（arm64 Linux 容器），`flutter build apk` 是跑不起来的 ——
Android SDK 的 `aapt2` 只有 x86_64 版本。这种情况直接用仓库里的工作流：

```
Actions → build-apk → Run workflow → 选 ABI（默认 android-arm64）→ Run
跑完在 Artifacts 里下载 lemonlite-apk-<run>
```

向 `main` 推送 `client/` 的改动也会自动触发一次。

工作流做的事：装 JDK 17 + Flutter 3.47.9 → `flutter pub get` →
`flutter analyze`（**不阻塞**，只用来暴露问题）→
`flutter build apk --release --target-platform <ABI> --build-number <run_number>` → 上传 APK。

签名说明：

- 仓库里没有 `client/android/key.properties` 时，`build.gradle.kts` 会**回落到
  debug 签名**，打出来的包能装能用，但与正式签名不同 ——
  **覆盖安装会失败，要先卸载旧版**。
- 想用正式签名，在仓库 Secrets 里配好
  `LEMONLITE_KEYSTORE_BASE64` / `LEMONLITE_KEYSTORE_PASSWORD` /
  `LEMONLITE_KEY_ALIAS` / `LEMONLITE_KEY_PASSWORD`，工作流会自动还原 `.jks`。

本机有 Flutter 时也可以用脚本（会顺手把产物复制到 `dist/`）：

```bash
./scripts/build-apk.sh              # release，arm64
./scripts/build-apk.sh debug        # debug 包
./scripts/build-apk.sh release all  # 全部 ABI，通用包
```

### 签名

正式签名依赖两个文件，**都不在仓库里**（已在 `.gitignore`）：

```
main/repo/client/android/key.properties        ← 凭据
main/repo/client/android/app/lemonlite-release.jks   ← 密钥库
```

`build.gradle.kts` 的逻辑：

* `key.properties` **存在** → 用正式签名
* `key.properties` **不存在** → 回落到 debug 签名（保证没配密钥的机器也能构建）

密钥库内容、密码、指纹见本地 `证书信息.txt`（含口令，已列入 `.gitignore`，不入库）。

**没有密钥库时怎么自己生成**：

```bash
cd main/repo/client

keytool -genkeypair \
  -keystore android/app/lemonlite-release.jks \
  -alias lemonlite \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=LemonLite, OU=Mobile, O=star201, L=Unknown, ST=Unknown, C=CN"

cat > android/key.properties <<'EOF'
storeFile=lemonlite-release.jks
storePassword=你的store密码
keyAlias=lemonlite
keyPassword=你的key密码
EOF

chmod 600 android/key.properties android/app/lemonlite-release.jks
```

### 验证签名

```bash
$ANDROID_SDK/build-tools/36.0.0/apksigner verify --print-certs \
  build/app/outputs/flutter-apk/app-release.apk
```

输出的 SHA-256 应与 `证书信息.txt` 里的一致。若显示 `CN=Android Debug`，说明用了 debug 签名。

### 改默认服务器地址

```dart
// main/repo/client/lib/core/globals.dart
const String kDefaultServerUrl = String.fromEnvironment(
  'LEMONLITE_SERVER',
  defaultValue: 'https://lemonlite.cc.cd',
);
```

支持**构建期覆盖**，不用改代码：

```bash
flutter build apk --release --dart-define=LEMONLITE_SERVER=https://your-server.com
```

### 改包名 / 应用名 / 版本

| 项 | 位置 |
| --- | --- |
| 包名 | `android/app/build.gradle.kts` 的 `applicationId` 与 `namespace` |
| 应用名 | `android/app/src/main/AndroidManifest.xml` 的 `android:label` |
| 版本 | `pubspec.yaml` 的 `version: 0.1.0+1`（`+` 后面是 versionCode） |

> 改包名时 Kotlin 源码目录也要跟着改：
> `android/app/src/main/kotlin/<包名路径>/MainActivity.kt`，
> 且文件首行 `package` 要一致。

### 图标

各密度 `ic_launcher.png` 在 `android/app/src/main/res/mipmap-*/`，
自适应图标在 `mipmap-anydpi-v26/ic_launcher.xml`（前景 + 背景色）。

换图标：把新 PNG 按 48/72/96/144/192 缩放到对应目录即可。

### 测试

```bash
cd main/repo/client
flutter analyze        # 静态检查
flutter test           # 184 个单元测试
```

---

## 二、Node.js 服务端

### 环境要求

* Node.js **20+**
* MySQL **8.0+**

### 构建

```bash
cd main/repo/server-node

cp .env.example .env
# 编辑 .env：DB_* 必填；注册要发验证码，MAIL_* 也要配
# （五种通道的配法见 docs/邮件通道配置.md；只想先跑通就 MAIL_DRIVER=console）

npm install
npm run init -- --seed     # 建库建表 + 灌基础分类/标签（不含任何小程序）
npm start                  # 启动（默认 3000）
```

### 测试

```bash
cd main/repo/server-node
npm test
```

---

## 三、常见问题

### `flutter build` 报 `The settings are not yet available for build`

Gradle daemon 缓存了旧的 `build.gradle.kts`。清掉：

```bash
./gradlew --stop
rm -rf ~/.gradle/caches/*/kotlin-dsl
```

### `share_plus` 与 `device_info_plus` 版本冲突

`share_plus` 必须用 **13.x**（10.x 与 `device_info_plus 13.x` 抢 `web` 包版本）。

### `file_picker` 构建失败

必须用 **12.3.0**：

* 11.x 及其更早在 AGP 9 下不应用 Kotlin 插件，生成注册类找不到 `FilePickerPlugin`
* 13.x 要求 `win32 ^6.3.0`，与 plus 系列冲突

详见 `pubspec.yaml` 里的注释。

### `flutter analyze` 在中文路径下崩溃

Flutter 的 analysis server 在非 ASCII 路径下会有字节/字符长度不一致的 bug。
用 `dart analyze` 代替：

```bash
dart analyze lib/
```

### 注册时提示「服务端邮件通道未配置」

服务端启动日志里会有一行 `! 邮件 ... 未就绪（原因）`，照括号里缺的项补 `.env` 即可：

| 日志说的 | 要补 |
| --- | --- |
| 没有配置 MAIL_FROM | `MAIL_FROM=no-reply@你的域名` |
| 没有配置 SMTP_HOST | `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASSWORD` |
| 没有配置 RESEND_API_KEY | `RESEND_API_KEY` |
| 没有配置 ALIYUN_DM_* | 阿里云的 AK/SK 与发信地址 |

改完 `.env` **重启服务端**才生效（配置只在启动时读一次）。

### 收不到验证码邮件

按这个顺序查（详见 `docs/邮件通道配置.md` 第 7 节）：

1. 服务端日志里有没有 SMTP 报错（535 = 授权码/密码错，550 = 发件地址未验证）
2. 垃圾箱；QQ/163 邮箱尤其容易把「机器发的 6 位数字」判成垃圾
3. 发件域名的 SPF / DKIM 有没有生效：`dig txt 你的域名`
4. 服务商控制台的发送记录（Resend / SendGrid / 阿里云都有）
5. 用 `MAIL_DRIVER=console MAIL_DEV_ECHO_CODE=true` 跑一次 ——
   能在响应里拿到 `debugCode` 就说明**应用逻辑没问题，问题在邮件通道**

### 服务端返回 `Connection refused`，但配置看起来是对的

`.env` 里的 `DB_HOST` 要用数据库真正监听的主机名（远程库不能用
`localhost`，那指的是「本机」而不是「库所在机器」）。

另外检查 `.env` 是否是 **UTF-8 无 BOM**（Windows 记事本会带 BOM），
以及 `npm start` 时终端有没有打印出实际监听的地址与端口。

### 客户端报「服务器返回了无法识别的内容」

到「设置 →（连点 8 次版本号）→ 开发者选项 → 诊断 → 运行日志」，
导出日志（会弹系统分享面板）。日志里会有 `Market` 开头的行，
带 HTTP 状态码、Content-Type 和响应片段。

---

## 四、目录速查

```
main/repo/client/
├── lib/
│   ├── core/          全局常量、日志、主题
│   ├── bridge/        JSBridge（小程序 ↔ 宿主）
│   ├── data/          模型、仓库、服务
│   └── pages/         页面（home / miniapp / settings / account / detail）
├── android/           Android 工程（含签名配置）
├── assets/            自检页与插件包（不含示例小程序）
└── test/              单元测试

main/repo/server-node/
├── src/
│   ├── routes/        路由
│   ├── lib/           鉴权、HTTP、用户数据、包/图标存储
│   └── *.js           入口与脚本
└── sql/
```

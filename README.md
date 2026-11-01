# 轻柠 LemonLite

Flutter + Android 的小程序宿主框架。跑小程序的方式是**下载 zip 包、
解压、用本地 `file://` 打开**，而不是加载远程网页 —— 这样能校验
SHA-256、能离线用、页面也不会随时变。

```
main/
├── repo/                    ← 本仓库（git 根在这里）
│   ├── client/              Flutter 客户端（Android）
│   ├── server-node/         Node.js 服务端（纯 API）
│   ├── docs/                开发技术文档
│   ├── dist/                构建产物 APK（不入库）
│   └── build.md             构建说明（从这里开始）
└── 证书信息.txt              签名证书的全部信息（不入库，在仓库外）
```

## 快速开始

**只想装 App**：见仓库根目录 `dist/` 里的 APK（构建产物，不入库）。

**要改客户端**：

```bash
cd client
flutter pub get
flutter build apk --release
```

**要部署服务端**（Node.js）：

```bash
cd server-node
cp .env.example .env     # 编辑 DB_*
npm install
npm run init -- --seed   # 建库建表 + 灌演示数据
npm start                # 启动（默认 3000）
```

## 文档

## 文档

| 文档 | 内容 |
| --- | --- |
| [`build.md`](build.md) | 构建、签名、部署、常见问题 |
| [`docs/开发技术文档.md`](docs/开发技术文档.md) | 架构、设计取舍、踩坑记录 |
| `../证书信息.txt`（仓库**外**的本地文件） | 签名证书的全部信息（含口令），只在本机保管 |
| [`server-node/README.md`](server-node/README.md) | Node.js 服务端 |

## 技术栈

| | |
| --- | --- |
| 客户端 | Flutter 3.47 / Dart 3.13，Android SDK 36，JDK 17 |
| 小程序容器 | flutter_inappwebview 6.2.0-beta.3 |
| 服务端 | Node.js 20+，MySQL 8.0+ |
| 客户端 HTTP | dio 5.7 |
| 本地存储 | shared_preferences 2.3 |

## 许可

未定。

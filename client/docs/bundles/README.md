# 模块与插件示例包

`demo-module.zip` 是 LemonLite 自有格式的导入样例：在「开发者选项 → 模块」里安装；
插件同样是这个格式（`type: "plugin"`），在「设置 → 插件」里导入。也可以用 `adb push` 放进应用私有目录后重启 App：

```bash
adb push demo-module.zip /data/data/com.lemonlite.lemonlite/files/lemonlite/modules/
```

（应用私有目录需要 root 或 `adb shell run-as com.lemonlite.lemonlite`；正常用文件选择器即可。）

## 包结构

两种包都是 **一个 zip**，里面必须有 `lemonlite.json`。

**模块**（注入页面）：

```
demo-module/
├── lemonlite.json     # manifest，文件名固定
├── inject.js          # 被 manifest 的 js 字段引用
└── style.css          # 可选，被 css 字段引用
```

**插件**（给宿主加能力，不注入代码）：

```
my-plugin/
└── lemonlite.json     # 必须有 platforms，capabilities 可选
```

- zip 里可以不带最外层目录，也可以带（带的话会被自动剥掉）。
- 也可以只导入一个单独的 `lemonlite.json`，但那样不能引用脚本文件。

## manifest 字段

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `type` | ✅ | `module` 或 `plugin` |
| `id` | ✅ | 全局唯一，小写字母数字与 `. _ -`，同时用作目录名 |
| `name` / `version` | ✅ | 展示用 |
| `description` / `author` | | 展示用 |
| `matches` | | 生效的页面模式，默认 `["*"]`。支持 `*`、`apps/hello/*`、`*hello*` |
| `runAt` | | `documentStart`（页面脚本前）或 `documentEnd`（默认） |
| `css` / `js` | | 包内相对路径，按数组顺序拼接 |
| `bridge` | | **仅模块**：声明新的 JSBridge 方法 |
| `platforms` | | **仅插件**：支持的平台（`android` / `ios` / `macos` / `windows` / `linux` / `web`），空 = 全平台 |
| `capabilities` | | **仅插件**：声明提供的能力名（当前宿主未内置实现，仅作声明） |

## 模块的 `bridge`

模块不能带 Dart 代码，所以「新增能力」只能是**声明式**的，由宿主用自己已有的实现组合：

```json
"bridge": [
  { "name": "greet", "action": "const", "params": { "value": { "text": "你好" } } },
  { "name": "remember", "action": "storage.set", "params": { "key": "count" } }
]
```

可用的 `action`：

| action | 说明 |
| --- | --- |
| `const` | 直接返回 `params.value` |
| `http.get` / `http.post` | 转发到宿主的 dio 请求，`params.url` 必填 |
| `storage.get/set/remove/clear/keys` | 转发到宿主存储（按当前小程序隔离） |
| `ui.toast` / `ui.setTitle` | 弹提示 / 改标题 |
| `shell.openUrl` | 用系统浏览器打开 |

`params` 里写死的值可以被小程序调用时传的参数覆盖。

小程序侧用法（宿主会自动生成包装函数）：

```js
const r = await lemonlite.greet();     // → { text: '你好', module: '…' }
await lemonlite.remember({ value: 1 });
const c = await lemonlite.recall();     // storage.get，manifest 里给了 defaultValue
```

## 边界（重要）

- 模块的脚本**只注入小程序 WebView 页面**，不执行任何 Dart，也无法改宿主 UI。
- 插件**不注入任何代码**，也不执行包内的脚本；它只是能力声明的载体。
- 模块拿不到宿主没有的能力：`action` 是白名单，装之前就会校验并拒绝。
- 名字不能覆盖宿主内置 API（`getTheme`、`showToast` 等），校验时会拦下。
- 解压有安全上限：拒绝 `..` 路径、绝对路径；最多 200 个条目、单文件 2MB、总计 8MB。

## 打包命令

改了 `src/` 下的源码后重新打包（zip 里带最外层目录，顺便验证剥目录逻辑）：

```bash
cd docs/bundles
for n in demo-module; do
  (cd src/$n && zip -r ../../$n.zip . -x '.*')
done
```
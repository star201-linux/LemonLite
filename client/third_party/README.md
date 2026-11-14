# 内置的第三方包

这里放的是**从 pub.dev 原样取下来**的依赖源码。用 `path:` 引入，而不是
`hosted:`，原因是这两包很小、上游只有一个维护者，而它们决定了所有页面的
加载指示器长什么样 —— 把它钉在仓库里，构建结果就不会随上游发版而变。

| 目录 | 上游 | 版本 | 许可证 |
|---|---|---|---|
| `material3_expressive_loading_indicator/` | [pub.dev](https://pub.dev/packages/material3_expressive_loading_indicator) | 0.1.2 | MIT（含 AOSP 的 Apache-2.0 片段，见 `NOTICE`） |
| `material_new_shapes/` | [pub.dev](https://pub.dev/packages/material_new_shapes) | 1.0.0 | Apache-2.0 |

## 改了什么

只有一处：`material3_expressive_loading_indicator/pubspec.yaml` 里对
`material_new_shapes` 的依赖从 `^1.0.0` 改成了 `path: ../material_new_shapes`。
其余文件与上游 tarball 逐字节一致。

## 升级

```bash
cd client/third_party
curl -L -o m3e.tgz https://pub.dev/api/archives/material3_expressive_loading_indicator-<新版本>.tar.gz
tar -xzf m3e.tgz -C material3_expressive_loading_indicator --strip-components=1
# 然后重新把 pubspec.yaml 里的 material_new_shapes 改成 path（见上）
cd .. && flutter pub get
```

升级后跑一遍 `flutter test`，并打开任意有加载状态的页面看一眼 ——
这两包是纯 UI，出问题只会在画面上。

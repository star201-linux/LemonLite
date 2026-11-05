// lib/pages/settings/miniapp_test_page.dart
//
// 「小程序测试」二级页：开发者模式下的调试入口。
//
// 为什么单独做一层而不是直接摊在开发者选项首页：
//   开发者选项首页负责的是「改配置」（服务器地址、运行时信息），是静态的；
//   而这一页负责的是「真去开一个 WebView 跑东西」，会跳走、会占资源。
//   把这类入口收进二级菜单，一是避免在主调试页误触，
//   二是后面要加更多测试用例（本地 HTML、指定 appId、注入自定义主题…）时有地方放。
//
// 两个入口（这一版不再内置示例小程序：默认市场是空的，
// 小程序只能由管理员在服务端添加，调试时用本地包目录）：
//   1. SDK 自检 —— 把每个受控能力真调一遍
//   2. 本地包目录 —— 直接指定一个**已解压**的小程序目录（file:// 打开）
//
// 0.6 起不再支持「自定义 URL」：小程序只能从本地包打开，
// 远程网页那条路已经删了（见 data/services/miniapp_package_service.dart）。
// 要测一个页面，把它打成 zip 传到服务端，或者直接把解压好的目录填进来。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/autotest.dart';
import '../../data/services/miniapp_package_service.dart';
import '../miniapp/miniapp_host.dart';

class MiniappTestPage extends StatefulWidget {
  const MiniappTestPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const MiniappTestPage(),
  );

  @override
  State<MiniappTestPage> createState() => _MiniappTestPageState();
}

class _MiniappTestPageState extends State<MiniappTestPage> {
  /// 本地包目录（绝对路径）。默认留空，由用户填。
  late final TextEditingController _urlController = TextEditingController();

  String? _urlError;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 校验

  /// 校验「要当小程序打开的本地目录」。
  ///
  /// 只接受**绝对路径且目录存在、里面有 index.html**。
  /// 不做路径穿越校验 —— 这是开发者选项，填的人本来就有这台机器的
  /// 文件访问权；真正需要防穿越的是「从网络下载的包」（见 PackageService）。
  String? _validate(String input) {
    final String value = input.trim();
    if (value.isEmpty) return '请输入小程序目录的绝对路径';
    if (!value.startsWith('/')) {
      return '请填写绝对路径，例如 /data/user/0/xyz.star201.lemonlite/files/miniapps/xxx/1.0.0';
    }
    final Directory dir = Directory(value);
    if (!dir.existsSync()) return '目录不存在';
    if (!File('$value/index.html').existsSync()) {
      return '这个目录里没有 index.html';
    }
    return null;
  }

  /// 用目录名推一个能看懂的标题
  String _titleOf(String path) {
    final String name = p.basename(path);
    return name.isEmpty ? '本地包' : name;
  }

  // ------------------------------------------------------------ 动作

  /// SDK 自检：把每个受控能力真调一遍，并把报告写进它自己的文件沙箱。
  /// 排障时比"一个个手点"快得多，也能一眼看出是权限被拒还是能力本身坏了。
  void _openSelftest() {
    MiniappHost.instance.open(
      appId: 'lemonlite.selftest',
      title: 'SDK 自检',
      localAsset: kAutotestAsset,
      isTransient: true,
    );
  }

  void _openCustom() {
    final String value = _urlController.text.trim();
    final String? error = _validate(value);
    if (error != null) {
      setState(() => _urlError = error);
      return;
    }

    setState(() => _urlError = null);
    // appId 用目录名：不同目录的调试小程序共用 storage 会串数据
    final String appId =
        'dev.local.${p.basename(value).replaceAll(RegExp(r'[^\w.\-]'), '_')}';
    MiniappHost.instance.open(
      appId: appId,
      title: _titleOf(value),
      // 直接构造一个「已安装包」：目录就是包根，入口固定 index.html
      installedPackage: InstalledPackage(
        appId: appId,
        version: 'dev',
        entry: 'index.html',
        dir: value,
      ),
      isTransient: true,
    );
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('小程序测试')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: <Widget>[
          // ---------------- 提示 ----------------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.science_outlined,
                    size: 20,
                    color: scheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '调试用入口。这里打开的页面同样走完整的 WebView 承载 + JSBridge，'
                      '可以调 window.lemonlite 下的全部 API。',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- SDK 自检 ----------------
          _section(context, 'SDK 自检', <Widget>[
            ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('运行 SDK 自检'),
              subtitle: const Text(
                '把音量/亮度/方向/熄屏/文件/WASM/后台运行逐个真调一遍，'
                '结果写进该小程序的文件沙箱',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: _openSelftest,
            ),
          ]),

          // ---------------- 本地包目录 ----------------
          //
          // 0.6 起小程序只能从本地包打开，所以这里填的是**目录**而不是 URL。
          // 典型用法：把 zip 解压到某个目录，或者直接指向
          //   <应用私有目录>/miniapps/<appId>/<version>/
          _section(context, '本地包目录', <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _urlController,
                autocorrect: false,
                maxLines: 1,
                decoration: InputDecoration(
                  labelText: '小程序目录（绝对路径）',
                  hintText:
                      '/data/user/0/xyz.star201.lemonlite/files/miniapps/xxx/1.0.0',
                  errorText: _urlError,
                  helperText: '目录里必须有 index.html；用 file:// 打开，不需要联网',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.folder_open),
                  suffixIcon: IconButton(
                    tooltip: '清空',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _urlController.clear();
                      _urlError = null;
                    }),
                  ),
                ),
                onChanged: (_) => setState(() => _urlError = null),
                onSubmitted: (_) => _openCustom(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _openCustom,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('打开'),
                ),
              ),
            ),
          ]),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '注意：Android 9+ 默认禁止明文 HTTP。release 包只能开 https 地址；'
              '要连局域网里的 http 服务，请用 debug 包（生成脚本已为 debug 放开明文）。',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

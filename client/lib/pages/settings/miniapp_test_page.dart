// lib/pages/settings/miniapp_test_page.dart
//
// 「小程序测试」二级页：开发者模式下的调试入口。
//
// 为什么单独做一层而不是直接摊在开发者选项首页：
//   开发者选项首页负责的是「改配置」（服务器地址、运行时信息），是静态的；
//   而这一页负责的是「真去开一个 WebView 跑东西」，会跳走、会占资源。
//   把这类入口收进二级菜单，一是避免在主调试页误触，
//   二是后面要加更多测试用例时有地方放。
//
// 两个入口（这一版不再内置示例小程序：默认市场是空的，
// 小程序只能由管理员在服务端添加，调试时用本地 zip 包）：
//   1. SDK 自检 —— 把每个受控能力真调一遍
//   2. 本地 ZIP 包 —— 选一个 zip，解压到应用私有目录后直接用 file:// 打开
//
// 为什么从「填目录路径」改成「选 zip」：
//   手打一条 `/data/user/0/.../miniapps/xxx/1.0.0` 在手机上几乎不可能不出错，
//   而且要先在别处把包解压好 —— 那一步在 Android 11+ 的分区存储下更麻烦。
//   选文件是系统能力，开发者只需要把 zip 传到手机里（或者直接用网盘下载）。
//
// 0.6 起不再支持「自定义 URL」：小程序只能从本地包打开，
// 远程网页那条路已经删了（见 data/services/miniapp_package_service.dart）。

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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
  /// 用户选中的 zip（只是选，还没导入）
  PlatformFile? _picked;

  /// 正在解压 / 打开
  bool _busy = false;

  String? _error;

  // ------------------------------------------------------------ 工具

  String get _pickedName => _picked?.name ?? '';

  String _sizeLabel(int bytes) {
    if (bytes <= 0) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  /// 用文件名推一个能看懂的标题（去掉 .zip 后缀）
  String _titleOf(String name) {
    final String base = p.basenameWithoutExtension(name).trim();
    return base.isEmpty ? '本地包' : base;
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

  Future<void> _pickZip() async {
    if (_busy) return;
    PlatformFile? picked;
    try {
      // 不用 allowedExtensions 过滤：各厂商文件选择器对 zip 的 MIME 过滤不一致，
      // 反而选不到；这里放开选择、在下面按后缀校验，错误信息也更明确。
      picked = await FilePicker.pickFile(
        type: FileType.any,
        dialogTitle: '选择小程序 ZIP 包',
      );
    } catch (e) {
      if (mounted) setState(() => _error = '打开文件选择器失败：$e');
      return;
    }
    if (picked == null) return; // 用户取消，不算错误
    if (!picked.name.toLowerCase().endsWith('.zip')) {
      setState(() {
        _picked = null;
        _error = '请选择 .zip 文件（「${picked!.name}」不是）';
      });
      return;
    }
    setState(() {
      _picked = picked;
      _error = null;
    });
  }

  Future<void> _importAndOpen() async {
    final PlatformFile? file = _picked;
    if (file == null || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final Uint8List bytes = await file.readAsBytes();
      final InstalledPackage pkg = await MiniappPackageService.instance
          .installLocalZip(bytes, fileName: file.name);

      if (!mounted) return;
      MiniappHost.instance.open(
        appId: pkg.appId,
        title: pkg.metadata?.name ?? _titleOf(file.name),
        installedPackage: pkg,
        isTransient: true,
      );
    } on PackageException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

          // ---------------- 本地 ZIP 包 ----------------
          _section(context, '本地 ZIP 包', <Widget>[
            ListTile(
              leading: Icon(
                _picked == null
                    ? Icons.folder_zip_outlined
                    : Icons.check_circle_outline,
                color: _picked == null ? null : scheme.primary,
              ),
              title: Text(
                _picked == null ? '还没有选择文件' : _pickedName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _picked == null
                    ? '选一个 .zip（内含 index.html 或 metadata.json）'
                    // lengthSync 在原生选择器已经报了大小时不会碰磁盘，
                    // 拿不到就显示「大小未知」，不值得为一行副标题读一遍文件
                    : _sizeLabel(_picked!.lengthSync() ?? 0),
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _pickZip,
                child: Text(_picked == null ? '选择' : '重选'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.error_outline, size: 16, color: scheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _picked == null || _busy ? null : _importAndOpen,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_new),
                  label: Text(_busy ? '正在导入…' : '导入并打开'),
                ),
              ),
            ),
          ]),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '包会被解压到应用私有目录（miniapps/），不同包用各自的 appId 隔离数据；'
              '同一个包再次导入会覆盖上一次的调试版本。\n'
              '包里没有 metadata.json 时按文件名生成 appId，入口固定取 index.html。',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              '注意：Android 9+ 默认禁止明文 HTTP。release 包只能开 https 地址；'
              '要连局域网里的 http 服务，请用 debug 包（生成脚本已为 debug 放开明文）。',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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

// lib/pages/settings/developer_page.dart
//
// 开发者选项（进入方式：设置页版本号连点 8 次，全程无提示）。
//
// 阶段一只有三件事：
//   1. 自定义市场服务器地址（保存 / 重置为默认），保存后**立即生效**
//      —— 保存后直接调 HomeController.load()，用新地址重新拉 index.json
//   2. 「测试工具 → 小程序测试」二级菜单，用来跑 SDK 自检或本地包目录
//   3. 关闭开发者模式
// 另外附一块「运行时信息」，调主题/桥接问题时不用再翻日志。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../../core/globals.dart';
import '../../core/run_log.dart';
import '../../data/models/bundle_manifest.dart';
import '../../data/models/json_utils.dart';
import '../../data/services/settings_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../../theme/theme_injector.dart';
import '../home/home_controller.dart';
import 'bundles_page.dart';
import 'miniapp_test_page.dart';
import 'run_log_page.dart';

class DeveloperPage extends StatefulWidget {
  const DeveloperPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const DeveloperPage(),
  );

  @override
  State<DeveloperPage> createState() => _DeveloperPageState();
}

class _DeveloperPageState extends State<DeveloperPage> {
  late final TextEditingController _urlController = TextEditingController(
    text: SettingsService.instance.serverUrl,
  );

  String? _urlError;
  bool _busy = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 校验

  String? _validate(String input) {
    final String value = input.trim();
    if (value.isEmpty) return '地址不能为空';
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) {
      return '请填写完整地址，例如 https://example.com/lemonlite';
    }
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return '只支持 http / https 协议';
    if (uri.host.isEmpty) return '缺少主机名';
    return null;
  }

  /// 正在探测服务端（按钮转圈用）
  bool _probing = false;

  /// 输入框地址对应的 index.json 完整地址（预览用）
  /// 服务端主页推荐接口
  String _feedUrlOf(String base) => '${_normalizeBase(base)}/api/market/feed';

  /// 服务端健康检查（后端探测就靠它）
  String _healthUrlOf(String base) => '${_normalizeBase(base)}/api/health';

  String _normalizeBase(String base) {
    String value = base.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 手动探一次服务端。
  ///
  /// 为什么要单独一个探测按钮：「为什么没走服务端」几乎总是连通性问题
  /// （没开服务、地址填错、手机与电脑不在同一网络），
  /// 让用户当场点一下看到具体错误，比让他猜有用得多。
  ///
  /// 这里直连 `/api/health`，不经过 MarketRepository ——
  /// 调试时用户需要的是「不管上次怎样，现在立刻再探一次」，
  /// 而业务层可能会缓存/复用连接，不适合做一次性检查。
  Future<void> _probeApi(String base) async {
    final String url = _healthUrlOf(base);
    setState(() => _probing = true);
    try {
      final Response<dynamic> res = await Dio().get<dynamic>(
        url,
        options: Options(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          validateStatus: (int? s) => s != null,
        ),
      );
      if (!mounted) return;

      final Object? data = res.data;
      final bool okBody = data is Map && data['ok'] == true;
      final bool ok = res.statusCode == 200 && okBody;

      AppTheme.showToast(
        ok
            ? '服务端可用（HTTP ${res.statusCode}）'
            : '服务端返回 HTTP ${res.statusCode}，不像 LemonLite 服务端',
        isError: !ok,
        duration: const Duration(seconds: 4),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      // 把常见的几种失败翻译成人话：这些才是用户真正会遇到的
      final String hint = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.transformTimeout => '连接超时：服务没起，或者手机连不到这台机器',
        DioExceptionType.connectionError => '连不上：检查地址与端口，以及手机是否在同一网络',
        DioExceptionType.badCertificate => '证书校验失败（自签名 HTTPS 会这样）',
        _ => '请求失败：${e.message ?? e.type.name}',
      };
      AppTheme.showToast(
        hint,
        isError: true,
        duration: const Duration(seconds: 5),
      );
    } catch (e) {
      if (!mounted) return;
      AppTheme.showToast('探测失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  // ------------------------------------------------------------ 动作

  Future<void> _save() async {
    final String value = _urlController.text.trim();
    final String? error = _validate(value);
    if (error != null) {
      setState(() => _urlError = error);
      return;
    }

    setState(() {
      _urlError = null;
      _busy = true;
    });

    final SettingsService settings = SettingsService.instance;
    await settings.setServerUrl(value);
    if (!mounted) return;

    // 保存后立即生效：用新地址重新拉一次市场（失败也会在主页给出明确错误）
    await context.read<HomeController>().load();
    if (!mounted) return;

    setState(() => _busy = false);
    AppTheme.showToast(
      settings.isDefaultServer ? '已恢复默认地址' : '已保存，正在使用新地址加载市场',
    );
  }

  Future<void> _reset() async {
    setState(() {
      _urlError = null;
      _busy = true;
    });

    final SettingsService settings = SettingsService.instance;
    await settings.resetServerUrl();
    if (!mounted) return;

    _urlController.text = settings.serverUrl;
    await context.read<HomeController>().load();
    if (!mounted) return;

    setState(() => _busy = false);
    AppTheme.showToast('已重置为默认服务器地址');
  }

  Future<void> _closeDeveloperMode() async {
    await SettingsService.instance.setDeveloperMode(false);
    if (!mounted) return;
    AppTheme.showToast('已关闭开发者模式');
    Navigator.of(context).pop();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    AppTheme.showToast('已复制到剪贴板');
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final SettingsService settings = context.watch<SettingsService>();
    final ThemeController theme = context.watch<ThemeController>();
    // 主页当前用的是哪种后端 —— 展示在这里，用户排查「为什么没走服务端」时
    // 第一眼就能看到答案。
    final HomeController home = context.watch<HomeController>();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('开发者选项')),
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
                    Icons.build_outlined,
                    size: 20,
                    color: scheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '这里是调试用入口。修改服务器地址后，应用市场会立即改用新地址；'
                      '地址需要指向一个已部署的 LemonLite 服务端（见仓库 server/ 目录）。'
                      '模块会向小程序页面注入脚本，并可声明由宿主白名单能力实现的 API。',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ---------------- 服务器地址 ----------------
          _section(context, '自定义服务器地址', <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: '服务器地址（根目录，不带结尾斜杠）',
                  hintText: kDefaultServerUrl,
                  errorText: _urlError,
                  helperText: '将请求：${_feedUrlOf(_urlController.text)}',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.dns_outlined),
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
                onSubmitted: (_) => _save(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('保存并重新加载'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy || settings.isDefaultServer
                          ? null
                          : _reset,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('重置为默认'),
                    ),
                  ),
                ],
              ),
            ),
          ]),

          // ---------------- 当前地址 ----------------
          _section(context, '当前生效地址', <Widget>[
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('服务器根地址'),
              subtitle: Text(settings.serverUrl),
              trailing: IconButton(
                tooltip: '复制',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: () => _copy(settings.serverUrl),
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // 已加载数量：用户能据此判断「服务端给了多少条」
            ListTile(
              leading: const Icon(Icons.list_alt_outlined),
              title: const Text('已加载应用'),
              subtitle: Text(
                home.hasData
                    ? '${home.loadedCount} 个'
                          '${home.hasMore ? '（还有更多）' : '（已全部加载）'}'
                    : '还没有加载过',
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // 两种后端的探测地址都列出来 —— 排查「为什么没走服务端」时
            // 用户需要能直接点开 / 复制这两个地址自己验证。
            ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('服务端健康检查'),
              subtitle: Text(_healthUrlOf(settings.serverUrl)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: '复制',
                    icon: const Icon(Icons.copy_all_outlined),
                    onPressed: () => _copy(_healthUrlOf(settings.serverUrl)),
                  ),
                  IconButton(
                    tooltip: _probing ? '正在探测…' : '探测',
                    icon: _probing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering),
                    onPressed: _probing
                        ? null
                        : () => _probeApi(settings.serverUrl),
                  ),
                ],
              ),
            ),
          ]),

          // ---------------- 模块 ----------------
          // 模块能声明新的 JSBridge API，仍属于开发者功能；普通页面扩展已移到设置首页。
          _section(context, '模块', <Widget>[
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('模块'),
              subtitle: const Text('注入脚本，并可用宿主白名单能力组合出新的 API'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(BundlesPage.route(BundleType.module)),
            ),
          ]),

          // ---------------- 运行日志 ----------------
          //
          // 放在测试工具之上：用户报障时第一件事就是「去开发者选项导出日志」，
          // 不该藏在二级菜单里。
          _section(context, '诊断', <Widget>[
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('运行日志'),
              subtitle: Text(
                RunLog.instance.isEmpty
                    ? '还没有日志；导出后可以发给开发者定位问题'
                    : '${RunLog.instance.length} 条 · 导出成文件发给开发者',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(RunLogPage.route()),
            ),
          ]),

          // ---------------- 测试工具（二级菜单入口） ----------------
          // 真正会启动 WebView 的动作都收进二级页，这一层只留「跳转」，
          // 免得在改配置的页面里误点一下就跳走。
          _section(context, '测试工具', <Widget>[
            ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('小程序测试'),
              subtitle: const Text('运行 SDK 自检，或打开一个本地包目录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MiniappTestPage.route()),
            ),
          ]),

          // ---------------- 运行时信息 ----------------
          _section(context, '运行时信息', <Widget>[
            _kv(context, '应用版本', AppInfo.versionLabel),
            _divider(),
            _kv(context, '框架版本', kFrameworkVersion),
            _divider(),
            _kv(context, '主题模式', theme.themeModeLabel),
            _divider(),
            _kv(context, '配色来源', theme.sourceLabel),
            _divider(),
            _kv(
              context,
              '动态取色',
              theme.dynamicColorAvailable ? '可用' : '不可用（需 Android 12+）',
            ),
            _divider(),
            _kv(context, '种子色', ThemeInjector.toHex(theme.seedColor)),
            _divider(),
            _kv(
              context,
              '当前主色',
              ThemeInjector.toHex(theme.effectiveScheme().primary),
            ),
            _divider(),
            _kv(
              context,
              '上次同步',
              settings.lastSyncAt == null
                  ? '从未成功'
                  : formatDateTimeLabel(settings.lastSyncAt),
            ),
          ]),

          // ---------------- 危险操作 ----------------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: OutlinedButton.icon(
              onPressed: _closeDeveloperMode,
              icon: Icon(Icons.logout, color: scheme.error),
              label: Text('关闭开发者模式', style: TextStyle(color: scheme.error)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '关闭后「开发者选项」入口会隐藏；已经改过的服务器地址会保留，'
              '想恢复默认地址请先在上方点「重置为默认」。',
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

  Widget _kv(BuildContext context, String label, String value) => ListTile(
    dense: true,
    title: Text(label),
    trailing: SelectableText(
      value,
      style: Theme.of(context).textTheme.bodyMedium,
    ),
  );

  Widget _divider() => const Divider(height: 1, indent: 16, endIndent: 16);
}

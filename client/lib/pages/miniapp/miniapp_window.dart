// lib/pages/miniapp/miniapp_window.dart
//
// 小程序**独立窗口**的 Dart 侧入口。
//
// 背景（为什么要多一个入口）：
//   宿主里的小程序是「覆盖层」—— 一张上下文里的小程序，最近任务里只有宿主
//   那张卡。用户要的是微信小程序那种形态：宿主一张卡，小程序一张卡，
//   在系统切换器里并存、各自切换。那需要一个**独立任务**，也就是另一个
//   Activity + 另一个 Flutter 引擎（见 MiniappTaskActivity）。
//
// 所以这个进程的启动路径有两条：
//   * `defaultRouteName == "/"`                → 宿主（main.dart 的常规流程）
//   * `defaultRouteName == "/miniapp-window…"` → 本文件：只渲染一个小程序
//
// 两条路径的隔离是**天然的**：Flutter 的每个引擎有自己的 Dart isolate，
// `MiniappHost` 单例在两边互不可见。窗口里打开的那个小程序是一份独立的
// 运行状态，宿主不会因为它而改变任何东西 —— 这正是「独立窗口」该有的语义。
//
// 初始化刻意比宿主轻：窗口只需要「主题 + 权限 + 已安装包索引」，
// 不读账号、不拉市场、不恢复下载队列（那些是宿主的事）。

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/globals.dart';
import '../../core/native_bridge.dart';
import '../../core/run_log.dart';
import '../../data/services/application_registry.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/permission_service.dart';
import '../../data/services/settings_service.dart';
import '../../theme/theme_controller.dart';
import 'miniapp_host.dart';

/// 窗口启动参数（来自原生 `getInitialRoute()`）。
class MiniappWindowArgs {
  const MiniappWindowArgs({required this.appId, required this.title});

  final String appId;
  final String title;

  /// 路由前缀。与 `MiniappTaskActivity.ROUTE_PREFIX` 逐字一致，改一端必须改另一端。
  static const String routePrefix = '/miniapp-window';

  /// 这次启动是不是「小程序窗口」。
  static bool matches(String route) =>
      route == routePrefix || route.startsWith('$routePrefix?');

  /// 解析路由；不是窗口路由 / 缺 appId 时返回 null（调用方按宿主流程继续）。
  ///
  /// 解析失败**不抛异常**：这是启动路径，抛出去只会变成一块黑屏，
  /// 而「当成宿主启动」至少能让用户看到界面。
  static MiniappWindowArgs? parse(String route) {
    if (!matches(route)) return null;
    try {
      final Uri uri = Uri.parse(route);
      final String appId = uri.queryParameters['appId']?.trim() ?? '';
      if (appId.isEmpty) return null;
      final String rawTitle = uri.queryParameters['title']?.trim() ?? '';
      return MiniappWindowArgs(
        appId: appId,
        // 没给名字就用 appId：卡片上有个能认的值，比空白强
        title: rawTitle.isEmpty ? appId : rawTitle,
      );
    } catch (e) {
      lemonLogError('Window', '解析窗口路由失败：$route（$e）');
      return null;
    }
  }
}

/// 启动小程序窗口。由 `main()` 在识别到窗口路由时调用。
Future<void> runMiniappWindow(MiniappWindowArgs args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 主题要在第一帧就位：窗口没有启动画面兜底，晚一步就是「先白后黑」。
  final SettingsService settings = await SettingsService.init();
  // 权限服务是同步单例；桥接层每次调用都会查它，必须比 WebView 早就绪。
  PermissionService.init();
  // 已安装包索引：窗口打开的就是本机这一版，不查市场、不联网。
  ApplicationRegistry.init();
  // 版本号与框架版本进日志：窗口里出的问题导出日志时也要能看出是哪个包
  await AppInfo.load();
  RunLog.instance.appVersion = AppInfo.versionLabel;
  RunLog.instance.frameworkVersion = kFrameworkVersion;

  lemonLog('Window', '作为独立窗口启动：${args.appId}（${args.title}）');
  runApp(MiniappWindowApp(args: args, settings: settings));
}

class MiniappWindowApp extends StatelessWidget {
  const MiniappWindowApp({super.key, required this.args, required this.settings});

  final MiniappWindowArgs args;
  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        ChangeNotifierProvider<ThemeController>(
          create: (BuildContext ctx) => ThemeController(settings),
        ),
      ],
      child: _WindowThemedApp(args: args),
    );
  }
}

class _WindowThemedApp extends StatelessWidget {
  const _WindowThemedApp({required this.args});

  final MiniappWindowArgs args;

  @override
  Widget build(BuildContext context) {
    final ThemeController themeController = context.watch<ThemeController>();

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        themeController.updateDynamicSchemes(lightDynamic, darkDynamic);

        return MaterialApp(
          title: kFrameworkName,
          debugShowCheckedModeBanner: false,
          // 这两个 key 与宿主是**同一份定义**（globals.dart），但每个 isolate
          // 各有一份实例：权限页、toast 都在本窗口内解析，不会串到宿主去。
          navigatorKey: lemonNavigatorKey,
          scaffoldMessengerKey: lemonScaffoldMessengerKey,
          themeMode: themeController.themeMode,
          theme: themeController.themeFor(Brightness.light),
          darkTheme: themeController.themeFor(Brightness.dark),
          home: MiniappWindowPage(args: args),
        );
      },
    );
  }
}

/// 窗口内容：加载 → 会话视图 / 错误页。
class MiniappWindowPage extends StatefulWidget {
  const MiniappWindowPage({super.key, required this.args});

  final MiniappWindowArgs args;

  @override
  State<MiniappWindowPage> createState() => _MiniappWindowPageState();
}

class _MiniappWindowPageState extends State<MiniappWindowPage> {
  /// 打开失败的原因（未安装 / 读包失败）；null 表示没出错
  String? _error;

  /// 会话是否已建立（建立之后界面交给 MiniappHost 的层）
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // 先立规矩再开门：窗口模式下「返回 / 关闭」的含义与宿主不同
    //（宿主是转后台，窗口是关掉这张卡），MiniappHost 靠这个标记分流。
    MiniappHost.instance.windowMode = true;
    // 等第一帧之后再开：WebView 是平台视图，需要在有窗口的帧里创建
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    try {
      final InstalledPackage? pkg =
          await MiniappPackageService.instance.installed(widget.args.appId);
      if (!mounted) return;
      if (pkg == null) {
        setState(() => _error = '本机没有安装「${widget.args.title}」，请先在轻柠里安装它。');
        return;
      }
      await MiniappHost.instance.open(
        appId: widget.args.appId,
        title: widget.args.title,
        installedPackage: pkg,
      );
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      lemonLogError('Window', '打开 ${widget.args.appId} 失败：$e');
      if (!mounted) return;
      setState(() => _error = '打开失败：$e');
    }
  }

  /// 系统返回键 / 手势返回。
  ///
  /// 顺序：先让 WebView 回退自己的历史；退无可退才关掉窗口。窗口里没有
  /// 「转后台」这一步 —— 系统切换器就是它的后台，页面留着没有意义。
  Future<void> _handleBack() async {
    if (_ready && await MiniappHost.instance.handleSystemBack()) return;
    await NativeBridge.finishTask();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        await _handleBack();
      },
      child: _body(),
    );
  }

  Widget _body() {
    final String? error = _error;
    if (error != null) {
      return _ErrorPage(message: error, title: widget.args.title);
    }
    if (!_ready) {
      // 还没建会话：用主题色铺底 + 转圈，避免「白屏一闪」
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('正在打开「${widget.args.title}」…'),
            ],
          ),
        ),
      );
    }
    // 会话就绪：整个窗口就是小程序（它自己的 Scaffold 铺满全屏）
    return MiniappHost.instance.buildLayer();
  }
}

class _ErrorPage extends StatelessWidget {
  const _ErrorPage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.extension_off_outlined, size: 48, color: scheme.error),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => NativeBridge.finishTask(),
                child: const Text('关闭窗口'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

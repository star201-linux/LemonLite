
import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:provider/provider.dart';

import 'core/autotest.dart';
import 'core/globals.dart';
import 'data/models/miniapp_permission.dart';
import 'data/repositories/market_repository.dart';
import 'data/services/account_service.dart';
import 'data/services/announcement_service.dart';
import 'data/services/market_cache_service.dart';
import 'data/services/settings_service.dart';
import 'data/services/update_service.dart';
import 'pages/account/account_page.dart' show LoginPage;
import 'data/models/announcement.dart';
import 'pages/account/session_offline_dialog.dart';
import 'pages/settings/announcement_dialog.dart';
import 'pages/applications/applications_page.dart';
import 'pages/home/home_controller.dart';
import 'pages/home/home_page.dart';
import 'pages/miniapp/miniapp_host.dart';
import 'pages/permissions/permission_prompt.dart';
import 'pages/settings/settings_page.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

class LemonLiteApp extends StatelessWidget {
  const LemonLiteApp({super.key, required this.settings});

  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // 已初始化的实例，直接 value 注入
        ChangeNotifierProvider<SettingsService>.value(value: settings),
        // 账号状态（未登录是合法状态，不阻塞任何功能）
        ChangeNotifierProvider<AccountService>(
          create: (BuildContext ctx) => AccountService.instance,
        ),
        // 主题状态中心
        ChangeNotifierProvider<ThemeController>(
          create: (BuildContext ctx) => ThemeController(settings),
        ),
        // 市场数据源（无状态，用 Provider 而不是 ChangeNotifierProvider）
        Provider<MarketRepository>(
          create: (BuildContext ctx) => MarketRepository(settings: settings),
        ),
        // 站点公告：启动弹窗、市场横幅、设置页红点共用同一份状态，
        // 所以必须是 ChangeNotifier（详见 announcement_service.dart 的注释）
        ChangeNotifierProvider<AnnouncementService>(
          create: (BuildContext ctx) => AnnouncementService(settings: settings),
        ),
        ChangeNotifierProvider<HomeController>(
          create: (BuildContext ctx) =>
              HomeController(ctx.read<MarketRepository>()),
        ),
      ],
      child: const _ThemedApp(),
    );
  }
}

class _ThemedApp extends StatelessWidget {
  const _ThemedApp();

  @override
  Widget build(BuildContext context) {
    final ThemeController themeController = context.watch<ThemeController>();

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        themeController.updateDynamicSchemes(lightDynamic, darkDynamic);

        return MaterialApp(
          title: kFrameworkName,
          debugShowCheckedModeBanner: false,
          navigatorKey: lemonNavigatorKey,
          scaffoldMessengerKey: lemonScaffoldMessengerKey,
          themeMode: themeController.themeMode,
          theme: themeController.themeFor(Brightness.light),
          darkTheme: themeController.themeFor(Brightness.dark),
          // 自检要能把界面截下来：根部挂一个 RepaintBoundary，
          // 常规运行时它只是一层透明的代理，没有任何行为影响。
          builder: (BuildContext context, Widget? child) => RepaintBoundary(
            key: kAppCaptureBoundaryKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const AppShell(),
        );
      },
    );
  }
}

const double kTabletMinShortestSide = 600;

bool useWideLayout(BuildContext context) {
  final Size size = MediaQuery.sizeOf(context);
  return size.shortestSide >= kTabletMinShortestSide;
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _tabIndex = 0;

  /// 弹窗防重入。一条 401 可能同时来自好几个并发请求，
  /// AccountService 已经做了幂等，这里再兜一层，避免叠出两个对话框。
  bool _offlineDialogOpen = false;

  /// 公告弹窗是否正在显示（避免热重载 / 前后台切换时叠出第二个）
  bool _announcementDialogOpen = false;

  /// 上一次校验登录态的时间。前后台来回切时用得上（见 [_checkSessionLater]）。
  DateTime _lastSessionCheck = DateTime.fromMillisecondsSinceEpoch(0);

  AppLifecycleListener? _appLifecycle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLifecycle = AppLifecycleListener(
      onDetach: () {
        MarketCacheService.maybeInstance?.clear();
      },
    );
    // 小程序菜单里的「返回主页」会发这个信号（见 core/globals.dart）
    shellHomeRequested.addListener(_onHomeRequested);
    // 更新状态是全局的：应用管理的导航角标要跟着它变
    UpdateService.instance.addListener(_onUpdatesChanged);
    // 「被下线」的提示也是全局的（任何页面、任何请求都可能触发）
    AccountService.instance.addListener(_onAccountChanged);
    // 先从缓存恢复（第一帧就能显示小红点），再在首帧后向服务端查一次
    UpdateService.instance.restore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // **启动时校验本地 token 还有没有效**：被管理员踢下线、在别的设备
      // 退出、或者 token 过期，本地都还揣着这张已经作废的票根。不校验的话
      // 界面会一直显示「已登录」，点进账号页才露馅（而且是个转不完的圈）。
      unawaited(_checkSession());
      _maybeShowOfflineDialog();
      // 启动公告：要等一帧，且排在「被下线」提示之后（见 _maybeShowAnnouncement）
      unawaited(_maybeShowAnnouncement());
      // **打开 App 时检查所有已装小程序有没有新版本**
      UpdateService.instance.checkAll(
        repository: context.read<MarketRepository>(),
      );
    });
    // 只在传了 --dart-define=LEMONLITE_AUTOTEST 的调试包里生效；正式包这里是死代码
    if (autotestEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runAutotest());
    }
  }

  @override
  void dispose() {
    _appLifecycle?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    shellHomeRequested.removeListener(_onHomeRequested);
    UpdateService.instance.removeListener(_onUpdatesChanged);
    AccountService.instance.removeListener(_onAccountChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_checkSession());
  }

  Future<void> _checkSession() async {
    final DateTime now = DateTime.now();
    if (now.difference(_lastSessionCheck) < const Duration(seconds: 20)) return;
    _lastSessionCheck = now;
    await AccountService.instance.validateSession();
  }

  Future<void> _maybeShowAnnouncement() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;

    final AnnouncementService service = context.read<AnnouncementService>();
    await service.bootstrap();
    if (!mounted || _announcementDialogOpen || _offlineDialogOpen) return;

    final Announcement? announcement = service.popup;
    if (announcement == null) return;

    _announcementDialogOpen = true;
    try {
      await AnnouncementDialog.show(
        context,
        announcement: announcement,
        onConfirm: () => service.confirmPopup(announcement),
      );
    } finally {
      _announcementDialogOpen = false;
    }
  }

  void _onAccountChanged() {
    if (!mounted) return;
    _maybeShowOfflineDialog();
  }

  void _maybeShowOfflineDialog() {
    if (_offlineDialogOpen) return;
    final String? reason = AccountService.instance.takeOfflineNotice();
    if (reason == null) return;
    _offlineDialogOpen = true;
    // 可能是在 notify 的同步调用栈里进来的，排到帧后再弹
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _offlineDialogOpen = false;
        return;
      }
      final bool goLogin = await SessionOfflineDialog.show(
        context,
        reason: reason,
      );
      _offlineDialogOpen = false;
      if (!mounted) return;
      if (goLogin) {
        await Navigator.of(context).push(LoginPage.route());
      } else {
        // 弹窗期间可能又收到一条（例如并发的另一个请求），补弹一次
        _maybeShowOfflineDialog();
      }
    });
  }

  void _onHomeRequested() {
    if (!mounted) return;
    if (_tabIndex != 0) setState(() => _tabIndex = 0);
  }

  void _onUpdatesChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 端到端自检的驱动：声明两项权限（模拟 index.json 里的 permissions）、
  /// 走一次"打开前批量确认"，然后打开内置自检小程序。
  Future<void> _runAutotest() async {
    await autotestLog('自检启动（answer=$kAutotestAnswer）');
    _startEvidencePump();
    const String appId = 'lemonlite.selftest';
    const List<MiniappPermission> declared = <MiniappPermission>[
      MiniappPermission.camera,
      MiniappPermission.microphone,
    ];
    await PermissionPromptService.instance.requestDeclared(
      appId: appId,
      appName: 'SDK 自检',
      declared: declared,
    );
    await autotestLog('批量确认结束，打开自检小程序');
    await MiniappHost.instance.open(
      appId: appId,
      title: 'SDK 自检',
      localAsset: kAutotestAsset,
      isTransient: true,
      declaredPermissions: declared,
    );
    await autotestLog('自检小程序已打开');
  }

  /// 自检期间每 2 秒把证据"搬出来"一次：
  ///   1. 放开应用私有目录的权限（宿主机才读得到）
  ///   2. 把小程序沙箱里的报告镜像到私有目录（外部存储的祖先目录是 media_rw 0770，
  ///      宿主机连进都进不去，放开权限也没用）
  /// 只在 `--dart-define=LEMONLITE_AUTOTEST` 的包里跑，60 秒后自动停。
  void _startEvidencePump() {
    int ticks = 0;
    Timer.periodic(const Duration(seconds: 2), (Timer timer) async {
      ticks++;
      if (ticks > 30 || !mounted) {
        timer.cancel();
        return;
      }
      final int relaxed = await autotestRelaxPermissions();
      final List<String> copied = await autotestMirrorSandbox();
      if (copied.isNotEmpty) {
        await autotestLog('镜像沙箱文件：${copied.join(",")}（本轮放开 $relaxed 项）');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool wide = useWideLayout(context);

    return PopScope<Object?>(
      // 自己接管返回键（小程序不是路由，系统返回键到不了它那里）：
      //   1. 前台有小程序 → 先交给它（先回退 WebView 历史，退无可退则转后台运行）
      //   2. 不在主页      → 先回主页，符合「返回键逐层退出」的直觉
      //   3. 已经在主页    → 交给系统退出 App
      // 用 canPop:false 显式接手，是因为「转后台」这个语义没有办法用 Navigator 表达。
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        if (await MiniappHost.instance.handleSystemBack()) return;
        if (_tabIndex != 0) {
          setState(() => _tabIndex = 0);
          return;
        }
        await SystemNavigator.pop();
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // ---- 第一层：外壳（导航 + 当前 Tab）----
          Scaffold(
            body: wide
                ? Row(
                    children: <Widget>[
                      _SideNav(
                        index: _tabIndex,
                        onSelected: (int i) => setState(() => _tabIndex = i),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: _tabs()),
                    ],
                  )
                : _tabs(),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: _tabIndex,
                    onDestinationSelected: (int i) =>
                        setState(() => _tabIndex = i),
                    destinations: _destinations(),
                  ),
          ),
          // ---- 第二层：小程序层（盖住导航，但路由仍压在它之上）----
          MiniappHost.instance.buildLayer(),
        ],
      ),
    );
  }

  Widget _tabs() => _TabSwitcher(
    index: _tabIndex,
    children: const <Widget>[HomePage(), ApplicationsPage(), SettingsPage()],
  );

  /// 底部导航。应用管理上挂一个小红点：有小程序可更新时提示用户。
  ///
  /// Badge 不带 label 时就是一个纯圆点（Material 3 的 small badge），
  /// 不显示数字 —— 需求里要的是「小红点」，数字会让它看起来像一个计数器。
  List<NavigationDestination> _destinations() {
    final bool hasUpdates = UpdateService.instance.hasUpdates;
    return <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.storefront_outlined),
        selectedIcon: Icon(Icons.storefront),
        label: '主页',
      ),
      NavigationDestination(
        icon: Badge(
          isLabelVisible: hasUpdates,
          smallSize: 9,
          child: const Icon(Icons.apps_outlined),
        ),
        selectedIcon: Badge(
          isLabelVisible: hasUpdates,
          smallSize: 9,
          child: const Icon(Icons.apps),
        ),
        label: '应用管理',
      ),
      const NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: '设置',
      ),
    ];
  }
}

class _TabSwitcher extends StatefulWidget {
  const _TabSwitcher({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_TabSwitcher> createState() => _TabSwitcherState();
}

class _TabSwitcherState extends State<_TabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: M3EMotion.fast,
    value: 1,
  );

  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void didUpdateWidget(covariant _TabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget stack = IndexedStack(
      index: widget.index,
      children: widget.children,
    );
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return stack;

    return AnimatedBuilder(
      animation: _curve,
      child: stack,
      builder: (BuildContext context, Widget? child) {
        final double t = _curve.value;
        return Opacity(
          opacity: 0.35 + 0.65 * t,
          child: Transform.translate(
            offset: Offset(0, 6 * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({required this.index, required this.onSelected});

  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final bool hasUpdates = UpdateService.instance.hasUpdates;
    return NavigationRail(
      selectedIndex: index,
      onDestinationSelected: onSelected,
      labelType: NavigationRailLabelType.all,
      // 大屏上顶部留出空间，避免图标贴着状态栏
      leading: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Icon(
          Icons.local_cafe_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      destinations: <NavigationRailDestination>[
        const NavigationRailDestination(
          icon: Icon(Icons.storefront_outlined),
          selectedIcon: Icon(Icons.storefront),
          label: Text('主页'),
        ),
        NavigationRailDestination(
          icon: Badge(
            isLabelVisible: hasUpdates,
            smallSize: 9,
            child: const Icon(Icons.apps_outlined),
          ),
          selectedIcon: Badge(
            isLabelVisible: hasUpdates,
            smallSize: 9,
            child: const Icon(Icons.apps),
          ),
          label: const Text('应用管理'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('设置'),
        ),
      ],
    );
  }
}

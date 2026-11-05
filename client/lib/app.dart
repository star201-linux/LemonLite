// lib/app.dart
//
// App 根组件：Provider 装配 + MD3 主题接线 + 响应式外壳。
//
// 主题链路（这是本工程最重要的一条链）：
//   SettingsService（持久化的偏好）
//     → ThemeController（合成最终 ColorScheme）
//     → DynamicColorBuilder（注入 Android 12+ 壁纸色）
//     → MaterialApp.theme / darkTheme（全 App 生效）
//     → ThemeInjector（同一份配色注入 WebView 的 --md-* 变量）
// 全程只有一份配色来源，所以宿主与小程序不会出现「不同步」。
//
// 外壳布局（0.4 新增）：
//   按屏幕**最短边 dp** 区分手机与平板（Material 3 的 window size class）：
//     最短边 < 600dp  → 手机：底部 NavigationBar
//     最短边 ≥ 600dp  → 平板/大屏：左侧 NavigationRail（底部栏放到侧面）
//   为什么用最短边而不是 dpi：dpi 只说明像素密度，400+ dpi 的旗舰手机
//   一大堆，按 dpi 判会把它们全判成平板。最短边（逻辑像素）才真正对应
//   「这块屏幕能放多少内容」。

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
import 'data/services/settings_service.dart';
import 'data/services/update_service.dart';
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
        // 主页状态。放在 App 根部而不是 HomePage 内部，
        // 这样切到「设置」再切回来时列表、搜索词、分类筛选都还在。
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

/// 平板判定阈值（dp）。取 Material 3 window size class 的 compact/medium 分界。
///
/// 用**最短边**而不是宽度：横屏手机宽度可以到 900dp 以上，但它的最短边
/// 仍是 400 左右 —— 那种尺寸上放侧边栏会把内容区挤得很窄，还不如用底部栏。
const double kTabletMinShortestSide = 600;

/// 是否按「平板 / 大屏」布局渲染。
///
/// 用 `MediaQuery.size` 的最短边，而不是 `MediaQuery.orientation`：
/// 设备横竖屏切换时布局不应该跳变（用户把平板转一下，导航栏从左跑到下面）。
bool useWideLayout(BuildContext context) {
  final Size size = MediaQuery.sizeOf(context);
  return size.shortestSide >= kTabletMinShortestSide;
}

/// 宿主外壳：导航（手机底部栏 / 平板侧边栏）+ 三个 Tab + 小程序层。
///
/// 三个 Tab 用 IndexedStack 保活，避免来回切换时丢失滚动位置与搜索状态。
///
/// 小程序层（MiniappHost）叠在**外壳内容之上**、但仍在 MaterialApp 之内：
/// 这样它盖住底部/侧边导航，而 push 出来的页面（权限管理等）作为真实路由
/// 天然压在它上面 —— 菜单点开的新页面能看见。
/// 为什么不用 Navigator Overlay：见 miniapp_host.dart 文件头那段警告。
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    // 小程序菜单里的「返回主页」会发这个信号（见 core/globals.dart）
    shellHomeRequested.addListener(_onHomeRequested);
    // 更新状态是全局的：应用管理的导航角标要跟着它变
    UpdateService.instance.addListener(_onUpdatesChanged);
    // 先从缓存恢复（第一帧就能显示小红点），再在首帧后向服务端查一次
    UpdateService.instance.restore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    shellHomeRequested.removeListener(_onHomeRequested);
    UpdateService.instance.removeListener(_onUpdatesChanged);
    super.dispose();
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

/// 三个 Tab 的容器：保留 IndexedStack 的「保活」语义，额外加一段**切换动效**。
///
/// 为什么不是 AnimatedSwitcher：它一旦换 key 就会重建子树，
/// 主页的滚动位置、搜索词、设置页的开关状态全都会丢。
/// 这里只在切换的瞬间对新页面做一次「淡入 + 上浮」，子树始终是同一个
/// IndexedStack，状态一点都不会丢。
///
/// 淡入从 0.35 起步而不是 0：整屏从全透明开始的一帧在 OLED 上像闪了一下。
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

/// 平板/大屏用的侧边导航。
///
/// 用 NavigationRail 而不是「把 NavigationBar 转 90 度」：
/// Rail 会把标签放在图标右侧、整条栏收窄到 80dp 左右，比横过来的底部栏
/// 省得多的高度/宽度，也是 M3 对大屏的推荐做法。
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

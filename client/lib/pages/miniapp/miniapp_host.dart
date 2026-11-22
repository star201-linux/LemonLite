
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/globals.dart';
import '../../core/native_bridge.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/models/miniapp_session.dart';
import '../../data/services/icon_cache_service.dart';
import '../../data/services/installed_app_info.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/application_registry.dart';
import '../../theme/app_theme.dart';
import 'miniapp_page.dart';

class MiniappHost extends ChangeNotifier {
  MiniappHost._();

  static final MiniappHost instance = MiniappHost._();

  final List<MiniappSession> _sessions = <MiniappSession>[];

  String? _foregroundId;

  bool windowMode = false;

  /// 当前全部会话（顺序 = 打开顺序）
  List<MiniappSession> get sessions =>
      List<MiniappSession>.unmodifiable(_sessions);

  bool get hasAny => _sessions.isNotEmpty;

  int get runningCount => _sessions.length;

  int get backgroundCount =>
      _sessions.where((MiniappSession s) => s.isBackground).length;

  /// 当前在前台的会话（没有则为 null）。
  /// 名字不叫 foreground 是因为下面有个同名的 foreground(appId) 动作方法，
  /// 「状态」和「动作」用同一个词会让调用处完全读不出意图。
  MiniappSession? get foregroundSession => _sessionOf(_foregroundId);

  bool get hasForeground => foregroundSession != null;

  MiniappSession? sessionOf(String appId) => _sessionOf(appId);

  bool isRunning(String appId) => _sessionOf(appId) != null;

  bool isForeground(String appId) => _foregroundId == appId;

  MiniappSession? _sessionOf(String? appId) {
    if (appId == null) return null;
    for (final MiniappSession s in _sessions) {
      if (s.appId == appId) return s;
    }
    return null;
  }

  Future<MiniappSession> open({
    required String appId,
    required String title,
    InstalledPackage? installedPackage,
    String? localAsset,
    String? iconUrl,
    bool isTransient = false,
    List<MiniappPermission> declaredPermissions = const <MiniappPermission>[],
  }) async {
    final MiniappSession? existing = _sessionOf(appId);
    if (existing != null) {
      await foreground(appId);
      return existing;
    }

    final MiniappSession session = MiniappSession(
      appId: appId,
      title: title,
      installedPackage: installedPackage,
      localAsset: localAsset,
      iconUrl: iconUrl,
      isTransient: isTransient,
      declaredPermissions: declaredPermissions,
    );
    session.bindTitleListener(() {
      notifyListeners();
      // 小程序 setTitle 之后，最近任务卡片上的名字也要跟着变。
      // 走的是去抖版本：标题可能被逐字改（打字机效果），不值得每改一次就跨一次 Binder。
      _scheduleTaskDescriptionSync();
    });
    _sessions.add(session);

    // 回外壳层：不这么做的话，从详情页打开小程序后，系统返回键会被详情页
    // 这个路由先消费掉（用户会看到「按返回露出详情页」）。
    _popToShell();

    session.isForeground = true;
    session.lastActiveAt = DateTime.now();
    _foregroundId = appId;

    _syncToastTarget();
    // 最近任务里的卡片立刻换成这个小程序的名字和图标（见 _syncTaskDescription）
    _scheduleTaskDescriptionSync(immediate: true);
    unawaited(session.applyWindowFlags());
    // 应用清单：应用管理与权限管理器都从它取数据，靠它把 appId 显示成名字。
    // 登记时一并带上图标与入口地址，这样权限弹窗顶部那个图标
    // 不用等市场数据回来就能显示。
    unawaited(
      ApplicationRegistry.instance.record(
        appId: appId,
        name: title,
        icon: iconUrl,
        // 记的是包版本号而不是地址：应用管理里显示「装了哪一版」更有用
        url: installedPackage == null
            ? null
            : 'local:v${installedPackage.version}',
        opened: true,
      ),
    );
    // 图标顺手缓存到本机：应用管理列表不该为了显示图标再发一次网络请求
    unawaited(IconCacheService.instance.ensure(appId: appId, url: iconUrl));
    lemonLog('Host', '打开小程序 $appId（当前运行 ${_sessions.length} 个）');
    notifyListeners();
    return session;
  }

  /// 切到前台（不重新创建会话）
  Future<void> foreground(String appId) async {
    final MiniappSession? session = _sessionOf(appId);
    if (session == null) return;
    _popToShell();
    for (final MiniappSession s in _sessions) {
      s.isForeground = s.appId == appId;
    }
    session.lastActiveAt = DateTime.now();
    _foregroundId = appId;
    _syncToastTarget();
    // 从后台切回来：最近任务卡片也要换回这个小程序
    _scheduleTaskDescriptionSync(immediate: true);
    // 恢复这个会话的 JS 定时器（后台期间是被挂起的）
    try {
      await session.onResumeTimers?.call();
    } catch (e) {
      lemonLog('Host', 'resumeTimers 失败：$e');
    }
    await session.applyWindowFlags();
    notifyListeners();
  }

  /// 「返回主页」：把小程序层收起来，并回到外壳的主页 Tab。
  ///
  /// 与 [sendToBackground] 的区别只有一点，但很关键：
  ///   * sendToBackground 只是把这一层从绘制里摘出去，**用户还停在他原来那个
  ///     页面**（可能是详情页、设置页）。适合「稍后再回来看」。
  ///   * goHome 额外做两件事：把所有路由收回外壳层，并通知 AppShell 切到主页 Tab。
  ///     适合「我不想看这个了，回首页」。
  ///
  /// 会话**不销毁**：用户能从主页的后台应用角标或「后台应用」里回来。
  Future<void> goHome() async {
    // 窗口里没有「主页」可回：这张卡本身就代表那个小程序。
    if (windowMode) {
      final MiniappSession? current = foregroundSession;
      if (current != null) await close(current.appId);
      return;
    }
    final MiniappSession? session = foregroundSession;
    if (session != null) {
      await sendToBackground(session.appId);
    }
    _popToShell();
    // 通知外壳切到主页 Tab。AppShell 是唯一知道 Tab 的地方，
    // 所以这里只发一个信号，由它自己 setState。
    shellHomeRequested.value++;
  }

  /// 转后台运行：不销毁页面，只把它从绘制/命中里摘出去
  Future<void> sendToBackground(String appId) async {
    final MiniappSession? session = _sessionOf(appId);
    if (session == null || !session.isForeground) return;
    session.isForeground = false;
    _foregroundId = null;
    _syncToastTarget();
    // 屏幕上又变回宿主了：卡片恢复成「轻柠」
    _scheduleTaskDescriptionSync(immediate: true);
    try {
      await session.onPauseTimers?.call();
    } catch (e) {
      lemonLog('Host', 'pauseTimers 失败：$e');
    }
    await session.applyWindowFlags();
    lemonLog('Host', '$appId 转入后台');
    notifyListeners();
  }

  /// 关闭会话（真正销毁 WebView）
  Future<void> close(String appId) async {
    final int index = _sessions.indexWhere(
      (MiniappSession s) => s.appId == appId,
    );
    if (index < 0) return;
    final MiniappSession session = _sessions.removeAt(index);
    final bool wasForeground = session.appId == _foregroundId;
    if (wasForeground) _foregroundId = null;

    _syncToastTarget();
    // 关掉的是前台那个 → 卡片回到宿主；关的是后台那个 → 前台不变（这里会重新套用一次，
    // 内容相同，原生侧会直接跳过）
    _scheduleTaskDescriptionSync(immediate: true);
    notifyListeners();

    // 等这一帧的卸载走完再销毁 notifier：widget 的 dispose 里还会 removeListener
    WidgetsBinding.instance.addPostFrameCallback((_) => session.dispose());
    if (wasForeground) {
      await NativeBridge.setOrientation(MiniappOrientation.auto);
      await NativeBridge.setKeepScreenOn(false);
    }
    lemonLog('Host', '关闭小程序 $appId（剩余 ${_sessions.length} 个）');
    // 窗口里没有「空窗口」这种状态：最后一个会话没了，这张卡就该消失。
    if (windowMode && _sessions.isEmpty) {
      await NativeBridge.finishTask();
    }
  }

  @visibleForTesting
  void resetForTest() {
    _taskDescriptionTimer?.cancel();
    windowMode = false;
    for (final MiniappSession s in _sessions) {
      s.titleNotifier.removeListener(notifyListeners);
    }
    _sessions.clear();
    _foregroundId = null;
    _syncToastTarget();
    notifyListeners();
  }

  Future<void> closeAll() async {
    for (final String id
        in _sessions.map((MiniappSession s) => s.appId).toList()) {
      await close(id);
    }
  }

  /// 只关后台的，保留前台那个
  Future<void> closeBackground() async {
    final List<String> ids = _sessions
        .where((MiniappSession s) => s.isBackground)
        .map((MiniappSession s) => s.appId)
        .toList(growable: false);
    for (final String id in ids) {
      await close(id);
    }
  }

  /// 刷新会话活跃时间（用户与小程序交互时调用）
  void touch(String appId) {
    final MiniappSession? session = _sessionOf(appId);
    if (session == null) return;
    session.lastActiveAt = DateTime.now();
  }

  Future<bool> handleSystemBack() async {
    final MiniappSession? session = foregroundSession;
    if (session == null) return false;
    try {
      final bool handled = await session.onSystemBack?.call() ?? false;
      if (handled) return true;
    } catch (e) {
      lemonLog('Host', '返回键处理失败，按后台运行处理：$e');
    }
    // 窗口模式没有「后台」这个概念（系统切换器就是它的后台）：
    // 退到页面历史最前面，再按一次就该关掉这张任务卡。
    if (windowMode) {
      await close(session.appId);
      return true;
    }
    final String title = session.title;
    await sendToBackground(session.appId);
    AppTheme.showToast('「$title」已转入后台运行');
    return true;
  }

  Widget buildLayer() {
    return ListenableBuilder(
      listenable: this,
      builder: (BuildContext context, Widget? child) => _buildLayer(),
    );
  }

  /// 层内容：所有会话 + 一个「全部后台」时的空占位。
  Widget _buildLayer() {
    if (_sessions.isEmpty) return const SizedBox.shrink();
    final int foregroundIndex = _foregroundId == null
        ? -1
        : _sessions.indexWhere((MiniappSession s) => s.appId == _foregroundId);

    return ScaffoldMessenger(
      // 小程序里的 showToast 要显示在小程序这一层，否则会被覆盖层挡住
      key: lemonMiniappMessengerKey,
      child: IndexedStack(
        index: foregroundIndex < 0 ? _sessions.length : foregroundIndex,
        sizing: StackFit.expand,
        children: <Widget>[
          for (final MiniappSession session in _sessions)
            MiniappSessionView(
              key: ValueKey<String>(session.appId),
              session: session,
            ),
          // 全部在后台时的占位：IndexedStack 仍然会布局上面的 WebView（状态保住），
          // 但只绘制这个空的 —— 屏幕上什么都看不到，点击也穿过去。
          const SizedBox.expand(),
        ],
      ),
    );
  }

  // ------------------------------------------- 最近任务里的卡片（图标 / 名字）

  /// 标题去抖用的定时器（见 [_scheduleTaskDescriptionSync]）
  Timer? _taskDescriptionTimer;

  /// 安排一次「最近任务卡片」同步。
  ///
  /// [immediate]：用户明确的前台/后台切换，要立刻看到效果；
  /// 不带它则走 300ms 去抖 —— 小程序可能用 setTitle 逐字改标题，
  /// 每敲一个字就跨一次 Binder 传一张 Bitmap 纯属浪费。
  void _scheduleTaskDescriptionSync({bool immediate = false}) {
    _taskDescriptionTimer?.cancel();
    if (immediate) {
      unawaited(_syncTaskDescription());
      return;
    }
    _taskDescriptionTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_syncTaskDescription());
    });
  }

  /// 把「最近任务」里的那张卡片刷成当前状态。
  ///
  /// 只对独立窗口有意义：窗口那张卡代表的就是里面运行的小程序，卡片的标题
  /// 与图标必须跟着它走。宿主自己的卡永远是「轻柠」—— 用户明确要求
  /// 「主程序那张卡不变」，所以宿主（[windowMode] 为 false）直接返回，
  /// 连 `resetTaskDescription` 都不调。
  Future<void> _syncTaskDescription() async {
    // 宿主那张卡永远是「轻柠」—— 用户明确要求「主程序不变」。
    // 只有独立窗口才需要把卡片刷成小程序（窗口本身代表那个小程序）。
    // 宿主内嵌模式（自检 / 非 Android 降级）不去动系统卡片。
    if (!windowMode) return;
    final MiniappSession? session = foregroundSession;
    if (session == null) {
      return;
    }

    // 第一步：只用**本机已有**的图标立刻上卡，不等网络。
    // 标题是卡片上最要紧的信息，为了等一张图标把名字拖后几百毫秒不划算；
    // 没有图标时原生会沿用上一次那张，观感也说得过去。
    String? iconPath;
    try {
      iconPath = await IconCacheService.instance.pathOf(session.appId);
    } catch (e) {
      lemonLog('Host', '读小程序图标失败：$e');
    }
    if (iconPath == null) {
      try {
        iconPath = (await loadInstalledAppInfo(session.appId)).iconPath;
      } catch (e) {
        lemonLog('Host', '读包内图标失败：$e');
      }
    }
    if (_foregroundId != session.appId) return;
    await NativeBridge.setTaskDescription(
      label: session.title,
      iconPath: iconPath,
    );

    // 第二步：本机没有图但服务端给了地址 → 后台补一次，拿到后再刷一遍。
    // 下载失败会返回 null，什么都不做（卡片保持宿主图标）。
    final String url = session.iconUrl?.trim() ?? '';
    if (iconPath != null || url.isEmpty) return;
    String? fresh;
    try {
      fresh = await IconCacheService.instance.ensure(
        appId: session.appId,
        url: url,
      );
    } catch (e) {
      lemonLog('Host', '缓存小程序图标失败：$e');
    }
    if (fresh == null || _foregroundId != session.appId) return;
    await NativeBridge.setTaskDescription(
      label: session.title,
      iconPath: fresh,
    );
  }

  /// 小程序是覆盖在路由之上的层，宿主那一层的 SnackBar 会被它盖住，
  /// 所以前台状态变化时要告诉 AppTheme 该用哪个 ScaffoldMessenger。
  void _syncToastTarget() {
    miniappForegroundActive = _foregroundId != null;
  }

  /// 把全部路由收回到外壳层。
  /// 不这么做的话：从详情页打开小程序后，覆盖层虽然盖住了详情页，
  /// 但系统返回键会被详情页这个路由先消费掉，用户会看到「按返回露出详情页」。
  void _popToShell() {
    final NavigatorState? navigator = lemonNavigatorKey.currentState;
    if (navigator == null) return;
    navigator.popUntil((Route<dynamic> route) => route.isFirst);
  }
}

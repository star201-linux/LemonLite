// lib/pages/miniapp/miniapp_host.dart
//
// 小程序「多会话 + 后台运行」管理器。
//
// 为什么不能继续用「一个路由装一个小程序」：
//   「后台运行」要求在退出页面之后**页面状态还在**（WebView 不重载、JS 不重启），
//   而路由一旦 pop 就会 dispose，WebView 随之销毁。所以小程序不能是路由，
//   必须是一个**比路由活得久**的层。
//
// 做法：把全部会话放进一个宿主外壳内部的 Stack 层（见 MiniappLayer），
//   由 AppShell 把这一层叠在「底部导航 + 当前 Tab」**之上**。
//   * 它盖住底部导航与外壳内容；
//   * 但它自己不是路由，不参与 pop，所以能一直存活；
//   * 从它里面 push 出来的页面（权限管理等）是真实路由，
//     **天然压在它之上**，返回时回到小程序 —— 这正是我们要的层序。
//
// ⚠️ 为什么不用 OverlayEntry（这是 0.3 之前踩过的坑，别再改回去）：
//   Navigator 每次路由变化都会执行 overlay.rearrange(_allRouteOverlayEntries)，
//   而我们的 entry 不在那个列表里 —— 它会被当成「多余条目」重新插到
//   _entries 的最顶端（insertAll(_entries.length, old)）。
//   于是 push 权限管理页之后，那个页面落在覆盖层**下面**：
//   菜单点了「看起来没反应」，其实页面已经打开，只是被 WebView 盖住了。
//   把层放进 AppShell 的 Stack 就没有这个问题 —— 路由管理器管不到它，
//   而 Stack 的 z 序是写死的。
//
// 多个会话之间用 IndexedStack 切换：
//   IndexedStack 会**布局**所有子节点但只**绘制**选中的那个，
//   所以后台会话的 WebView 尺寸不会塌成 0（不会触发页面 resize 重排），
//   同时又不会被画到屏幕上、也收不到点击。
//
// 保活的诚实边界（README 里也写了）：
//   这是**进程内**保活。切到后台的会话不会被销毁、不会重新加载，
//   并会显式调用 WebView 的 resumeTimers() 让 JS 定时器继续跑；
//   但 Android 在内存紧张时仍可能回收整个进程，那不是框架能保证的。
//
// 依赖方向：miniapp_host → miniapp_page（要用会话视图）。
// miniapp_page 又会 import 本文件（菜单里的关闭/后台运行）。
// 这两个文件确实互相 import —— Dart 允许循环 import，且它们本就是
// 「同一个功能的管理层与视图层」，把视图工厂外置只会让调用方更啰嗦。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/globals.dart';
import '../../core/native_bridge.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/models/miniapp_session.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/application_registry.dart';
import '../../theme/app_theme.dart';
import 'miniapp_page.dart';

class MiniappHost extends ChangeNotifier {
  MiniappHost._();

  static final MiniappHost instance = MiniappHost._();

  final List<MiniappSession> _sessions = <MiniappSession>[];

  String? _foregroundId;

  /// 当前全部会话（顺序 = 打开顺序）
  List<MiniappSession> get sessions => List<MiniappSession>.unmodifiable(_sessions);

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

  MiniappSession? _sessionOf(String? appId) {
    if (appId == null) return null;
    for (final MiniappSession s in _sessions) {
      if (s.appId == appId) return s;
    }
    return null;
  }

  // -------------------------------------------------------------- 打开/关闭

  /// 打开一个小程序。
  ///
  /// 同一个 appId 只会有一个会话：重复打开等于把已有会话切到前台，
  /// 这样「后台运行中的小程序被再次点开」不会出现两份状态互相覆盖。
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
    session.bindTitleListener(notifyListeners);
    _sessions.add(session);

    // 回外壳层：不这么做的话，从详情页打开小程序后，系统返回键会被详情页
    // 这个路由先消费掉（用户会看到「按返回露出详情页」）。
    _popToShell();

    session.isForeground = true;
    session.lastActiveAt = DateTime.now();
    _foregroundId = appId;

    _syncToastTarget();
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
    // 让 WebView 的 JS 定时器继续跑：不可见的 WebView 会被 Chromium 降频，
    // resumeTimers() 是 Android WebView 官方给的「我在后台但别停我」开关。
    try {
      await session.onResumeTimers?.call();
    } catch (e) {
      lemonLog('Host', 'resumeTimers 失败：$e');
    }
    await session.applyWindowFlags();
    lemonLog('Host', '$appId 转入后台');
    notifyListeners();
  }

  /// 关闭会话（真正销毁 WebView）
  Future<void> close(String appId) async {
    final int index = _sessions.indexWhere((MiniappSession s) => s.appId == appId);
    if (index < 0) return;
    final MiniappSession session = _sessions.removeAt(index);
    final bool wasForeground = session.appId == _foregroundId;
    if (wasForeground) _foregroundId = null;

    _syncToastTarget();
    notifyListeners();

    // 等这一帧的卸载走完再销毁 notifier：widget 的 dispose 里还会 removeListener
    WidgetsBinding.instance.addPostFrameCallback((_) => session.dispose());
    if (wasForeground) {
      await NativeBridge.setOrientation(MiniappOrientation.auto);
      await NativeBridge.setKeepScreenOn(false);
    }
    lemonLog('Host', '关闭小程序 $appId（剩余 ${_sessions.length} 个）');
  }

  /// **仅供测试**：把宿主恢复到「没有任何会话」的干净状态。
  ///
  /// 为什么需要它：MiniappHost 是全局单例，而 close() 的销毁是「等下一帧」
  /// 的（addPostFrameCallback）—— 在没有持续帧的测试环境里，
  /// 上一条用例的会话会残留到下一條，导致断言互相污染。
  ///
  /// 生产代码不该调用它（它不走正常的关闭流程，不会通知 UI）。
  @visibleForTesting
  void resetForTest() {
    for (final MiniappSession s in _sessions) {
      s.titleNotifier.removeListener(notifyListeners);
    }
    _sessions.clear();
    _foregroundId = null;
    _syncToastTarget();
    notifyListeners();
  }

  Future<void> closeAll() async {
    for (final String id in _sessions.map((MiniappSession s) => s.appId).toList()) {
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

  // ------------------------------------------------------------ 返回键接管

  /// 系统返回键。返回 true 表示已被小程序消费，宿主不再处理。
  ///
  /// 语义：先在 WebView 内部回退历史；退无可退就**转后台**而不是销毁 ——
  /// 这正是「后台运行」这条能力存在的意义，用户可以从「后台应用」里回来或关掉。
  Future<bool> handleSystemBack() async {
    final MiniappSession? session = foregroundSession;
    if (session == null) return false;
    try {
      final bool handled = await session.onSystemBack?.call() ?? false;
      if (handled) return true;
    } catch (e) {
      lemonLog('Host', '返回键处理失败，按后台运行处理：$e');
    }
    final String title = session.title;
    await sendToBackground(session.appId);
    AppTheme.showToast('「$title」已转入后台运行');
    return true;
  }

  // -------------------------------------------------------------- Overlay

  /// 由 AppShell 把这一层叠在「底部导航 + 当前 Tab」之上（见 app.dart）。
  ///
  /// ⚠ 空判断必须放在 ListenableBuilder **里面**。
  /// 之前它在外面：打开第一个小程序时 `_sessions` 从空变非空，
  /// 但 AppShell 没有理由重建（它不监听 MiniappHost），于是 buildLayer()
  /// 不会重跑，这一层**永远停在那块 SizedBox.shrink()**。
  /// 症状就是「点小程序没反应 / 白屏 / 一进去像崩了」。
  /// 现在无论有没有会话都返回一个会监听 rebuild 的 builder，
  /// 空→非空、非空→空都会正确刷新。
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
            MiniappSessionView(key: ValueKey<String>(session.appId), session: session),
          // 全部在后台时的占位：IndexedStack 仍然会布局上面的 WebView（状态保住），
          // 但只绘制这个空的 —— 屏幕上什么都看不到，点击也穿过去。
          const SizedBox.expand(),
        ],
      ),
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

// lib/data/models/miniapp_session.dart
//
// 一个「正在运行的小程序」。
//
// 为什么它是个模型而不是页面状态：
//   小程序可以退到后台继续运行，于是「会话」必须活得比页面 widget 久。
//   桥接层（setPageOrientation / setKeepScreenOn / runInBackground）也要读写它，
//   把会话放在 data/models 下，桥接层就只依赖模型、不依赖 pages，层次是干净的：
//
//     models ← services ← bridge
//     models ← pages（host / session view）
//
// 它刻意只用可变的裸字段（而不是状态机）：会话状态只有「前台/后台」「方向」「常亮」
// 三件小事，再造一层状态机只会让阅读成本变高，而不会更安全。

import 'package:flutter/foundation.dart';

import '../../core/native_bridge.dart';
import '../services/miniapp_package_service.dart';
import 'miniapp_permission.dart';

class MiniappSession {
  MiniappSession({
    required this.appId,
    required String title,
    this.installedPackage,
    this.localAsset,
    this.iconUrl,
    this.isTransient = false,
    this.declaredPermissions = const <MiniappPermission>[],
  }) : titleNotifier = ValueNotifier<String>(title) {
    titleNotifier.addListener(_onTitleChanged);
  }

  final String appId;

  /// 本机已安装的小程序包（0.6 起主要入口）。
  ///
  /// 它指向 `miniapps/<appId>/<version>/`，WebView 用 file:// 打开其中的
  /// 入口文件 —— 断网也能用，而且「装的是哪一版」是明确的。
  final InstalledPackage? installedPackage;

  /// 本地 assets 入口
  final String? localAsset;

  final String? iconUrl;

  /// 临时会话（开发者选项里的本地包调试）。同样支持后台运行 ——
  /// 少一个特例就少一处不一致。
  final bool isTransient;

  /// 市场数据（index.json）里声明的能力；打开前已经一次性确认过。
  /// 保留在会话上，是为了让权限管理/排障时能回答"它当初声明了什么"。
  final List<MiniappPermission> declaredPermissions;

  /// 宿主 AppBar / 后台列表显示的标题（小程序 setTitle 会改它）
  final ValueNotifier<String> titleNotifier;

  final DateTime openedAt = DateTime.now();
  DateTime lastActiveAt = DateTime.now();

  /// 是否在前台（同一时刻最多一个为 true）
  bool isForeground = false;

  /// 页面方向标记（小程序用 setPageOrientation 设置）
  MiniappOrientation orientation = MiniappOrientation.auto;

  /// 是否屏幕常亮 = 不允许熄屏（小程序用 setKeepScreenOn 设置）
  bool keepScreenOn = false;

  /// 会话已被关闭（回调里用来避免操作已销毁的 WebView）
  bool isClosed = false;

  /// 由会话视图注入：处理系统返回键，返回 true 表示已消费
  Future<bool> Function()? onSystemBack;

  /// 由会话视图注入：切到后台时让 WebView 的 JS 定时器继续跑
  Future<void> Function()? onResumeTimers;

  /// 由会话视图注入：重新加载页面
  Future<void> Function()? onReload;

  void Function()? _titleListener;

  String get title => titleNotifier.value;

  /// 入口地址（后台列表里展示用）
  String get entry =>
      installedPackage?.entryUri ?? localAsset ?? '（无入口）';

  /// WebView 要加载的 file:// 地址（本地包时非空）
  String? get fileUri => installedPackage?.entryUri;

  bool get isBackground => !isForeground;

  void _onTitleChanged() => _titleListener?.call();

  /// 让宿主在标题变化时收到通知（由 MiniappHost 在创建会话后挂上）
  void bindTitleListener(void Function() listener) {
    _titleListener = listener;
  }

  /// 标记方向。只有前台会话才真的落到窗口上（见 applyWindowFlags）。
  Future<void> setOrientation(MiniappOrientation value) async {
    orientation = value;
    if (isForeground) await NativeBridge.setOrientation(value);
  }

  /// 标记是否常亮（= 不允许熄屏）。
  Future<void> setKeepScreenOn(bool value) async {
    keepScreenOn = value;
    if (isForeground) await NativeBridge.setKeepScreenOn(value);
  }

  /// 把「方向 + 常亮」落到系统窗口上。
  ///
  /// 只有前台的会话才允许影响窗口；后台会话一律恢复默认，
  /// 否则会出现「小程序在后台，整个 App 却还锁着横屏 / 常亮」。
  Future<void> applyWindowFlags() async {
    if (!NativeBridge.isSupported) return;
    if (isForeground) {
      await NativeBridge.setOrientation(orientation);
      await NativeBridge.setKeepScreenOn(keepScreenOn);
    } else {
      await NativeBridge.setOrientation(MiniappOrientation.auto);
      await NativeBridge.setKeepScreenOn(false);
    }
  }

  void dispose() {
    isClosed = true;
    titleNotifier.removeListener(_onTitleChanged);
    titleNotifier.dispose();
    _titleListener = null;
    onSystemBack = null;
    onResumeTimers = null;
    onReload = null;
  }
}

/// 页面方向的字符串 ↔ 枚举互转（桥接参数、持久化、UI 三处共用一套写法）
class MiniappOrientationX {
  const MiniappOrientationX._();

  static const List<String> allIds = <String>[
    'portrait',
    'landscape',
    'portraitReverse',
    'landscapeReverse',
    'auto',
  ];

  static String idOf(MiniappOrientation value) => switch (value) {
    MiniappOrientation.portrait => 'portrait',
    MiniappOrientation.landscape => 'landscape',
    MiniappOrientation.portraitReverse => 'portraitReverse',
    MiniappOrientation.landscapeReverse => 'landscapeReverse',
    MiniappOrientation.auto => 'auto',
  };

  static String labelOf(MiniappOrientation value) => switch (value) {
    MiniappOrientation.portrait => '竖屏',
    MiniappOrientation.landscape => '横屏',
    MiniappOrientation.portraitReverse => '反向竖屏',
    MiniappOrientation.landscapeReverse => '反向横屏',
    MiniappOrientation.auto => '自动',
  };

  /// 宽松解析：兼容 `landscape-reverse` / `reverseLandscape` / 大小写差异
  static MiniappOrientation? parse(Object? raw) {
    final String value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return null;
    final String key = value
        .replaceAll(RegExp(r'[^A-Za-z]'), '')
        .toLowerCase();
    return switch (key) {
      'portrait' => MiniappOrientation.portrait,
      'landscape' => MiniappOrientation.landscape,
      'portraitreverse' || 'reverseportrait' => MiniappOrientation.portraitReverse,
      'landscapereverse' || 'reverselandscape' => MiniappOrientation.landscapeReverse,
      'auto' || 'unspecified' || 'system' => MiniappOrientation.auto,
      _ => null,
    };
  }
}

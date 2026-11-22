// lib/core/globals.dart
//
// 全局单例与常量。
//
// 设计意图：JSBridge 的回调发生在 WebView 的事件流里，很多时候**不在 Widget 树内**，
// 拿不到 BuildContext。所以这里统一暴露 GlobalKey，让桥接层也能弹 SnackBar、读 MediaQuery、做路由跳转。
// （这是对原始目录结构的一点补充：把跨层共享的东西集中到 core/，避免各处重复声明。）

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'run_log.dart';

/// 全局路由 key：桥接层的 navigateBack / 页面跳转都靠它。
final GlobalKey<NavigatorState> lemonNavigatorKey = GlobalKey<NavigatorState>();

/// 全局 ScaffoldMessenger key：桥接层的 showToast 靠它。
final GlobalKey<ScaffoldMessengerState> lemonScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 小程序覆盖层的 ScaffoldMessenger key。
///
/// 小程序不是路由，而是插在 Navigator Overlay 上的一个层，**盖在所有路由之上**。
/// 所以宿主那一层的 SnackBar 会被它挡住 —— 前台有小程序时，Toast 必须交给这一层。
final GlobalKey<ScaffoldMessengerState> lemonMiniappMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 自检截图用的根 RepaintBoundary key。
///
/// 只在传了 `--dart-define=LEMONLITE_AUTOTEST` 的调试包里被用到；
/// 正式包里它只是一个多余的 GlobalKey，没有任何行为副作用。
final GlobalKey kAppCaptureBoundaryKey = GlobalKey();

final ValueNotifier<int> shellHomeRequested = ValueNotifier<int>(0);

bool miniappForegroundActive = false;

/// 框架名（getSystemInfo 会返回给小程序的 framework 字段）
const String kFrameworkName = 'LemonLite';

/// 框架版本。
///
/// 0.2.0：小程序包引入 metadata.json（身份 / 版本 / 入口 / 权限声明），
///        权限页改为按声明展示；移除页面扩展与插件 wasm。
const String kFrameworkVersion = '0.2.0';

/// index.json 的 schema 版本（当前支持的版本号）
const int kSupportedSchemaVersion = 1;

/// 默认市场服务器地址。
///
/// 支持**构建期覆盖**，方便打「指向测试环境的安装包」：
/// ```bash
/// flutter build apk --dart-define=LEMONLITE_SERVER=https://your-test-host/lemonlite
/// ```
/// 不传时就是下面的正式默认值（源码行为不变）。
const String kDefaultServerUrl = String.fromEnvironment(
  'LEMONLITE_SERVER',
  defaultValue: 'https://lemonlite.cc.cd',
);

void lemonLog(String tag, Object? message) {
  if (kDebugMode) {
    debugPrint('[$kFrameworkName/$tag] $message');
  }
  RunLog.instance.add(tag, message);
}

/// 记一条错误级日志（额外打一次 debugPrint，并进导出文件）
void lemonLogError(String tag, Object? message) {
  RunLog.instance.error(tag, message);
}

/// 当前屏幕的 MediaQueryData（桥接层读屏幕尺寸用）。
/// 拿不到时返回 null，调用方自行兜底。
MediaQueryData? get currentMediaQuery {
  final BuildContext? ctx = lemonNavigatorKey.currentContext;
  if (ctx == null) return null;
  return MediaQuery.maybeOf(ctx);
}

/// 当前主题的 ColorScheme（桥接层读主题色用，已包含动态取色结果）。
ColorScheme? get currentColorScheme {
  final BuildContext? ctx = lemonNavigatorKey.currentContext;
  if (ctx == null) return null;
  return Theme.of(ctx).colorScheme;
}

/// App 自身信息（版本号用于「连点 8 次进入开发者模式」）。
class AppInfo {
  const AppInfo._();

  static String version = '0.0.0';
  static String buildNumber = '0';
  static String packageName = 'xyz.star201.lemonlite';
  static bool _loaded = false;

  /// 在 main() 里 await 一次，之后同步读取。
  static Future<void> load() async {
    if (_loaded) return;
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      version = info.version;
      buildNumber = info.buildNumber;
      packageName = info.packageName;
    } catch (e) {
      // 极端情况下（例如平台通道未就绪）读取失败不应该让 App 起不来
      lemonLog('AppInfo', '读取版本信息失败，使用默认值：$e');
    }
    _loaded = true;
  }

  static String get versionLabel => 'v$version+$buildNumber';
}

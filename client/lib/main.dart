// lib/main.dart
//
// 应用入口。
//
// 两个初始化动作刻意放在 runApp 之前 await：
//  1. SharedPreferences —— 主题偏好要在第一帧就拿到，否则会出现「先亮后暗」的闪烁
//  2. PackageInfo       —— 版本号在设置页要同步显示
// 两者都做了失败兜底，不会因为插件异常导致白屏。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'app.dart';
import 'core/globals.dart';
import 'core/run_log.dart';
import 'data/services/account_service.dart';
import 'data/services/application_registry.dart';
import 'data/services/download_service.dart';
import 'data/services/permission_service.dart';
import 'data/services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 尽早接上异常钩子：之后的任何异常都会进日志缓冲区，
  // 用户一键导出就能看到。这是「release 包也能排障」的基石。
  RunLog.instance.installErrorHooks();

  final SettingsService settings = await SettingsService.init();
  // 权限服务必须在任何小程序页面之前就绪：桥接层每次调用都会查它，
  // 而它是同步单例（没有异步初始化成本），所以直接 init 不用 await。
  PermissionService.init();
  // 应用清单的唯一真相来源。应用管理、权限管理器与存储页都从它取应用列表，
  // 所以它必须比任何页面都早就绪。
  ApplicationRegistry.init();
  // 下载管理：先把落盘的记录读回来，再在后台回查未完成任务的真实进度。
  // start() 是同步的（读 SharedPreferences），不会拖慢启动。
  DownloadService.init().start();
  // 账号：只从本地读 token，**不等网络**。
  // 没网时不该让 App 卡在「正在校验登录态」上 —— 校验在后台静默做。
  await AccountService.instance.init(settings);
  await AppInfo.load();

  // 把版本号写进日志头部：导出文件第一屏就能看出是哪个包出的问题
  RunLog.instance.appVersion = AppInfo.versionLabel;
  RunLog.instance.frameworkVersion = kFrameworkVersion;

  // 查询原生侧的 WebView 预检结果（数据目录锁冲突时走了独立目录）。
  // 查不到（非 Android / 通道未注册）就静默跳过 —— 那些环境本来也没有这个概念。
  try {
    const MethodChannel probe = MethodChannel('lemonlite/native');
    final Object? suffix = await probe.invokeMethod<Object?>('getWebviewPreflight');
    if (suffix == true) {
      lemonLogError(
        'main',
        'WebView 数据目录锁冲突：本进程已切换到独立数据目录，'
        'WebView 的 cookies/localStorage 会是空的（小程序 storage 不受影响）',
      );
    }
  } catch (_) {
    // 非 Android 或通道未就绪：忽略
  }

  lemonLog('main', '启动 ${AppInfo.versionLabel}，服务器：${settings.serverUrl}');

  runApp(LemonLiteApp(settings: settings));
}

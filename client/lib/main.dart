
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'app.dart';
import 'core/globals.dart';
import 'core/run_log.dart';
import 'data/models/miniapp_metadata.dart';
import 'data/services/account_service.dart';
import 'data/services/application_registry.dart';
import 'data/services/download_service.dart';
import 'data/services/market_cache_service.dart';
import 'data/services/permission_service.dart';
import 'data/services/settings_service.dart';
import 'pages/miniapp/miniapp_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 尽早接上异常钩子：之后的任何异常都会进日志缓冲区，
  // 用户一键导出就能看到。这是「release 包也能排障」的基石。
  RunLog.instance.installErrorHooks();

  // 包里的 metadata.json 可能写 minFrameworkVersion；它要能和当前框架版本比。
  MiniappMetadata.currentFramework = kFrameworkVersion;

  final String initialRoute =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final MiniappWindowArgs? windowArgs = MiniappWindowArgs.parse(initialRoute);
  if (windowArgs != null) {
    await runMiniappWindow(windowArgs);
    return;
  }

  final SettingsService settings = await SettingsService.init();
  // 市场本地缓存（主页 / 搜索的分页快照）。放在 SettingsService 之后：
  // 它本身只是 SharedPreferences 之上的一层，没有异步初始化成本。
  MarketCacheService.init(settings);
  PermissionService.init();
  // 应用清单的唯一真相来源。应用管理、权限管理器与存储页都从它取应用列表，
  // 所以它必须比任何页面都早就绪。
  ApplicationRegistry.init();
  // 下载管理：先把落盘的记录读回来，再在后台回查未完成任务的真实进度。
  // start() 是同步的（读 SharedPreferences），不会拖慢启动。
  DownloadService.init().start();
  await AccountService.instance.init(settings);
  await AppInfo.load();

  // 把版本号写进日志头部：导出文件第一屏就能看出是哪个包出的问题
  RunLog.instance.appVersion = AppInfo.versionLabel;
  RunLog.instance.frameworkVersion = kFrameworkVersion;

  // 查询原生侧的 WebView 预检结果（数据目录锁冲突时走了独立目录）。
  // 查不到（非 Android / 通道未注册）就静默跳过 —— 那些环境本来也没有这个概念。
  try {
    const MethodChannel probe = MethodChannel('lemonlite/native');
    final Object? suffix = await probe.invokeMethod<Object?>(
      'getWebviewPreflight',
    );
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

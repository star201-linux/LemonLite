// test/miniapp_window_test.dart
//
// 「小程序独立窗口」的两条契约：
//
//   1. 路由解析：原生用 `/miniapp-window?appId=…&title=…` 启动第二个进程，
//      解析失败必须**安静地退回宿主**（而不是抛异常黑屏）。
//   2. 窗口语义：窗口模式下「关闭 = 结束这张任务卡」，不是宿主里的
//      「转后台」。这两件事在同一个 MiniappHost 上靠 windowMode 分流，
//      分错了会出现「点关闭，窗口还在」或者「在宿主里点关闭，App 没了」。
//
// 原生侧（MiniappTaskActivity / FLAG_ACTIVITY_NEW_DOCUMENT）没法在单测里
// 验证，所以这里只钉住 Dart 能决定的那部分；Kotlin 靠编译 + 真机验证。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/core/native_bridge.dart';
import 'package:lemonlite/data/services/application_registry.dart';
import 'package:lemonlite/data/services/permission_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:lemonlite/pages/miniapp/miniapp_host.dart';
import 'package:lemonlite/pages/miniapp/miniapp_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MiniappWindowArgs', () {
    test('只有窗口路由才算', () {
      expect(MiniappWindowArgs.matches('/'), isFalse);
      expect(MiniappWindowArgs.matches('/settings'), isFalse);
      expect(MiniappWindowArgs.matches('/miniapp-window'), isTrue);
      expect(MiniappWindowArgs.matches('/miniapp-window?appId=a'), isTrue);
    });

    test('解析出 appId 与标题', () {
      final MiniappWindowArgs? args = MiniappWindowArgs.parse(
        '/miniapp-window?appId=com.example.ledger&title=%E8%AE%B0%E8%B4%A6%E6%9C%AC',
      );
      expect(args, isNotNull);
      expect(args!.appId, 'com.example.ledger');
      expect(args.title, '记账本'); // %E8%AE%B0%E8%B4%A6%E6%9C%AC
    });

    test('没有标题时用 appId 兜底（卡片上总得有个能认的值）', () {
      final MiniappWindowArgs? args =
          MiniappWindowArgs.parse('/miniapp-window?appId=com.example.clock');
      expect(args!.title, 'com.example.clock');
    });

    test('缺 appId / 非窗口路由返回 null，调用方按宿主流程继续', () {
      expect(MiniappWindowArgs.parse('/miniapp-window'), isNull);
      expect(MiniappWindowArgs.parse('/miniapp-window?appId=%20'), isNull);
      expect(MiniappWindowArgs.parse('/'), isNull);
    });
  });

  group('窗口模式下的关闭语义', () {
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() async {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, (MethodCall call) async {
            calls.add(call);
            return true;
          });
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();
      PermissionService.init();
      ApplicationRegistry.init();
      // 窗口由 main() 的窗口分支置位；测试里手动摆成同一个状态
      MiniappHost.instance.windowMode = true;
    });

    tearDown(() {
      MiniappHost.instance.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeBridge.channel, null);
    });

    testWidgets('窗口里关掉最后一个会话 → 结束任务（而不是转后台）', (WidgetTester tester) async {
      await MiniappHost.instance.open(
        appId: 'com.example.ledger',
        title: '记账本',
        isTransient: true,
      );
      await tester.pump();
      calls.clear();

      await MiniappHost.instance.close('com.example.ledger');
      await tester.pump();

      expect(
        calls.map((MethodCall c) => c.method),
        contains('finishTask'),
        reason: '窗口里没有「空窗口」这种状态，最后一个会话没了就该结束这张卡',
      );
      expect(MiniappHost.instance.sessionOf('com.example.ledger'), isNull);
    });

    testWidgets('窗口里按下返回（退无可退）→ 结束任务', (WidgetTester tester) async {
      await MiniappHost.instance.open(
        appId: 'com.example.ledger',
        title: '记账本',
        isTransient: true,
      );
      await tester.pump();
      calls.clear();

      // 没有注入 onSystemBack（等价于 WebView 没有可回退的历史）
      final bool handled = await MiniappHost.instance.handleSystemBack();
      await tester.pump();

      expect(handled, isTrue);
      expect(calls.map((MethodCall c) => c.method), contains('finishTask'));
    });

    testWidgets('宿主模式不受影响：关闭只销毁会话，不动任务', (WidgetTester tester) async {
      MiniappHost.instance.windowMode = false;
      await MiniappHost.instance.open(
        appId: 'com.example.ledger',
        title: '记账本',
        isTransient: true,
      );
      await tester.pump();
      calls.clear();

      await MiniappHost.instance.close('com.example.ledger');
      await tester.pump();

      expect(calls.map((MethodCall c) => c.method), isNot(contains('finishTask')));
    });
  });
}

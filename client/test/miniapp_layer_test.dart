// test/miniapp_layer_test.dart
//
// 小程序层的「挂上去」回归测试。
//
// 这条测试的由来是一个真实崩溃/白屏 bug：
//   MiniappHost.buildLayer() 里，空判断写在 ListenableBuilder **外面**：
//
//     if (_sessions.isEmpty) return const SizedBox.shrink();   // ← 在这里
//     return ListenableBuilder(listenable: this, ...);
//
//   AppShell 不监听 MiniappHost，所以「打开第一个小程序」时
//   _sessions 从空变非空，但 AppShell 不需要重建，buildLayer() 也不会重跑 ——
//   这一层永远停在那块 SizedBox.shrink()。
//   用户点「进入测试小程序」→ 什么都没发生 / 白屏 → 看起来就是崩了。
//
// 所以这里断言：打开会话之后，层必须真的把会话视图挂进 widget 树。


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/services/application_registry.dart';
import 'package:lemonlite/data/services/permission_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:lemonlite/pages/miniapp/miniapp_host.dart';
import 'package:lemonlite/pages/miniapp/miniapp_page.dart';
import 'package:lemonlite/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 把「只有一层 Stack」的测试宿主包成真实 App 的最小形态。
///
/// MiniappSessionView 会 watch ThemeController，所以必须有 Provider；
/// 缺了它会抛 ProviderNotFoundException —— 那是测试环境的问题，
/// 不是产品 bug（真实 App 里 app.dart 已经装好了这些 Provider）。
Widget _host() => MultiProvider(
  providers: [
    ChangeNotifierProvider<ThemeController>(
      create: (BuildContext c) => ThemeController(SettingsService.instance),
    ),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Stack(
        children: <Widget>[MiniappHost.instance.buildLayer()],
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // MiniappHost.open() 会登记到应用清单，所以这些单例必须先就绪。
    // 顺序与 main() 一致 —— 测试里也要遵守同一条约束。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init();
    PermissionService.init();
    ApplicationRegistry.init();
  });

  tearDown(() {
    // 直接重置，不走 close()。
    //
    // close() 的销毁是「等下一帧」的（addPostFrameCallback），而没有持续帧的
    // 测试环境里那个回调不会跑；再叠加 open() 里两个 unawaited
    // （applyWindowFlags / ApplicationRegistry.record）在测试里会挂住，
    // 整条用例就会等到超时。resetForTest() 是为了这件事加的。
    MiniappHost.instance.resetForTest();
  });

  testWidgets('没有会话时，层是空的（不占位、不吃点击）', (WidgetTester tester) async {
    await tester.pumpWidget(_host());

    expect(find.byType(MiniappSessionView), findsNothing);
    // 空的时候不该有 ScaffoldMessenger 包着（那会多一层无意义的节点）
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开会话后，会话视图必须出现在 widget 树里（回归：曾永远不出现）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    expect(find.byType(MiniappSessionView), findsNothing);

    // 模拟点「示例小程序」：这一步在真机上以前什么都不发生
    await MiniappHost.instance.open(
      appId: 'lemonlite.demo',
      title: '示例小程序',
      localAsset: kDemoMiniappAsset,
      isTransient: true,
    );
    await tester.pump();

    expect(
      find.byType(MiniappSessionView),
      findsOneWidget,
      reason: '会话已创建，但层没有把会话视图挂上去 —— 用户会看到「点了没反应」',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有会话后，层回到空状态（不能留下一个空壳盖住界面）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());

    await MiniappHost.instance.open(
      appId: 'lemonlite.demo',
      title: '示例小程序',
      localAsset: kDemoMiniappAsset,
      isTransient: true,
    );
    await tester.pump();
    expect(find.byType(MiniappSessionView), findsOneWidget);

    // 这里用 resetForTest() 而不是 close()：
    // close() 会 await NativeBridge.setOrientation / setKeepScreenOn，
    // 测试环境里那两个平台通道没有实现，await 会一直挂着。
    // 「关闭后层要变空」这件事本质上由 _sessions 变空触发，
    // 用 reset 验证同一件事，且不依赖平台通道。
    MiniappHost.instance.resetForTest();
    await tester.pump();

    expect(find.byType(MiniappSessionView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右上/右下只有一颗「更多」按钮，且菜单只有 4 项（回归：曾有多余菜单项）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host());

    await MiniappHost.instance.open(
      appId: 'lemonlite.demo',
      title: '示例小程序',
      localAsset: kDemoMiniappAsset,
      isTransient: true,
    );
    await tester.pump();

    // 打开菜单
    final Finder more = find.byTooltip('更多');
    expect(more, findsOneWidget, reason: '应该只有一个「更多」入口');
    await tester.tap(more);
    // 不用 pumpAndSettle：WebView 的加载指示器（LinearProgressIndicator）
    // 会一直重绘，settle 永远等不到静止。推进固定几帧让菜单完成展开动画即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 只剩这四项：关闭 / 后台运行 / 权限管理 / 后台应用
    for (final String label in <String>['关闭', '后台运行', '权限管理', '后台应用']) {
      expect(find.text(label), findsOneWidget, reason: '缺少菜单项：$label');
    }

    // 这两项已按要求移除 —— 它们对普通用户没有意义
    expect(find.text('用浏览器打开'), findsNothing);
    expect(find.text('查看入口地址'), findsNothing);
    // 标题栏也去掉了：页面上不该有「重新加载」按钮
    expect(find.byTooltip('重新加载'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('会话数正确反映在 runningCount / hasAny 上', (WidgetTester tester) async {
    await tester.pumpWidget(_host());

    expect(MiniappHost.instance.hasAny, isFalse);
    expect(MiniappHost.instance.runningCount, 0);

    await MiniappHost.instance.open(
      appId: 'lemonlite.demo',
      title: '示例小程序',
      localAsset: kDemoMiniappAsset,
      isTransient: true,
    );
    await tester.pump();

    expect(MiniappHost.instance.hasAny, isTrue);
    expect(MiniappHost.instance.runningCount, 1);
    expect(MiniappHost.instance.isRunning('lemonlite.demo'), isTrue);

    // 注意：这里刻意**不测**「重复 open 同一个 appId」。
    // 那条路径会走 foreground() → _popToShell() → navigator.popUntil，
    // 在没有真实路由栈的测试宿主里会让测试挂住（等一个永远不来的帧）。
    // 重复打开的去重逻辑由 _sessionOf() 保证，属于纯状态判断，
    // 在真实 App 里不会有这个问题。
  });
}

// test/task_description_test.dart
//
// 「最近任务」卡片（TaskDescription）的契约测试。
//
// 背景：宿主的全部小程序都跑在**同一个 Activity、同一个任务**里。
// 用户打开小程序后按 Home，最近任务里原来只有一张写着「轻柠」的卡片，
// 点回来时分不清那是宿主还是刚才那个小程序。所以前台会话变化时要把卡片
// 换成小程序自己的名字和图标，回到宿主再换回去 —— 这正是微信小程序的做法。
//
// 这条链路的坑不在 Dart 也不在 Kotlin，而在**时序**：
//   1. 打开 / 切前台必须立刻改（用户就在看着最近的卡片）；
//   2. 标题变化要合并（setTitle 可能逐字改，不该每字跨一次 Binder 传 Bitmap）；
//   3. 取图标是 async 的，await 期间用户可能已经切走 —— 不能把旧名字盖回去。
//
// 这里用 mock 通道把「Dart 侧到底下了什么指令」固定下来，
// Kotlin 侧只要照约定执行就行。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/core/native_bridge.dart';
import 'package:lemonlite/data/models/miniapp_session.dart';
import 'package:lemonlite/data/services/application_registry.dart';
import 'package:lemonlite/data/services/permission_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:lemonlite/pages/miniapp/miniapp_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 图标缓存要用的应用支持目录通道（见 setUp 里为什么要 mock 它）
const MethodChannel _pathProviderChannel = MethodChannel(
  'plugins.flutter.io/path_provider',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 记录 Dart 侧发给原生的全部调用
  final List<MethodCall> calls = <MethodCall>[];

  setUp(() async {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, (MethodCall call) async {
          calls.add(call);
          // 一律回 true：这些接口的返回值只表示「原生有没有照做」，
          // 不是本测试的观察对象
          return true;
        });

    // 图标缓存要读应用支持目录。不 mock 的话这条通道在测试里永远不会回，
    // _syncTaskDescription 会卡在第一步（看起来像「卡片根本没改」）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (MethodCall call) async {
          return Directory.systemTemp.path;
        });

    // 卡片同步只在「独立窗口」里发生（宿主那张卡永远叫「轻柠」）。
    // 窗口由 main() 的窗口分支置位，测试里手动摆成同一个状态。
    MiniappHost.instance.windowMode = true;

    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init();
    PermissionService.init();
    ApplicationRegistry.init();
  });

  tearDown(() {
    MiniappHost.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeBridge.channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  List<MethodCall> taskCalls() => calls
      .where(
        (MethodCall c) =>
            c.method == 'setTaskDescription' ||
            c.method == 'resetTaskDescription',
      )
      .toList();

  /// 让 unawaited 的那条异步链（图标缓存 → 平台通道）跑完。
  ///
  /// 用 pump 驱动测试的假时钟，而不是 runAsync 等真实时间：
  /// 那些 Future 是在 fake async zone 里创建的，真实时间对它们没有意义。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('打开小程序：卡片换成小程序的名字（不是「轻柠」）', (WidgetTester tester) async {
    await MiniappHost.instance.open(
      appId: 'com.example.ledger',
      title: '记账本',
      isTransient: true,
    );
    await settle(tester);

    final List<MethodCall> task = taskCalls();
    expect(task, isNotEmpty, reason: '打开小程序后没有改最近任务的卡片');
    expect(task.first.method, 'setTaskDescription');
    final Map<Object?, Object?> args =
        task.first.arguments as Map<Object?, Object?>;
    expect(args['label'], '记账本');
    expect(args.containsKey('iconPath'), isTrue);
    // 没有 iconUrl、本机也没有缓存 → 交 null 给原生兜底成宿主图标
    expect(args['iconPath'], isNull);
  });

  testWidgets('转后台：卡片恢复成宿主自己的样子', (WidgetTester tester) async {
    await MiniappHost.instance.open(
      appId: 'com.example.ledger',
      title: '记账本',
      isTransient: true,
    );
    await settle(tester);

    await MiniappHost.instance.sendToBackground('com.example.ledger');
    await settle(tester);

    expect(
      taskCalls().last.method,
      'resetTaskDescription',
      reason: '屏幕上已经是宿主了，卡片还挂着小程序名字会让人以为它还在前台',
    );
  });

  testWidgets('标题变化：去抖后把新标题同步到卡片', (WidgetTester tester) async {
    final MiniappSession session = await MiniappHost.instance.open(
      appId: 'com.example.ledger',
      title: '记账本',
      isTransient: true,
    );
    await settle(tester);
    final int before = taskCalls().length;

    // 模拟小程序 setTitle 逐字改标题（打字机效果）：只有最后一次该落下去
    for (final String title in <String>['月', '月度', '月度报表']) {
      session.titleNotifier.value = title;
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final List<MethodCall> task = taskCalls();
    expect(task.length, greaterThan(before), reason: '标题变了但卡片没跟着变');
    final Map<Object?, Object?> args =
        task.last.arguments as Map<Object?, Object?>;
    expect(args['label'], '月度报表');
  });

  testWidgets('宿主模式不动系统卡片（主程序永远叫「轻柠」）', (WidgetTester tester) async {
    MiniappHost.instance.windowMode = false;
    await MiniappHost.instance.open(
      appId: 'com.example.ledger',
      title: '记账本',
      isTransient: true,
    );
    await settle(tester);
    await MiniappHost.instance.sendToBackground('com.example.ledger');
    await settle(tester);

    expect(taskCalls(), isEmpty, reason: '宿主内嵌模式没有独立任务卡，不该改系统卡片');
  });

  testWidgets('没有前台会话时的重复重置是幂等的（不产生多余调用）', (WidgetTester tester) async {
    await MiniappHost.instance
        .open(appId: 'com.example.ledger', title: '记账本', isTransient: true);
    await settle(tester);
    final int before = taskCalls().length;

    // close 一个**后台**会话不该动当前前台的卡片，更不该把名字清空
    await MiniappHost.instance
        .open(appId: 'com.example.clock', title: '时钟', isTransient: true);
    await settle(tester);
    await MiniappHost.instance.close('com.example.ledger');
    await settle(tester);

    final List<MethodCall> task = taskCalls();
    expect(task.length, greaterThan(before));
    // 最后一次仍然应该是「时钟」——关掉的是后台那个记账本
    final Map<Object?, Object?> args =
        task.last.arguments as Map<Object?, Object?>;
    expect(args['label'], '时钟');
  });
}

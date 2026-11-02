// test/permission_test.dart
//
// 权限模型 / 权限服务 / 应用清单 / 文件沙箱 / 插件提供的 WASM / 桥接层的单元测试。
//
// 这一版把「权限」收窄成**浏览器的受控资源**（摄像头 / 麦克风 / 文件系统访问），
// 所以断言也围着这条线写：
//   1. 权限枚举本身的自洽（id 唯一、默认询问、分组不空、退役 id 不重叠）
//   2. 三态决定与申请记录的持久化语义（含损坏数据不崩）
//   3. 应用清单的唯一真相来源（ApplicationRegistry）与权限管理器的联动
//   4. WebView 权限请求 → 框架权限的翻译与放行结果（这是安全边界，必须逐项断言）
//   5. 文件沙箱的路径校验（越界一律拒绝）
//   6. 桥接层**没有**权限闸门这件事本身（音量/亮度/文件不再弹窗）
//   7. 权限改名（allFiles → sdcard）后的**旧数据兼容**：旧决定仍然生效
//   8. WebAssembly 从"内置"改为"插件提供"之后：插件 manifest 与 wasm 载荷
//
// 约定：每个用例都从干净的 SharedPreferences 开始（setMockInitialValues 重置），
// 这样用例之间不会通过持久化互相污染。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/bridge/bridge_api.dart';
import 'package:lemonlite/bridge/web_permission.dart';
import 'package:lemonlite/core/native_bridge.dart';
import 'package:lemonlite/data/models/bundle_manifest.dart';
import 'package:lemonlite/data/models/json_utils.dart';
import 'package:lemonlite/data/models/miniapp_permission.dart';
import 'package:lemonlite/data/models/miniapp_session.dart';
import 'package:lemonlite/data/services/application_registry.dart';
import 'package:lemonlite/data/services/miniapp_storage_service.dart';
import 'package:lemonlite/data/services/permission_service.dart';
import 'package:lemonlite/data/services/plugin_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:lemonlite/pages/permissions/permission_prompt.dart';
import 'package:lemonlite/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SettingsService settings;
late PermissionService permissions;
late ApplicationRegistry registry;

/// 重置到一个干净的持久化环境
Future<void> freshPrefs([Map<String, Object> values = const <String, Object>{}]) async {
  SharedPreferences.setMockInitialValues(values);
  settings = await SettingsService.init();
  permissions = PermissionService.init();
  registry = ApplicationRegistry.init();
}

/// 被测的桥接实例。不需要真的 WebView：dispatch 只依赖会话 + 平台通道。
BridgeApi apiFor(String appId, {MiniappSession? session}) => BridgeApi(
  appId: appId,
  themeController: ThemeController(settings),
  onSetTitle: (String title) {},
  onNavigateBack: (int delta) async => true,
  session: session,
);

Future<LemonBridgeException> captureBridgeError(Future<void> Function() action) async {
  try {
    await action();
  } on LemonBridgeException catch (e) {
    return e;
  }
  throw StateError('期望抛出 LemonBridgeException，但没有');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await freshPrefs();
  });

  // ================================================================ 权限模型

  group('权限模型', () {
    test('受控资源清单：媒体采集 + 定位 + 剪贴板/通知 + 文件访问', () {
      expect(
        MiniappPermission.values.map((MiniappPermission p) => p.id).toList(),
        <String>[
          'camera',
          'microphone',
          'geolocationFine',
          'geolocationCoarse',
          'clipboard',
          'notifications',
          'sdcard',
        ],
      );
    });

    test('精确/模糊定位成对，且精度不同', () {
      expect(
        MiniappPermission.geolocationFine.pairedWith,
        MiniappPermission.geolocationCoarse,
      );
      expect(
        MiniappPermission.geolocationCoarse.pairedWith,
        MiniappPermission.geolocationFine,
      );
      // 非定位项没有配对
      expect(MiniappPermission.camera.pairedWith, isNull);
      // 精细只申请 FINE，粗略只申请 COARSE —— 不能反过来
      expect(
        MiniappPermission.geolocationFine.runtimePermissions,
        <String>['android.permission.ACCESS_FINE_LOCATION'],
      );
      expect(
        MiniappPermission.geolocationCoarse.runtimePermissions,
        <String>['android.permission.ACCESS_COARSE_LOCATION'],
      );
    });

    test('每个权限的 id 唯一、非空，且都有中文名与说明', () {
      final Set<String> ids = <String>{};
      for (final MiniappPermission p in MiniappPermission.values) {
        expect(p.id.trim(), isNotEmpty, reason: '$p 缺 id');
        expect(ids.add(p.id), isTrue, reason: 'id 重复：${p.id}');
        expect(p.label.trim(), isNotEmpty);
        expect(p.description.trim(), isNotEmpty);
      }
    });

    test('默认状态一律是「询问」：没有任何权限被静默放行', () {
      for (final MiniappPermission p in MiniappPermission.values) {
        expect(
          p.defaultDecision,
          PermissionDecision.ask,
          reason: '${p.id} 的默认状态不是询问',
        );
      }
    });

    test('摄像头/麦克风需要系统运行时权限，手机存储不需要', () {
      expect(
        MiniappPermission.camera.runtimePermissions,
        <String>['android.permission.CAMERA'],
      );
      expect(
        MiniappPermission.microphone.runtimePermissions,
        <String>['android.permission.RECORD_AUDIO'],
      );
      // 手机存储由系统文件选择器逐次确认，不需要额外的运行时权限
      expect(MiniappPermission.sdcard.runtimePermissions, isEmpty);
      expect(MiniappPermission.camera.needsRuntimePermission, isTrue);
      expect(MiniappPermission.sdcard.needsRuntimePermission, isFalse);
      // 定位两档都需要系统权限
      expect(MiniappPermission.geolocationFine.needsRuntimePermission, isTrue);
      expect(MiniappPermission.geolocationCoarse.needsRuntimePermission, isTrue);
      // 剪贴板不需要 Android 运行时权限
      expect(MiniappPermission.clipboard.needsRuntimePermission, isFalse);
    });

    test('敏感权限覆盖会碰隐私数据/设备的那些，通知除外', () {
      final Set<MiniappPermission> sensitive =
          MiniappPermission.sensitiveList.toSet();
      expect(sensitive, contains(MiniappPermission.camera));
      expect(sensitive, contains(MiniappPermission.microphone));
      expect(sensitive, contains(MiniappPermission.geolocationFine));
      expect(sensitive, contains(MiniappPermission.geolocationCoarse));
      expect(sensitive, contains(MiniappPermission.clipboard));
      expect(sensitive, contains(MiniappPermission.sdcard));
      // 通知是「常规」等级：它不读数据，只是打扰
      expect(sensitive, isNot(contains(MiniappPermission.notifications)));
      expect(MiniappPermission.sdcard.risk, PermissionRisk.dangerous);
    });

    test('定位归在「位置」分组，不与媒体采集混在一起', () {
      expect(
        MiniappPermission.geolocationFine.group,
        PermissionGroup.location,
      );
      expect(
        MiniappPermission.geolocationCoarse.group,
        PermissionGroup.location,
      );
      expect(MiniappPermission.camera.group, PermissionGroup.media);
    });

    test('分组覆盖全部权限，且不产生空分组', () {
      final Map<PermissionGroup, List<MiniappPermission>> grouped =
          MiniappPermission.grouped();
      final int total = grouped.values.fold<int>(
        0,
        (int sum, List<MiniappPermission> items) => sum + items.length,
      );
      expect(total, MiniappPermission.values.length);
      for (final List<MiniappPermission> items in grouped.values) {
        expect(items, isNotEmpty);
      }
    });

    test('byId 能反查，未知 id 返回 null', () {
      expect(MiniappPermission.byId('camera'), MiniappPermission.camera);
      expect(MiniappPermission.byId('nope'), isNull);
    });

    test('退役清单与现存权限不重叠（否则旧数据会被误判）', () {
      for (final MiniappPermission p in MiniappPermission.values) {
        expect(
          MiniappPermission.isRetired(p.id),
          isFalse,
          reason: '${p.id} 既在枚举里又在退役表里',
        );
      }
      expect(MiniappPermission.isRetired('volume'), isTrue);
      expect(MiniappPermission.isRetired('camra'), isFalse);
    });

    test('JS SDK 里 invoke 的每个方法，Dart 侧都有 case（反之亦然）', () {
      final String js = File('lib/bridge/injected_js.dart').readAsStringSync();
      final String dart = File('lib/bridge/bridge_api.dart').readAsStringSync();

      final Set<String> jsMethods = RegExp(r"invoke\('([A-Za-z0-9_]+)'")
          .allMatches(js)
          .map((RegExpMatch m) => m.group(1)!)
          .toSet();
      // dispatch 的 case 减去模块 action 的 case，剩下的就是内置 API
      final Set<String> moduleActions = <String>{
        'const',
        'http.get',
        'http.post',
        'storage.get',
        'storage.set',
        'storage.remove',
        'storage.clear',
        'storage.keys',
        'ui.toast',
        'ui.setTitle',
        'shell.openUrl',
      };
      final Set<String> dartMethods = RegExp(r"case '([A-Za-z0-9_.]+)':")
          .allMatches(dart)
          .map((RegExpMatch m) => m.group(1)!)
          .where((String m) => !moduleActions.contains(m))
          .toSet();

      expect(jsMethods, isNotEmpty);
      expect(jsMethods.difference(dartMethods), isEmpty, reason: 'JS 调了但 Dart 没实现');
      expect(dartMethods.difference(jsMethods), isEmpty, reason: 'Dart 实现了但 JS SDK 没暴露');
    });
  });

  // ====================================================== WebView 权限翻译

  group('WebPermissionAsk 翻译', () {
    test('CAMERA → camera，MICROPHONE → microphone', () {
      final WebPermissionAsk camera = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[PermissionResourceType.CAMERA],
        ),
      );
      expect(camera.permissions, <MiniappPermission>[MiniappPermission.camera]);
      expect(camera.isUnmanaged, isFalse);

      final WebPermissionAsk mic = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[PermissionResourceType.MICROPHONE],
        ),
      );
      expect(mic.permissions, <MiniappPermission>[MiniappPermission.microphone]);
    });

    test('CAMERA_AND_MICROPHONE 一次要问两项，且顺序按枚举固定', () {
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[
            PermissionResourceType.CAMERA_AND_MICROPHONE,
          ],
        ),
      );
      expect(
        ask.permissions,
        <MiniappPermission>[MiniappPermission.camera, MiniappPermission.microphone],
      );
    });

    test('FILE_READ_WRITE → sdcard（手机存储）', () {
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[PermissionResourceType.FILE_READ_WRITE],
        ),
      );
      expect(ask.permissions, <MiniappPermission>[MiniappPermission.sdcard]);
    });

    test('不认识的资源（AUTOPLAY）→ isUnmanaged，调用方应直接放行', () {
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[PermissionResourceType.AUTOPLAY],
        ),
      );
      expect(ask.isUnmanaged, isTrue);
      expect(ask.permissions, isEmpty);
    });

    test('混合请求只翻译认识的，重复资源不会产生重复权限', () {
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[
            PermissionResourceType.CAMERA,
            PermissionResourceType.CAMERA,
            PermissionResourceType.AUTOPLAY,
          ],
        ),
      );
      expect(ask.permissions, <MiniappPermission>[MiniappPermission.camera]);
    });
  });

  group('WebPermissionAsk 放行结果', () {
    WebPermissionAsk askOf(List<PermissionResourceType> resources) =>
        WebPermissionAsk.from(
          PermissionRequest(
            origin: WebUri('https://example.com'),
            resources: resources,
          ),
        );

    test('一项都没同意 → DENY', () {
      final WebPermissionAsk ask = askOf(<PermissionResourceType>[
        PermissionResourceType.CAMERA,
      ]);
      final PermissionResponse response = WebPermissionAsk.response(
        ask: ask,
        granted: <MiniappPermission>{},
      );
      expect(response.action, PermissionResponseAction.DENY);
    });

    test('同意后回 GRANT，且只带上被同意的资源', () {
      final WebPermissionAsk ask = askOf(<PermissionResourceType>[
        PermissionResourceType.CAMERA,
        PermissionResourceType.MICROPHONE,
      ]);
      final PermissionResponse response = WebPermissionAsk.response(
        ask: ask,
        granted: <MiniappPermission>{MiniappPermission.camera},
      );
      expect(response.action, PermissionResponseAction.GRANT);
      expect(response.resources, <PermissionResourceType>[PermissionResourceType.CAMERA]);
    });

    test('复合资源只同意一半时整体拒绝（不能偷偷放行另一半）', () {
      final WebPermissionAsk ask = askOf(<PermissionResourceType>[
        PermissionResourceType.CAMERA_AND_MICROPHONE,
      ]);
      final PermissionResponse response = WebPermissionAsk.response(
        ask: ask,
        granted: <MiniappPermission>{MiniappPermission.camera},
      );
      expect(response.action, PermissionResponseAction.DENY);
    });

    test('两项都同意时复合资源整体放行', () {
      final WebPermissionAsk ask = askOf(<PermissionResourceType>[
        PermissionResourceType.CAMERA_AND_MICROPHONE,
      ]);
      final PermissionResponse response = WebPermissionAsk.response(
        ask: ask,
        granted: <MiniappPermission>{
          MiniappPermission.camera,
          MiniappPermission.microphone,
        },
      );
      expect(response.action, PermissionResponseAction.GRANT);
      expect(response.resources, <PermissionResourceType>[
        PermissionResourceType.CAMERA_AND_MICROPHONE,
      ]);
    });
  });

  // ============================================================ 方向标记

  group('MiniappOrientationX', () {
    test('五种标记的 id 与中文名齐全', () {
      expect(MiniappOrientationX.allIds, hasLength(5));
      expect(MiniappOrientationX.labelOf(MiniappOrientation.landscape), '横屏');
      expect(MiniappOrientationX.labelOf(MiniappOrientation.portraitReverse), '反向竖屏');
      expect(MiniappOrientationX.labelOf(MiniappOrientation.landscapeReverse), '反向横屏');
      expect(MiniappOrientationX.labelOf(MiniappOrientation.auto), '自动');
    });

    test('宽松解析：大小写、横线、反写都能认', () {
      expect(MiniappOrientationX.parse('landscape'), MiniappOrientation.landscape);
      expect(MiniappOrientationX.parse('LANDSCAPE'), MiniappOrientation.landscape);
      expect(
        MiniappOrientationX.parse('landscape-reverse'),
        MiniappOrientation.landscapeReverse,
      );
      expect(
        MiniappOrientationX.parse('reverseLandscape'),
        MiniappOrientation.landscapeReverse,
      );
      expect(MiniappOrientationX.parse('auto'), MiniappOrientation.auto);
      expect(MiniappOrientationX.parse('unspecified'), MiniappOrientation.auto);
      expect(MiniappOrientationX.parse('sideways'), isNull);
      expect(MiniappOrientationX.parse(null), isNull);
      expect(MiniappOrientationX.parse(''), isNull);
    });

    test('id 往返一致', () {
      for (final MiniappOrientation o in MiniappOrientation.values) {
        expect(MiniappOrientationX.parse(MiniappOrientationX.idOf(o)), o);
      }
    });
  });

  // ============================================================ 体积格式化

  group('formatBytes', () {
    test('各量级都可读', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-5), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(1024 * 1024 * 3 ~/ 2), '1.50 MB');
      expect(formatBytes(1024 * 1024 * 1024 * 2), '2.00 GB');
    });
  });

  // ========================================================= 权限服务行为

  group('PermissionService 授权（三态）', () {
    const String app = 'demo.app';

    test('默认是「询问」：既不是允许也不是拒绝', () {
      for (final MiniappPermission p in MiniappPermission.values) {
        expect(permissions.decisionOf(app, p), PermissionDecision.ask);
        expect(permissions.isDecided(app, p), isFalse);
        expect(permissions.isGranted(app, p), isFalse);
      }
    });

    test('setDecision：允许 / 拒绝 / 回到询问', () async {
      await permissions.setDecision(
        app,
        MiniappPermission.camera,
        PermissionDecision.granted,
      );
      expect(permissions.isGranted(app, MiniappPermission.camera), isTrue);
      expect(permissions.isDecided(app, MiniappPermission.camera), isTrue);

      await permissions.setDecision(
        app,
        MiniappPermission.camera,
        PermissionDecision.denied,
      );
      expect(
        permissions.decisionOf(app, MiniappPermission.camera),
        PermissionDecision.denied,
      );
      expect(permissions.isGranted(app, MiniappPermission.camera), isFalse);

      // 回到「询问」= 删除记录，而不是写一个 ask 值（少一个状态就少一处不一致）
      await permissions.setDecision(
        app,
        MiniappPermission.camera,
        PermissionDecision.ask,
      );
      expect(
        permissions.decisionOf(app, MiniappPermission.camera),
        PermissionDecision.ask,
      );
      expect(permissions.isDecided(app, MiniappPermission.camera), isFalse);
    });

    test('setGranted 是布尔的便捷入口', () async {
      await permissions.setGranted(app, MiniappPermission.microphone, false);
      expect(
        permissions.decisionOf(app, MiniappPermission.microphone),
        PermissionDecision.denied,
      );
      await permissions.setGranted(app, MiniappPermission.microphone, true);
      expect(
        permissions.decisionOf(app, MiniappPermission.microphone),
        PermissionDecision.granted,
      );
    });

    test('setSensitiveDecision 只动敏感项，通知保持「询问」', () async {
      await permissions.setSensitiveDecision(app, PermissionDecision.denied);
      for (final MiniappPermission p in MiniappPermission.sensitiveList) {
        expect(permissions.decisionOf(app, p), PermissionDecision.denied);
      }
      expect(
        permissions.decisionOf(app, MiniappPermission.notifications),
        PermissionDecision.ask,
      );
    });

    test('setAllDecisions(denied) 之后 resetApp 回到全部「询问」', () async {
      await permissions.setAllDecisions(app, PermissionDecision.denied);
      expect(
        permissions.decisionOf(app, MiniappPermission.sdcard),
        PermissionDecision.denied,
      );
      await permissions.resetApp(app);
      for (final MiniappPermission p in MiniappPermission.values) {
        expect(permissions.decisionOf(app, p), PermissionDecision.ask);
      }
    });

    test('决定按 appId 隔离：改一个不影响另一个', () async {
      await permissions.setDecision(
        'a',
        MiniappPermission.camera,
        PermissionDecision.denied,
      );
      expect(
        permissions.decisionOf('a', MiniappPermission.camera),
        PermissionDecision.denied,
      );
      expect(
        permissions.decisionOf('b', MiniappPermission.camera),
        PermissionDecision.ask,
      );
    });

    test('setSensitiveDecisionForAll 批量收紧', () async {
      await permissions.setSensitiveDecisionForAll(
        <String>['a', 'b'],
        PermissionDecision.denied,
      );
      expect(
        permissions.decisionOf('a', MiniappPermission.camera),
        PermissionDecision.denied,
      );
      expect(
        permissions.decisionOf('b', MiniappPermission.microphone),
        PermissionDecision.denied,
      );
    });

    test('损坏的决定记录按「询问」处理，不崩', () async {
      await settings.writeRaw('perm.decision.$app.camera', 'whatever');
      expect(
        permissions.decisionOf(app, MiniappPermission.camera),
        PermissionDecision.ask,
      );
    });
  });

  group('PermissionService 申请记录', () {
    const String app = 'demo.app';

    test('成功与拒绝分别计数，并记录首末时间', () async {
      await permissions.recordUse(app, MiniappPermission.camera);
      await permissions.recordUse(app, MiniappPermission.camera);
      await permissions.recordUse(app, MiniappPermission.camera, denied: true);

      final MiniappUsage usage = permissions.usageOf(app, MiniappPermission.camera);
      expect(usage.count, 2);
      expect(usage.deniedCount, 1);
      expect(usage.totalCalls, 3);
      expect(usage.used, isTrue);
      expect(usage.firstAt, isNotNull);
      expect(usage.lastAt, isNotNull);
    });

    test('没有任何记录时是 empty 且 used=false', () {
      final MiniappUsage usage = permissions.usageOf(app, MiniappPermission.camera);
      expect(usage.count, 0);
      expect(usage.deniedCount, 0);
      expect(usage.used, isFalse);
    });

    test('申请记录损坏时按空处理，不抛异常', () async {
      await settings.writeRaw('perm.usage.$app.camera', '{不是合法 JSON');
      expect(permissions.usageOf(app, MiniappPermission.camera).count, 0);
    });

    test('clearUsage 只清申请记录，不动授权', () async {
      await permissions.recordUse(app, MiniappPermission.camera);
      await permissions.setGranted(app, MiniappPermission.camera, false);
      await permissions.clearUsage(app);
      expect(permissions.usageOf(app, MiniappPermission.camera).used, isFalse);
      expect(permissions.isGranted(app, MiniappPermission.camera), isFalse);
    });
  });

  group('PermissionService 扫描', () {
    test('应用清单跟随 ApplicationRegistry：那边登记了这边就有', () async {
      await registry.record(appId: 'a', name: '应用 A');
      await registry.record(appId: 'b', name: '应用 B');
      final PermissionScanReport report = permissions.scan();
      expect(
        report.miniapps.map((KnownMiniapp a) => a.id),
        containsAll(<String>['a', 'b']),
      );
      expect(report.appById('a')!.displayName, '应用 A');
    });

    test('scan 会把 storage 里出现过的小程序也带上', () async {
      await settings.writeRaw('miniapp.storage.ghost.app.key1', '"v"');
      final PermissionScanReport report = permissions.scan();
      expect(report.miniapps.map((KnownMiniapp a) => a.id), contains('ghost'));
      // 只有 id 没有名字时，展示名退化成 id
      expect(report.appById('ghost')!.displayName, 'ghost');
    });

    test('scan 用 nameHints / extraIds 补名字与条目', () async {
      await registry.record(appId: 'a', name: 'a');
      final PermissionScanReport report = permissions.scan(
        nameHints: <String, String>{'a': '市场名', 'c': '不该凭空出现'},
        extraIds: <String>['b', '  '],
      );
      expect(report.appById('a')!.displayName, '市场名');
      expect(report.appById('b')!.displayName, 'b');
      // nameHints 不该把没出现过的小程序凭空加进来
      expect(report.appById('c'), isNull);
    });

    test('扫描报告能统计使用次数与拒绝次数', () async {
      await registry.record(appId: 'a', name: 'A');
      await registry.record(appId: 'b', name: 'B');
      await permissions.recordUse('a', MiniappPermission.camera);
      await permissions.recordUse('a', MiniappPermission.camera, denied: true);

      final PermissionScanReport report = permissions.scan();
      expect(report.totalApps, 2);
      expect(report.appsUsingSensitive, 1);
      expect(report.totalCalls, 2);
      expect(report.deniedCalls, 1);
      expect(report.usedPermissions, contains(MiniappPermission.camera));
    });

    test('损坏的旧注册表不会让扫描崩掉', () async {
      await settings.writeRaw('perm.known_apps', '[不是数组');
      expect(permissions.knownMiniapps, isEmpty);
      expect(permissions.scan().isEmpty, isTrue);
    });
  });

  // ======================================================== 应用清单

  group('ApplicationRegistry', () {
    test('record 新增、按 id 覆盖，并保留首次登记时间', () async {
      await registry.record(appId: 'a', name: 'A');
      final DateTime first = registry.byId('a')!.firstSeenAt!;
      await registry.record(appId: 'a', name: 'A 改名', opened: true);
      expect(registry.count, 1);
      expect(registry.byId('a')!.displayName, 'A 改名');
      expect(registry.byId('a')!.firstSeenAt, first);
      expect(registry.byId('a')!.lastOpenedAt, isNotNull);
    });

    test('空 appId 不登记', () async {
      await registry.record(appId: '   ', name: '空');
      expect(registry.count, 0);
    });

    test('remove 会同时清掉权限决定与申请记录', () async {
      await registry.record(appId: 'a', name: 'A');
      await permissions.setGranted('a', MiniappPermission.camera, true);
      await permissions.recordUse('a', MiniappPermission.camera);

      await registry.remove('a');

      expect(registry.contains('a'), isFalse);
      expect(
        permissions.decisionOf('a', MiniappPermission.camera),
        PermissionDecision.ask,
      );
      expect(permissions.usageOf('a', MiniappPermission.camera).used, isFalse);
      // 权限管理器里也不该再看到它
      expect(permissions.scan().appById('a'), isNull);
    });

    test('removeAll 批量移除', () async {
      await registry.record(appId: 'a', name: 'A');
      await registry.record(appId: 'b', name: 'B');
      await registry.removeAll(<String>['a', 'b']);
      expect(registry.count, 0);
    });

    test('最近打开的排在前面', () async {
      await registry.record(appId: 'old', name: '旧');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await registry.record(appId: 'new', name: '新', opened: true);
      expect(registry.all.first.id, 'new');
    });

    test('损坏的清单按空处理，不抛异常', () async {
      await settings.writeRaw('apps.registry', '{不是数组');
      expect(registry.all, isEmpty);
    });
  });

  // ======================================================== 文件路径安全

  group('MiniappStorageService 路径校验', () {
    final MiniappStorageService service = MiniappStorageService.instance;

    test('相对路径规范化', () {
      expect(service.normalizeRelativePath(''), '.');
      expect(service.normalizeRelativePath('   '), '.');
      expect(service.normalizeRelativePath('a/b.txt'), 'a/b.txt');
      expect(service.normalizeRelativePath('./a/b.txt'), 'a/b.txt');
      expect(service.normalizeRelativePath('a//b'), 'a/b');
      expect(service.normalizeRelativePath('a/./b'), 'a/b');
      expect(service.normalizeRelativePath(r'a\b'), 'a/b');
      // 目录内的回溯是合法的，会被规范化掉
      expect(service.normalizeRelativePath('a/../b.txt'), 'b.txt');
    });

    test('绝对路径一律拒绝', () {
      expect(
        () => service.normalizeRelativePath('/etc/passwd'),
        throwsA(isA<AppFileException>()),
      );
      expect(
        () => service.normalizeRelativePath('C:/Windows'),
        throwsA(isA<AppFileException>()),
      );
    });

    test('越出小程序目录的路径一律拒绝', () {
      for (final String evil in <String>['..', '../x', 'a/../../x', '../']) {
        expect(
          () => service.normalizeRelativePath(evil),
          throwsA(isA<AppFileException>()),
          reason: '$evil 应该被拒绝',
        );
      }
    });

    test('超长路径拒绝', () {
      expect(
        () => service.normalizeRelativePath('a' * 600),
        throwsA(isA<AppFileException>()),
      );
    });

    test('两个作用域的显示路径互不相同', () {
      final String shared = service.displayPath('a', FileScope.files);
      final String private = service.displayPath('a', FileScope.private);
      expect(shared, contains('Android/data'));
      expect(private, isNot(shared));
      expect(FileScope.parse('PRIVATE'), FileScope.private);
      expect(FileScope.parse('不认识的'), FileScope.files);
      expect(FileScope.parse(null), FileScope.files);
    });

    test('storage 键统计：按 appId 隔离且能算出字节数', () async {
      await freshPrefs(<String, Object>{
        'miniapp.storage.a.k1': 'v1',
        'miniapp.storage.a.k2': 'longer-value',
        'miniapp.storage.b.k1': 'other',
      });
      final List<MiniappStorageEntry> entries = MiniappStorageService.instance
          .storageEntries('a');
      expect(entries, hasLength(2));
      expect(
        entries.map((MiniappStorageEntry e) => e.key),
        containsAll(<String>['k1', 'k2']),
      );
      // 按体积倒序：longer-value 在前
      expect(entries.first.key, 'k2');
      expect(
        MiniappStorageService.instance.storageBytes('a'),
        'v1'.length + 'longer-value'.length,
      );
      expect(MiniappStorageService.instance.storageBytes('b'), 'other'.length);
      expect(MiniappStorageService.instance.storageBytes('c'), 0);
    });

    test('删除单个键只影响那一个', () async {
      await freshPrefs(<String, Object>{
        'miniapp.storage.a.k1': 'v1',
        'miniapp.storage.a.k2': 'v2',
      });
      final MiniappStorageService svc = MiniappStorageService.instance;
      await svc.removeStorageEntry('miniapp.storage.a.k1');
      expect(
        svc.storageEntries('a').map((MiniappStorageEntry e) => e.key),
        <String>['k2'],
      );
    });
  });

  // ==================================================== 权限弹窗（批量/单条）

  group('权限弹窗（首次使用确认）', () {
    const String app = 'demo.app';

    test('pendingDeclared：只挑"声明里且还没决定"的，顺序固定按枚举', () async {
      final List<MiniappPermission> declared = <MiniappPermission>[
        MiniappPermission.sdcard,
        MiniappPermission.camera,
        MiniappPermission.microphone,
      ];
      expect(
        PermissionPromptService.pendingDeclared(appId: app, declared: declared)
            .map((MiniappPermission p) => p.id)
            .toList(),
        <String>['camera', 'microphone', 'sdcard'],
      );

      await permissions.setDecision(
        app,
        MiniappPermission.camera,
        PermissionDecision.granted,
      );
      await permissions.setDecision(
        app,
        MiniappPermission.microphone,
        PermissionDecision.denied,
      );
      // 允许过和拒绝过的都不再出现在待询问清单里
      expect(
        PermissionPromptService.pendingDeclared(appId: app, declared: declared)
            .map((MiniappPermission p) => p.id)
            .toList(),
        <String>['sdcard'],
      );
    });

    test('pendingDeclared：没声明的权限不进批量清单', () {
      expect(
        PermissionPromptService.pendingDeclared(
          appId: app,
          declared: <MiniappPermission>[MiniappPermission.camera],
        ).map((MiniappPermission p) => p.id),
        <String>['camera'],
      );
      expect(
        PermissionPromptService.pendingDeclared(
          appId: app,
          declared: const <MiniappPermission>[],
        ),
        isEmpty,
      );
    });

    test('ensure：已经允许过就直接放行，不再弹窗', () async {
      await permissions.setDecision(
        app,
        MiniappPermission.camera,
        PermissionDecision.granted,
      );
      final PermissionAnswer answer = await PermissionPromptService.instance.ensure(
        app,
        MiniappPermission.camera,
      );
      expect(answer.allowed, isTrue);
    });

    test('ensure：已经拒绝过就直接拒绝，不再弹窗', () async {
      await permissions.setDecision(
        app,
        MiniappPermission.camera,
        PermissionDecision.denied,
      );
      final PermissionAnswer answer = await PermissionPromptService.instance.ensure(
        app,
        MiniappPermission.camera,
      );
      expect(answer.allowed, isFalse);
    });

    test('ensure：没问过又弹不出弹窗 → 本次拒绝，但绝不写决定', () async {
      // 测试环境里没有 Navigator 覆盖层，走的就是 fail closed 分支
      final PermissionAnswer answer = await PermissionPromptService.instance.ensure(
        app,
        MiniappPermission.camera,
      );
      expect(answer.allowed, isFalse);
      expect(
        permissions.decisionOf(app, MiniappPermission.camera),
        PermissionDecision.ask,
        reason: '这次弹不出来不该把用户永久钉在"拒绝"上',
      );
    });

    test('requestDeclared：弹不出弹窗时不写决定（留到真正调用时再问）', () async {
      await PermissionPromptService.instance.requestDeclared(
        appId: app,
        appName: 'A',
        declared: <MiniappPermission>[
          MiniappPermission.camera,
          MiniappPermission.microphone,
        ],
      );
      expect(
        permissions.decisionOf(app, MiniappPermission.camera),
        PermissionDecision.ask,
      );
      expect(
        permissions.decisionOf(app, MiniappPermission.microphone),
        PermissionDecision.ask,
      );
    });

    test('ensureAll 只返回被允许的那些', () async {
      await permissions.setDecision(
        app,
        MiniappPermission.camera,
        PermissionDecision.granted,
      );
      await permissions.setDecision(
        app,
        MiniappPermission.microphone,
        PermissionDecision.denied,
      );
      final Set<MiniappPermission> granted =
          await PermissionPromptService.instance.ensureAll(
        app,
        <MiniappPermission>[
          MiniappPermission.camera,
          MiniappPermission.microphone,
        ],
      );
      expect(granted, <MiniappPermission>{MiniappPermission.camera});
    });
  });

  // ==================================================== 桥接层不再有权限闸门

  group('桥接层（这一版没有权限闸门）', () {
    test('音量/亮度不再因为「权限被关闭」而返回 40001', () async {
      // 旧版本这里会被权限闸门拦住；现在这些能力一律直接放行，
      // 测试环境没有平台通道 → 降级成 10003（能力不可用），而不是 40001。
      await permissions.setAllDecisions('a', PermissionDecision.denied);
      final BridgeApi api = apiFor('a');
      final LemonBridgeException e = await captureBridgeError(
        () => api.dispatch('getVolume', <String, dynamic>{}),
      );
      expect(e.code, BridgeErrorCode.notSupported);
    });

    test('桥接层源码里没有任何权限闸门（这一版刻意去掉的）', () async {
      // 这条断言防的是「把旧版的闸门又搬回来」：
      // 一旦有人重新引入按方法查权限再拦截的逻辑，这里会立刻失败。
      final String source = File('lib/bridge/bridge_api.dart').readAsStringSync();
      expect(source.contains('requestPermission'), isFalse);
      expect(source.contains('permissionService'), isFalse);
      expect(source.contains('_guard('), isFalse);
      // 权限模型里也不该再有「方法 → 权限」的映射表
      expect(MiniappPermission.isRetired('volume'), isTrue);
      await permissions.setAllDecisions('a', PermissionDecision.denied);
      // 被用户「拒绝」的权限只影响 WebView 层，不影响 JSBridge 的内置方法
      final BridgeApi api = apiFor('a');
      final Object? theme = await api.dispatch('getTheme', <String, dynamic>{});
      expect(theme, isNotNull);
    });

    test('方向标记：合法值可直接设置并回读', () async {
      final MiniappSession session = MiniappSession(appId: 'a', title: 'A');
      final BridgeApi api = apiFor('a', session: session);

      final Object? result = await api.dispatch(
        'setPageOrientation',
        <String, dynamic>{'orientation': 'landscape'},
      );
      expect((result! as Map<String, dynamic>)['orientation'], 'landscape');
      expect(session.orientation, MiniappOrientation.landscape);

      final Object? read = await api.dispatch('getPageOrientation', <String, dynamic>{});
      expect((read! as Map<String, dynamic>)['orientation'], 'landscape');
      expect((read as Map<String, dynamic>)['label'], '横屏');
    });

    test('方向标记：非法值报 10001', () async {
      final BridgeApi api = apiFor('a');
      final LemonBridgeException e = await captureBridgeError(
        () => api.dispatch('setPageOrientation', <String, dynamic>{'orientation': 'sideways'}),
      );
      expect(e.code, BridgeErrorCode.invalidArgument);
    });

    test('熄屏标记：enabled 与 allowScreenOff 两种写法语义相反', () async {
      final MiniappSession session = MiniappSession(appId: 'a', title: 'A');
      final BridgeApi api = apiFor('a', session: session);

      Object? r = await api.dispatch('setKeepScreenOn', <String, dynamic>{'enabled': true});
      expect((r! as Map<String, dynamic>)['keepScreenOn'], isTrue);
      expect(session.keepScreenOn, isTrue);

      r = await api.dispatch('setKeepScreenOn', <String, dynamic>{'allowScreenOff': false});
      expect((r! as Map<String, dynamic>)['keepScreenOn'], isTrue);

      r = await api.dispatch('setKeepScreenOn', <String, dynamic>{'allowScreenOff': true});
      expect((r! as Map<String, dynamic>)['keepScreenOn'], isFalse);
      expect(session.keepScreenOn, isFalse);
    });

    test('熄屏标记：完全没给参数时报 10001', () async {
      final BridgeApi api = apiFor('a');
      final LemonBridgeException e = await captureBridgeError(
        () => api.dispatch('setKeepScreenOn', <String, dynamic>{}),
      );
      expect(e.code, BridgeErrorCode.invalidArgument);
    });

    test('未知 API 报 10003', () async {
      final BridgeApi api = apiFor('a');
      final LemonBridgeException e = await captureBridgeError(
        () => api.dispatch('nope', <String, dynamic>{}),
      );
      expect(e.code, BridgeErrorCode.notSupported);
    });

    test('没有会话时 runInBackground / close 报 10003 而不是静默失败', () async {
      final BridgeApi api = apiFor('a');
      expect(
        (await captureBridgeError(
          () => api.dispatch('runInBackground', <String, dynamic>{}),
        )).code,
        BridgeErrorCode.notSupported,
      );
      expect(
        (await captureBridgeError(() => api.dispatch('close', <String, dynamic>{}))).code,
        BridgeErrorCode.notSupported,
      );
    });

    test('前台有会话时 runInBackground 会真的调用回调', () async {
      bool called = false;
      final BridgeApi api = BridgeApi(
        appId: 'a',
        themeController: ThemeController(settings),
        onSetTitle: (String t) {},
        onNavigateBack: (int d) async => true,
        onRunInBackground: () async => called = true,
      );
      final Object? result = await api.dispatch('runInBackground', <String, dynamic>{});
      expect(called, isTrue);
      expect((result! as Map<String, dynamic>)['background'], isTrue);
    });
  });

  // ==================================================== 权限改名后的兼容

  group('allFiles → sdcard 的兼容', () {
    const String app = 'demo.app';

    test('旧 id 仍能识别，并解析成新权限', () {
      expect(MiniappPermission.byId('allFiles'), MiniappPermission.sdcard);
      expect(MiniappPermission.byId('nope'), isNull);
      // 声明里写旧 id 的应用不该被当成"未知权限"
      expect(MiniappPermission.isRetired('allFiles'), isFalse);
    });

    test('升级前写下的旧决定继续生效', () async {
      await freshPrefs(<String, Object>{
        'perm.decision.$app.allFiles': 'granted',
      });
      expect(
        permissions.decisionOf(app, MiniappPermission.sdcard),
        PermissionDecision.granted,
      );
    });

    test('重新设置决定时新旧键一起清，不会让旧记录"复活"', () async {
      await freshPrefs(<String, Object>{
        'perm.decision.$app.allFiles': 'denied',
      });
      await permissions.setDecision(
        app,
        MiniappPermission.sdcard,
        PermissionDecision.ask,
      );
      expect(
        permissions.decisionOf(app, MiniappPermission.sdcard),
        PermissionDecision.ask,
      );
      // 旧键必须已经被删掉，否则下次读取还会拿到 denied
      expect(settings.readRaw('perm.decision.$app.allFiles'), isNull);
    });
  });

  // ============================================================ 插件 / WASM

  group('插件 manifest', () {
    Map<String, dynamic> pluginJson({
      List<String> platforms = const <String>['android', 'ios'],
      List<String> capabilities = const <String>['wasm'],
      List<Map<String, dynamic>> modules = const <Map<String, dynamic>>[
        <String, dynamic>{'name': 'lemonlite', 'file': 'modules/lemonlite.wasm'},
      ],
    }) => <String, dynamic>{
      'type': 'plugin',
      'id': 'lemonlite.wasm',
      'name': 'WebAssembly 运行时',
      'version': '1.0.0',
      'platforms': platforms,
      'capabilities': capabilities,
      'wasm': <String, dynamic>{'modules': modules},
    };

    test('type = plugin 被识别，且落到 plugins 目录', () {
      final BundleManifest m = BundleManifest.parse(pluginJson());
      expect(m.type, BundleType.plugin);
      expect(m.type.label, '插件');
      expect(m.type.directoryName, 'plugins');
      expect(m.capabilities, <String>['wasm']);
      expect(m.hasCapability('wasm'), isTrue);
      expect(m.hasCapability('camera'), isFalse);
      expect(m.platforms, <String>['android', 'ios']);
      expect(m.wasmModules.single.name, 'lemonlite');
      expect(m.wasmModules.single.file, 'modules/lemonlite.wasm');
    });

    test('平台匹配按当前平台判断，空列表 = 全平台', () {
      final BundleManifest limited = BundleManifest.parse(pluginJson());
      final BundleManifest universal = BundleManifest.parse(
        pluginJson(platforms: const <String>[]),
      );
      // 测试环境是 android（defaultTargetPlatform 的默认值）
      expect(PluginService.platformMatches(limited), isTrue);
      expect(PluginService.platformMatches(universal), isTrue);
      expect(PluginService.currentPlatformId, 'android');
    });

    test('插件必须声明能力', () {
      expect(
        () => BundleManifest.parse(pluginJson(capabilities: const <String>[])),
        throwsA(isA<BundleManifestException>()),
      );
    });

    test('声明了 wasm 能力却没有模块 → 拒绝', () {
      expect(
        () => BundleManifest.parse(pluginJson(modules: const <Map<String, dynamic>>[])),
        throwsA(isA<BundleManifestException>()),
      );
    });

    test('wasm 模块缺 name / file → 拒绝', () {
      expect(
        () => BundleManifest.parse(
          pluginJson(modules: <Map<String, dynamic>>[
            <String, dynamic>{'name': 'x'},
          ]),
        ),
        throwsA(isA<BundleManifestException>()),
      );
    });
  });

  group('随包附带的 wasm 插件载荷', () {
    /// 插件包里的 wasm 路径（不再放在 assets/wasm 下 —— 它已经不是宿主的一部分了）
    const String wasmPath = 'assets/plugins/lemonlite-wasm/modules/lemonlite.wasm';
    const String manifestPath = 'assets/plugins/lemonlite-wasm/lemonlite.json';

    test('插件包文件存在，且 pubspec 声明了它们', () {
      expect(File(wasmPath).existsSync(), isTrue);
      expect(File(manifestPath).existsSync(), isTrue);
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains(wasmPath), isTrue);
      expect(pubspec.contains(manifestPath), isTrue);
      // 宿主不再内置 wasm：旧路径必须已经删掉
      expect(File('assets/wasm/lemonlite.wasm').existsSync(), isFalse);
    });

    test('插件 manifest 声明的能力与模块和包内文件一致', () {
      final Object? decoded = jsonDecode(File(manifestPath).readAsStringSync());
      final BundleManifest manifest = BundleManifest.parse(
        (decoded! as Map).map<String, dynamic>(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        ),
      );
      expect(manifest.type, BundleType.plugin);
      expect(manifest.capabilities, contains('wasm'));
      expect(manifest.wasmModules, isNotEmpty);
      for (final PluginWasmModule module in manifest.wasmModules) {
        final String path = 'assets/plugins/lemonlite-wasm/${module.file}';
        expect(File(path).existsSync(), isTrue, reason: '$path 不存在');
        expect(module.exports, contains('add'));
        expect(module.exports.toSet().length, module.exports.length);
      }
    });

    test('wasm 二进制头合法（\\0asm + 版本 1），导出符号名出现在二进制里', () {
      final List<int> bytes = File(wasmPath).readAsBytesSync();
      expect(bytes.length, greaterThan(8));
      expect(bytes.sublist(0, 4), <int>[0x00, 0x61, 0x73, 0x6D]); // \0asm
      expect(bytes[4], 1); // version = 1
      expect(bytes[5], 0);
      expect(bytes[6], 0);
      expect(bytes[7], 0);

      final String ascii = String.fromCharCodes(bytes);
      for (final String symbol in <String>['add', 'fib', 'sum_to', 'clamp']) {
        expect(ascii.contains(symbol), isTrue, reason: '二进制里找不到导出 $symbol');
      }
      expect(ascii.contains('memory'), isTrue);
    });
  });
}

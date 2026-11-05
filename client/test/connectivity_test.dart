// test/connectivity_test.dart
//
// 蓝牙 / NFC 这两条「宿主原生能力」的接线测试。
//
// 重点不是真的连设备（测试环境没有平台通道），而是确认三件事：
//   1. 它们被算进权限模型，且 NFC 不会被误标成需要 Android 运行时权限；
//   2. 小程序调用时**先过应用内授权**，未授权一律 fail closed（40001）；
//   3. 已授权后，在非 Android 环境里会安全降级（返回空设备 / supported=false），
//      而不是抛一个让页面白屏的异常。
//
// 真实蓝牙/NFC 的收发由 Kotlin 侧负责，这里用不到。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/bridge/bridge_api.dart';
import 'dart:async';

import 'package:lemonlite/core/bluetooth_bridge.dart';
import 'package:lemonlite/core/nfc_bridge.dart';
import 'package:lemonlite/data/models/miniapp_permission.dart';
import 'package:lemonlite/data/services/application_registry.dart';
import 'package:lemonlite/data/services/permission_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:lemonlite/theme/md3e_styles.dart';
import 'package:lemonlite/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SettingsService settings;
late PermissionService permissions;

Future<void> freshPrefs() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  settings = await SettingsService.init();
  permissions = PermissionService.init();
  ApplicationRegistry.init();
}

BridgeApi apiFor(String appId) => BridgeApi(
  appId: appId,
  themeController: ThemeController(settings),
  onSetTitle: (String title) {},
  onNavigateBack: (int delta) async => true,
);

Future<LemonBridgeException> captureError(
  Future<Object?> Function() action,
) async {
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
    // Flutter 测试默认把 targetPlatform 当作 Android；这里显式切到 linux，
    // 才能验证「非 Android 时安全降级」的分支（真机上它是 Android）。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await freshPrefs();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('蓝牙 / NFC 权限模型', () {
    test('蓝牙需要 Android 12+ 的扫描与连接运行时权限', () {
      expect(
        MiniappPermission.bluetooth.runtimePermissions,
        containsAll(<String>[
          'android.permission.BLUETOOTH_SCAN',
          'android.permission.BLUETOOTH_CONNECT',
        ]),
      );
      expect(MiniappPermission.bluetooth.needsRuntimePermission, isTrue);
      expect(MiniappPermission.bluetooth.group, PermissionGroup.connectivity);
    });

    test('NFC 是安装期权限：应用内仍然要问，但不申请运行时权限', () {
      expect(MiniappPermission.nfc.runtimePermissions, isEmpty);
      expect(MiniappPermission.nfc.needsRuntimePermission, isFalse);
      expect(MiniappPermission.nfc.group, PermissionGroup.connectivity);
      // 仍然算敏感项，所以默认会进入「一键收紧敏感权限」
      expect(MiniappPermission.nfc.isSensitive, isTrue);
    });

    test('两个新权限都能被市场声明解析出来', () {
      expect(MiniappPermission.byId('bluetooth'), MiniappPermission.bluetooth);
      expect(MiniappPermission.byId('nfc'), MiniappPermission.nfc);
      final Map<PermissionGroup, List<MiniappPermission>> grouped =
          MiniappPermission.grouped();
      expect(grouped[PermissionGroup.connectivity], isNotEmpty);
    });
  });

  group('桥接层的权限闸门', () {
    test('未授权时蓝牙列表调用直接拒绝（不会偷偷去问系统）', () async {
      final LemonBridgeException e = await captureError(
        () => apiFor(
          'app.bt',
        ).dispatch('bluetoothListPaired', <String, dynamic>{}),
      );
      expect(e.code, BridgeErrorCode.permissionDenied);
    });

    test('未授权时 NFC 读卡直接拒绝', () async {
      final LemonBridgeException e = await captureError(
        () => apiFor('app.nfc').dispatch('nfcRead', <String, dynamic>{}),
      );
      expect(e.code, BridgeErrorCode.permissionDenied);
    });

    test('已授权后，非 Android 环境安全降级为空设备列表', () async {
      await permissions.setGranted('app.bt', MiniappPermission.bluetooth, true);
      final Object? data = await apiFor(
        'app.bt',
      ).dispatch('bluetoothListPaired', <String, dynamic>{});
      expect(data, isA<Map<String, dynamic>>());
      expect((data! as Map<String, dynamic>)['devices'], isEmpty);
    });

    test('已授权后，状态查询在非 Android 环境返回 supported=false', () async {
      final Object? bt = await apiFor(
        'app.bt',
      ).dispatch('bluetoothStatus', <String, dynamic>{});
      expect((bt! as Map<String, dynamic>)['supported'], isFalse);

      final Object? nfc = await apiFor(
        'app.nfc',
      ).dispatch('nfcStatus', <String, dynamic>{});
      expect((nfc! as Map<String, dynamic>)['supported'], isFalse);
    });
  });

  group('原生通道在非 Android 上的行为', () {
    test('蓝牙的状态 / 扫描返回空而不是抛错', () async {
      expect(BluetoothBridge.isSupported, isFalse);
      expect(await BluetoothBridge.listPaired(), isEmpty);
      expect(await BluetoothBridge.scan(), isEmpty);
    });

    test('NFC 的读写会明确报「不支持」', () async {
      expect(NfcBridge.isSupported, isFalse);
      await expectLater(NfcBridge.read(), throwsA(isA<NfcException>()));
    });
  });

  group('跨平台后端可替换', () {
    test('蓝牙：注册一个后端后，公共 API 全部走它', () async {
      final BluetoothBackend original = BluetoothBridge.backend;
      final _FakeBluetoothBackend fake = _FakeBluetoothBackend();
      BluetoothBridge.registerBackend(fake);
      addTearDown(() => BluetoothBridge.registerBackend(original));

      expect(BluetoothBridge.isSupported, isTrue);
      final Map<String, dynamic> status = await BluetoothBridge.status();
      expect(status['supported'], isTrue);
      final List<Map<String, dynamic>> devices =
          await BluetoothBridge.listPaired();
      expect(devices, hasLength(1));
      expect(devices.first['address'], 'AA:BB:CC:DD:EE:FF');
      expect(fake.lastMethod, 'listPaired');
    });

    test('蓝牙事件只转发给连接过的地址', () async {
      final BluetoothBackend original = BluetoothBridge.backend;
      final _FakeBluetoothBackend fake = _FakeBluetoothBackend();
      BluetoothBridge.registerBackend(fake);
      addTearDown(() => BluetoothBridge.registerBackend(original));
      await permissions.setGranted(
        'app.events',
        MiniappPermission.bluetooth,
        true,
      );

      final Map<String, Map<String, dynamic>> received =
          <String, Map<String, dynamic>>{};
      final BridgeApi api = BridgeApi(
        appId: 'app.events',
        themeController: ThemeController(settings),
        onSetTitle: (String title) {},
        onNavigateBack: (int delta) async => true,
        onEvent: (String appId, String type, Map<String, dynamic> data) {
          received[type] = data;
        },
      );
      addTearDown(api.dispose);

      await api.dispatch('bluetoothConnect', <String, dynamic>{
        'address': 'AA:BB:CC:DD:EE:FF',
      });
      fake.emit(<String, dynamic>{
        'type': 'notification',
        'address': 'AA:BB:CC:DD:EE:FF',
        'characteristic': '0000FFF1-0000-1000-8000-00805F9B34FB',
        'value': 'AQID',
      });
      await Future<void>.delayed(Duration.zero);
      expect(received, contains('bluetooth:notification'));

      fake.emit(<String, dynamic>{
        'type': 'notification',
        'address': '11:22:33:44:55:66',
        'value': 'AQID',
      });
      await Future<void>.delayed(Duration.zero);
      expect(received.length, 1, reason: '别的地址的事件不能泄漏给这个会话');
    });

    test('NFC：注册一个后端后，公共 API 全部走它', () async {
      final NfcBackend original = NfcBridge.backend;
      final _FakeNfcBackend fake = _FakeNfcBackend();
      NfcBridge.registerBackend(fake);
      addTearDown(() => NfcBridge.registerBackend(original));

      expect(NfcBridge.isSupported, isTrue);
      final Map<String, dynamic> status = await NfcBridge.status();
      expect(status['enabled'], isTrue);
      final Map<String, dynamic> tag = await NfcBridge.read(timeoutMs: 2000);
      expect(tag['id'], '0102');
    });
  });

  group('MD3 Expressive 基础样式', () {
    test('包含代表性的形状 / 字体 / 按钮规则', () {
      expect(Md3eStyles.css, contains('--md3e-radius-full'));
      expect(Md3eStyles.css, contains(':where(button'));
      expect(Md3eStyles.css, contains('var(--md-primary'));
      expect(Md3eStyles.css, contains('prefers-reduced-motion'));
    });

    test('注入脚本是自包含的，并带防止重复注入的标记', () {
      final String script = Md3eStyles.buildInjectScript();
      expect(script, contains('lemonlite-md3e'));
      expect(script, contains('__LEMONLITE_MD3E__'));
      expect(script, contains('DOMContentLoaded'));
    });
  });
}

class _FakeBluetoothBackend implements BluetoothBackend {
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  String? lastMethod;

  @override
  bool get isSupported => true;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  void emit(Map<String, dynamic> event) => _events.add(event);

  @override
  Future<Map<String, dynamic>> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    lastMethod = method;
    switch (method) {
      case 'status':
        return <String, dynamic>{
          'supported': true,
          'enabled': true,
          'bleSupported': true,
          'permissionGranted': true,
        };
      case 'listPaired':
        return <String, dynamic>{
          'devices': <Map<String, dynamic>>[
            <String, dynamic>{
              'address': 'AA:BB:CC:DD:EE:FF',
              'name': 'Fake',
              'type': 'le',
            },
          ],
        };
      case 'connect':
        return <String, dynamic>{
          'address': 'AA:BB:CC:DD:EE:FF',
          'name': 'Fake',
          'mtu': 23,
          'services': <dynamic>[],
        };
      default:
        return <String, dynamic>{};
    }
  }
}

class _FakeNfcBackend implements NfcBackend {
  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    switch (method) {
      case 'status':
        return <String, dynamic>{'supported': true, 'enabled': true};
      case 'read':
        return <String, dynamic>{'id': '0102', 'records': <dynamic>[]};
      default:
        return <String, dynamic>{};
    }
  }
}

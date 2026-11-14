// test/miniapp_metadata_test.dart
//
// metadata.json 的解析与「权限该显示哪些」的判定。
//
// 这两块是同一件事的两面：包自己声明了什么，权限页就显示什么。
// 一旦解析或取并集的逻辑错了，用户会在权限页上看到不该出现的条目，
// 或者看不到自己其实用过的能力 —— 都不是能靠肉眼发现的问题。

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/models/miniapp_metadata.dart';
import 'package:lemonlite/data/models/miniapp_permission.dart';
import 'package:lemonlite/data/services/application_registry.dart';
import 'package:lemonlite/data/services/permission_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MiniappMetadata', () {
    Map<String, dynamic> json({Map<String, dynamic> extra = const <String, dynamic>{}}) =>
        <String, dynamic>{
          'id': 'com.example.notes',
          'name': '记事本',
          'version': '1.2.0',
          'entry': 'app.html',
          'permissions': <String>['camera', 'bluetooth', 'camra'],
          ...extra,
        };

    test('解析必需字段与默认值', () {
      final MiniappMetadata? meta = MiniappMetadata.parse(json());
      expect(meta, isNotNull);
      expect(meta!.id, 'com.example.notes');
      expect(meta.name, '记事本');
      expect(meta.entry, 'app.html');
      // 未知 id 保留在原始清单里，不静默丢弃
      expect(meta.permissionIds, <String>['camera', 'bluetooth', 'camra']);
      expect(
        meta.declaredPermissions,
        <MiniappPermission>[MiniappPermission.camera, MiniappPermission.bluetooth],
      );
      expect(meta.unknownPermissionIds, <String>['camra']);
    });

    test('entry 缺省为 index.html', () {
      final MiniappMetadata? meta = MiniappMetadata.parse(
        json(extra: <String, dynamic>{'entry': ''}),
      );
      expect(meta!.entry, 'index.html');
    });

    test('缺 id / name 直接判为非法', () {
      expect(MiniappMetadata.parse(<String, dynamic>{'name': 'x'}), isNull);
      expect(MiniappMetadata.parse(<String, dynamic>{'id': 'x'}), isNull);
    });

    test('minFrameworkVersion 高于当前框架时要拒绝', () {
      MiniappMetadata.currentFramework = '0.2.0';
      final MiniappMetadata newer = MiniappMetadata.parse(
        json(extra: <String, dynamic>{'minFrameworkVersion': '0.3.0'}),
      )!;
      final MiniappMetadata same = MiniappMetadata.parse(
        json(extra: <String, dynamic>{'minFrameworkVersion': '0.2'}),
      )!;
      expect(newer.needsNewerFramework, isTrue);
      expect(same.needsNewerFramework, isFalse);
    });

    test('版本比较按段对齐，1.10 > 1.9（字符串比较会判反）', () {
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('0.2', '0.2.0'), 0);
      expect(compareVersions('0.1.9', '0.2.0'), lessThan(0));
    });

    test('toJson 能往返', () {
      final MiniappMetadata meta = MiniappMetadata.parse(json())!;
      final MiniappMetadata again = MiniappMetadata.parse(meta.toJson())!;
      expect(again.id, meta.id);
      expect(again.permissionIds, meta.permissionIds);
      expect(again.entry, meta.entry);
    });
  });

  group('权限页该显示哪些', () {
    KnownMiniapp app(List<String> declared) =>
        KnownMiniapp(id: 'com.example.a', name: '甲', permissionIds: declared);

    PermissionScanReport report({
      required List<KnownMiniapp> apps,
      Map<String, Map<MiniappPermission, MiniappUsage>> usage =
          const <String, Map<MiniappPermission, MiniappUsage>>{},
    }) => PermissionScanReport(
      miniapps: apps,
      decisions: <String, Map<MiniappPermission, PermissionDecision>>{},
      usage: usage,
    );

    test('只声明没使用：显示声明项', () {
      final PermissionScanReport r = report(
        apps: <KnownMiniapp>[app(<String>['camera'])],
      );
      expect(r.relevantOf('com.example.a'), <MiniappPermission>[
        MiniappPermission.camera,
      ]);
      expect(r.declaredOnlyOf('com.example.a'), <MiniappPermission>{
        MiniappPermission.camera,
      });
    });

    test('没声明但真用过：也要显示（运行时请求）', () {
      final PermissionScanReport r = report(
        apps: <KnownMiniapp>[app(<String>[])],
        usage: <String, Map<MiniappPermission, MiniappUsage>>{
          'com.example.a': <MiniappPermission, MiniappUsage>{
            MiniappPermission.microphone: const MiniappUsage(count: 3),
          },
        },
      );
      expect(r.relevantOf('com.example.a'), <MiniappPermission>[
        MiniappPermission.microphone,
      ]);
      expect(r.declaredOnlyOf('com.example.a'), isEmpty);
    });

    test('声明 + 使用取并集，顺序按枚举固定', () {
      final PermissionScanReport r = report(
        apps: <KnownMiniapp>[app(<String>['nfc'])],
        usage: <String, Map<MiniappPermission, MiniappUsage>>{
          'com.example.a': <MiniappPermission, MiniappUsage>{
            MiniappPermission.camera: const MiniappUsage(count: 1),
          },
        },
      );
      expect(r.relevantOf('com.example.a'), <MiniappPermission>[
        MiniappPermission.camera,
        MiniappPermission.nfc,
      ]);
    });

    test('完全没有声明与使用：空（权限页给空态，不列九项）', () {
      final PermissionScanReport r = report(
        apps: <KnownMiniapp>[app(<String>[])],
      );
      expect(r.relevantOf('com.example.a'), isEmpty);
    });

    test('未知声明 id 不会变成任何权限，也不会让相关清单报错', () {
      final PermissionScanReport r = report(
        apps: <KnownMiniapp>[app(<String>['camra', 'bluetooth'])],
      );
      expect(r.relevantOf('com.example.a'), <MiniappPermission>[
        MiniappPermission.bluetooth,
      ]);
    });
  });

  group('应用清单保存声明', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService.init();
      ApplicationRegistry.init();
    });

    test('record 写入的 permissions 能读回，且去重去空', () async {
      final ApplicationRegistry registry = ApplicationRegistry.instance;
      await registry.record(
        appId: 'com.example.a',
        name: '甲',
        permissions: <String>['camera', 'camera', ' ', 'bluetooth'],
      );
      final RegisteredApp? saved = registry.byId('com.example.a');
      expect(saved!.permissionIds, <String>['camera', 'bluetooth']);
    });

    test('不传 permissions 时保留原值（安装回调只补名字不会抹掉声明）', () async {
      final ApplicationRegistry registry = ApplicationRegistry.instance;
      await registry.record(
        appId: 'com.example.a',
        name: '甲',
        permissions: <String>['camera'],
      );
      await registry.record(appId: 'com.example.a', name: '甲（新名）');
      final RegisteredApp? saved = registry.byId('com.example.a');
      expect(saved!.displayName, '甲（新名）');
      expect(saved.permissionIds, <String>['camera']);
    });
  });
}

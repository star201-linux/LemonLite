
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/services/application_registry.dart';
import 'package:lemonlite/data/services/installed_app_info.dart';
import 'package:lemonlite/data/services/miniapp_package_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final MiniappPackageService packages = MiniappPackageService.instance;

  /// 铺一个已安装的包（生产布局：app/<appId>/ 平铺）
  void layOut(
    String appId, {
    required String metadata,
    String entry = 'index.html',
    String? iconFile,
  }) {
    final Directory dir = Directory(p.join(root.path, appId))
      ..createSync(recursive: true);
    File(p.join(dir.path, entry)).writeAsStringSync('<h1>x</h1>');
    File(p.join(dir.path, 'metadata.json')).writeAsStringSync(metadata);
    File(p.join(dir.path, '.install.json')).writeAsStringSync(
      '{"version":"9.9.9","entry":"$entry","installedAt":"2026-11-19T00:00:00.000Z"}',
    );
    if (iconFile != null) {
      final File f = File(p.join(dir.path, iconFile));
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(<int>[137, 80, 78, 71]);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init();
    ApplicationRegistry.init();
    root = Directory.systemTemp.createTempSync('ll-app-info-');
    packages.debugRootOverride = root;
  });

  tearDown(() {
    packages.debugRootOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('名称 / 版本 / 简介 / 作者 / 权限全部来自 metadata.json', () async {
    layOut(
      'com.lemon.weather',
      metadata:
          '{"id":"com.lemon.weather","name":"包里叫这个名字","version":"2.3.4",'
          '"description":"包里写的简介","author":"作者名","permissions":["location"]}',
    );
    // 应用清单里留的是市场名字（安装时同步过来的旧值）
    await ApplicationRegistry.instance.ensureKnown(
      appId: 'com.lemon.weather',
      name: '市场里的名字',
      icon: 'https://cdn.example/icon.png',
    );

    final InstalledAppInfo info = await loadInstalledAppInfo('com.lemon.weather');
    expect(info.name, '包里叫这个名字');
    expect(info.version, '2.3.4');
    expect(info.versionLabel, 'v2.3.4');
    expect(info.description, '包里写的简介');
    expect(info.author, '作者名');
    expect(info.permissionIds, <String>['location']);
    expect(info.fromMetadata, isTrue);
    // 图标地址仍然留着当兜底（包内没有图标时用）
    expect(info.iconUrl, 'https://cdn.example/icon.png');
    expect(info.iconPath, isNull);
  });

  test('包内图标被解析成绝对路径', () async {
    layOut(
      'com.demo.icon',
      metadata:
          '{"id":"com.demo.icon","name":"带图标","version":"1.0.0","icon":"assets/i.png"}',
      iconFile: 'assets/i.png',
    );
    final InstalledAppInfo info = await loadInstalledAppInfo('com.demo.icon');
    expect(info.iconPath, p.join(root.path, 'com.demo.icon', 'assets', 'i.png'));
    expect(File(info.iconPath!).existsSync(), isTrue);
  });

  test('图标路径越界（../）被忽略', () async {
    layOut(
      'com.demo.evil',
      metadata:
          '{"id":"com.demo.evil","name":"越界","version":"1.0.0","icon":"../../etc/passwd"}',
    );
    final InstalledAppInfo info = await loadInstalledAppInfo('com.demo.evil');
    expect(info.iconPath, isNull);
  });

  test('没有 metadata.json 的老包退回清单里的名字', () async {
    final Directory dir = Directory(p.join(root.path, 'com.old.app'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'index.html')).writeAsStringSync('<h1>x</h1>');
    File(p.join(dir.path, '.install.json')).writeAsStringSync(
      '{"version":"1.0.0","entry":"index.html"}',
    );
    await ApplicationRegistry.instance.ensureKnown(
      appId: 'com.old.app',
      name: '旧应用',
    );

    final InstalledAppInfo info = await loadInstalledAppInfo('com.old.app');
    expect(info.name, '旧应用');
    expect(info.version, '1.0.0');
    expect(info.fromMetadata, isFalse);
    expect(info.iconPath, isNull);
  });

  test('本机没有包时不崩：只是一个「安装包已丢失」的条目', () async {
    await ApplicationRegistry.instance.ensureKnown(
      appId: 'com.gone.app',
      name: '已经没了',
    );
    final InstalledAppInfo info = await loadInstalledAppInfo('com.gone.app');
    expect(info.installed, isFalse);
    expect(info.name, '已经没了');
    expect(info.versionLabel, '版本未知');
  });
}

// test/miniapp_zip_test.dart
//
// 「小程序测试 → 导入本地 ZIP」。
//
// 这条路径几乎全是文件系统操作：解压、找入口、写完成标记、切 current、
// 清旧版本。**任何一步写错都不会报错**，只会表现成「点开白屏」或
// 「改了包还是旧页面」—— 所以这里逐条钉住。
//
// 不 mock path_provider：MiniappPackageService 留了 debugRootOverride，
// 直接指到临时目录即可（见该字段的注释）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/services/miniapp_package_service.dart';
import 'package:path/path.dart' as p;

/// 打一个 zip 出来。files 的 key 是包内路径。
Uint8List makeZip(Map<String, String> files) {
  final Archive archive = Archive();
  files.forEach((String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final List<int> encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final MiniappPackageService service = MiniappPackageService.instance;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ll-miniapp-zip-');
    service.debugRootOverride = root;
  });

  tearDown(() {
    service.debugRootOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('没有 metadata.json 时按文件名推 appId，入口取 index.html', () async {
    final Uint8List zip = makeZip(<String, String>{
      'index.html': '<h1>hi</h1>',
      'style.css': 'body{}',
    });

    final InstalledPackage pkg = await service.installLocalZip(
      zip,
      fileName: '我的小工具.zip',
    );

    // 中文文件名会被净化成下划线，但一定带 dev.local. 前缀，
    // 不可能撞上市场上的正式 id
    expect(pkg.appId, startsWith('dev.local.'));
    expect(pkg.entry, 'index.html');
    expect(pkg.version, startsWith('dev-'));
    expect(File(p.join(pkg.dir, 'index.html')).existsSync(), isTrue);
    expect(File(p.join(pkg.dir, 'style.css')).existsSync(), isTrue);
    // 完成标记与 current 指针是「装好了」的唯一凭据
    expect(File(p.join(pkg.dir, '.complete')).existsSync(), isTrue);
    expect(File(p.join(root.path, pkg.appId, 'current')).existsSync(), isTrue);
    expect(pkg.isUsable, isTrue);
  });

  test('有 metadata.json 时以包声明的 id 与 entry 为准', () async {
    final Uint8List zip = makeZip(<String, String>{
      'lemonlite.json': '{"id":"com.demo.app","name":"演示"}',
      'app/main.html': '<h1>main</h1>',
      'metadata.json':
          '{"id":"com.demo.app","name":"演示应用","entry":"app/main.html"}',
    });

    final InstalledPackage pkg = await service.installLocalZip(
      zip,
      fileName: 'whatever.zip',
    );

    expect(pkg.appId, 'com.demo.app');
    expect(pkg.entry, 'app/main.html');
    expect(pkg.metadata?.name, '演示应用');
    expect(File(p.join(pkg.dir, 'app', 'main.html')).existsSync(), isTrue);
  });

  test('包外面多套一层目录也能找到入口', () async {
    final Uint8List zip = makeZip(<String, String>{
      'my-app/index.html': '<h1>nested</h1>',
      'my-app/metadata.json':
          '{"id":"com.demo.nested","name":"套了一层","entry":"index.html"}',
    });

    final InstalledPackage pkg = await service.installLocalZip(zip);

    expect(pkg.appId, 'com.demo.nested');
    expect(pkg.entry, 'my-app/index.html');
    expect(pkg.isUsable, isTrue);
  });

  test('缺入口时报错，且不留下半个包', () async {
    final Uint8List zip = makeZip(<String, String>{'other.txt': 'x'});

    await expectLater(
      service.installLocalZip(zip, fileName: 'broken.zip'),
      throwsA(
        isA<PackageException>().having(
          (PackageException e) => e.code,
          'code',
          'missing_entry',
        ),
      ),
    );
    // 目标目录必须被清掉：留着的话下次会读到「有目录但没入口」，
    // 看起来像装好了，打开却白屏
    expect(root.listSync().whereType<Directory>(), isEmpty);
  });

  test('包内有越界路径 → bad_path', () async {
    final Uint8List zip = makeZip(<String, String>{
      'index.html': 'ok',
      '../../evil.txt': 'bad',
    });

    await expectLater(
      service.installLocalZip(zip, fileName: 'evil.zip'),
      throwsA(
        isA<PackageException>().having(
          (PackageException e) => e.code,
          'code',
          'bad_path',
        ),
      ),
    );
  });

  test('坏 zip → bad_zip 而不是抛 FormatException', () async {
    await expectLater(
      service.installLocalZip(
        Uint8List.fromList(<int>[1, 2, 3, 4]),
        fileName: 'x.zip',
      ),
      throwsA(isA<PackageException>()),
    );
  });

  test('空文件 → empty_zip', () async {
    await expectLater(
      service.installLocalZip(Uint8List(0)),
      throwsA(
        isA<PackageException>().having(
          (PackageException e) => e.code,
          'code',
          'empty_zip',
        ),
      ),
    );
  });

  test('同一个包再次导入会覆盖上一次，磁盘上只留一个 dev 版本', () async {
    final Uint8List zip = makeZip(<String, String>{'index.html': 'v1'});

    final InstalledPackage first = await service.installLocalZip(
      zip,
      fileName: 'demo.zip',
    );
    // 时间戳精确到毫秒，连续两次可能撞上同一个值；隔一下让版本号必然不同
    await Future<void>.delayed(const Duration(milliseconds: 5));

    final Uint8List zip2 = makeZip(<String, String>{'index.html': 'v2'});
    final InstalledPackage second = await service.installLocalZip(
      zip2,
      fileName: 'demo.zip',
    );

    expect(second.appId, first.appId);
    expect(second.version, isNot(first.version));

    final Directory appRoot = Directory(p.join(root.path, second.appId));
    final List<String> dirs = appRoot.listSync()
        .whereType<Directory>()
        .map((Directory d) => p.basename(d.path))
        .toList();
    expect(dirs, <String>[second.version]);
    // 新包的内容真的生效了
    expect(
      File(p.join(second.dir, 'index.html')).readAsStringSync(),
      'v2',
    );
    // current 指向新版本
    final String pointer = File(p.join(appRoot.path, 'current')).readAsStringSync();
    expect(pointer, contains(second.version));
  });
}

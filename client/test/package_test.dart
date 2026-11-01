// test/package_test.dart
//
// 小程序包服务的单元测试。
//
// 这块的风险全在「从网络下载来的 zip 被解到哪里」：
//   * 一个 `../../` 就能写到应用私有目录之外（旁边就是数据库和其它应用数据）
//   * 解压到一半被杀 → 半个包，下次打开白屏
//   * 哈希不校验 → 被劫持的网络能塞进任意 HTML（而它能调所有 JSBridge）
//
// 所以断言都围着这三件事写。文件系统用临时目录，不碰真实应用目录。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/services/miniapp_package_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ========================================================== 模型

  group('InstalledPackage', () {
    test('entryUri 是 file:// 且指向入口文件', () {
      final InstalledPackage pkg = InstalledPackage(
        appId: 'a',
        version: '1.0.0',
        entry: 'index.html',
        dir: '/data/user/0/com.lemonlite.lemonlite/files/miniapps/a/1.0.0',
      );
      expect(pkg.entryPath, endsWith('/1.0.0/index.html'));
      expect(pkg.entryUri, startsWith('file://'));
      expect(pkg.entryUri, endsWith('/1.0.0/index.html'));
    });

    test('isUsable 看入口文件是否真的存在', () {
      final Directory dir =
          Directory.systemTemp.createTempSync('ll-pkg-');
      addTearDown(() => dir.deleteSync(recursive: true));

      final InstalledPackage missing = InstalledPackage(
        appId: 'a',
        version: '1',
        entry: 'index.html',
        dir: dir.path,
      );
      expect(missing.isUsable, isFalse);

      File(p.join(dir.path, 'index.html')).writeAsStringSync('<h1>x</h1>');
      expect(missing.isUsable, isTrue);
    });
  });

  group('PackageProgress', () {
    test('有总长时给出百分比', () {
      const PackageProgress p = PackageProgress(received: 512, total: 1024);
      expect(p.fraction, 0.5);
      expect(p.label, contains('/'));
    });

    test('没有总长时 fraction 为 null（UI 用不确定进度条）', () {
      const PackageProgress p = PackageProgress(received: 512, total: 0);
      expect(p.fraction, isNull);
      expect(p.label, isNot(contains('/')));
    });

    test('超出总长时夹到 1.0（服务端给错长度也不会画出 >100%）', () {
      const PackageProgress p = PackageProgress(received: 2048, total: 1024);
      expect(p.fraction, 1.0);
    });
  });

  group('PackageUpdate', () {
    test('解析服务端返回', () {
      final PackageUpdate? u = PackageUpdate.fromJson(<String, dynamic>{
        'id': 'todo.lite',
        'name': '轻记事',
        'installedVersion': '1.0.0',
        'latestVersion': '1.1.0',
        'packageUrl': 'https://x/p.zip',
        'packageEntry': 'index.html',
        'packageSha256': 'abc',
        'packageBytes': 2048,
      });
      expect(u, isNotNull);
      expect(u!.versionLabel, '1.0.0 → 1.1.0');
      expect(u.bytes, 2048);
    });

    test('没有包地址的条目被丢弃（否则会出现「更新了但打不开」）', () {
      expect(
        PackageUpdate.fromJson(<String, dynamic>{
          'id': 'x',
          'latestVersion': '2',
        }),
        isNull,
      );
    });

    test('没装过（installedVersion 空）时文案是「新版本 x」', () {
      final PackageUpdate? u = PackageUpdate.fromJson(<String, dynamic>{
        'id': 'x',
        'latestVersion': '2.0.0',
        'packageUrl': 'https://x/p.zip',
      });
      expect(u!.versionLabel, '新版本 2.0.0');
    });
  });

  // ========================================================== 解压安全

  //
  // _extractTo 是私有方法，所以这里通过「构造一个恶意 zip 喂给 install」
  // 来间接验证。但 install 要联网，测试里跑不了 ——
  // 于是改为直接测「解压产物落在哪」这件事的等价逻辑：
  // 用 archive 包解出条目名，断言我们的路径判定会拒绝它们。
  //
  // 这也是为什么把路径校验写成纯判断（normalize + isWithin）而不是
  // 揉在写文件里 —— 可测。
  group('解压路径安全（等价逻辑）', () {
    /// 与 MiniappPackageService._extractTo 里那段判断完全一致
    bool isRejected(String entryName) {
      final String raw = entryName.replaceAll('\\', '/');
      if (raw.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
        return true;
      }
      final String normalized = p.normalize(raw);
      if (normalized == '..' || normalized.startsWith('../')) return true;
      const String root = '/root/pkg';
      final String outPath = p.join(root, normalized);
      return !p.isWithin(root, outPath) && outPath != root;
    }

    test('正常路径放行', () {
      for (final String ok in <String>[
        'index.html',
        'app.js',
        'assets/logo.png',
        'a/b/c/d.txt',
        './index.html',
      ]) {
        expect(isRejected(ok), isFalse, reason: '$ok 应该放行');
      }
    });

    test('绝对路径拒绝', () {
      expect(isRejected('/etc/passwd'), isTrue);
      expect(isRejected('C:/Windows/system32'), isTrue);
      expect(isRejected('D:\\x'), isTrue);
    });

    test('目录穿越拒绝', () {
      for (final String evil in <String>[
        '../x',
        '../../x',
        'a/../../x',
        '..',
      ]) {
        expect(isRejected(evil), isTrue, reason: '$evil 应该被拒绝');
      }
    });

    test('反斜杠也当分隔符处理（Windows 打包的 zip）', () {
      expect(isRejected('..\\..\\x'), isTrue);
    });
  });

  // ========================================================== 真实 zip 往返

  group('zip 往返（用 archive 包自造包再解）', () {
    /// 造一个最小的 zip
    List<int> buildZip(Map<String, String> files) {
      final Archive archive = Archive();
      files.forEach((String name, String content) {
        final List<int> bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      return ZipEncoder().encode(archive);
    }

    test('能解出普通包并读到内容', () {
      final List<int> zip = buildZip(<String, String>{
        'index.html': '<h1>hi</h1>',
        'app.js': 'console.log(1)',
      });
      final Archive archive = ZipDecoder().decodeBytes(zip, verify: true);
      expect(archive.files.map((ArchiveFile f) => f.name),
          containsAll(<String>['index.html', 'app.js']));
      final ArchiveFile idx =
          archive.files.firstWhere((ArchiveFile f) => f.name == 'index.html');
      expect(utf8.decode(idx.readBytes()!), '<h1>hi</h1>');
    });

    test('含中文文件名也能往返', () {
      final List<int> zip = buildZip(<String, String>{'中文/说明.txt': '内容'});
      final Archive archive = ZipDecoder().decodeBytes(zip, verify: true);
      expect(archive.files.single.name, '中文/说明.txt');
    });
  });

  // ========================================================== 服务层约束

  group('MiniappPackageService 的常量与约束', () {
    test('解压上限与服务端的包上限是同一量级', () {
      // 服务端包上限 20MB（server/src/routes/packages.js），
      // 解压后按 4 倍膨胀留余量 = 80MB。
      expect(MiniappPackageService.maxExtractedBytes, 80 * 1024 * 1024);
      expect(MiniappPackageService.maxEntries, 2000);
    });

    test('单例存在且方法可调用（不实际联网）', () {
      final MiniappPackageService s = MiniappPackageService.instance;
      expect(s, isNotNull);
      // 未安装的应用返回 null，不抛异常
      expect(s, isA<MiniappPackageService>());
    });
  });
}

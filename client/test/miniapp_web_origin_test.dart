// test/miniapp_web_origin_test.dart
//
// 本地包的虚拟源（https://miniapp.lemonlite.local/<appId>/<version>/…）。
//
// 这里钉三件事：
//   1. URL 生成与解析是同一套规则 —— 生成出来的地址必须能被解析回同一个文件，
//      否则「小程序能打开」只是碰巧；
//   2. **不能让路径爬出 miniapps 目录**：打包方（甚至恶意包）可以写任意
//      entry / 相对引用，读到别的应用的数据就晚了；
//   3. 字体 / wasm 的 MIME 必须给对，Chromium 对字体有白名单。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/core/miniapp_web_origin.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('miniapp-origin-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('地址生成', () {
    test('入口地址带 appId / 版本 / 包内路径', () {
      final Uri url = MiniappWebOrigin.entryUrl(
        appId: 'com.lemon.weather',
        version: 'dev-1794823163572',
        entry: 'index.html',
      );
      expect(
        url.toString(),
        'https://miniapp.lemonlite.local/com.lemon.weather/dev-1794823163572/index.html',
      );
      expect(MiniappWebOrigin.owns(url), isTrue);
    });

    test('子目录入口逐段编码，斜杠不丢', () {
      final Uri url = MiniappWebOrigin.entryUrl(
        appId: 'a.b',
        version: '1.0.0',
        entry: 'pages/home index.html',
      );
      expect(url.pathSegments, <String>['a.b', '1.0.0', 'pages', 'home index.html']);
    });

    test('不是我们的 host / scheme 一律不接管', () {
      expect(
        MiniappWebOrigin.owns(Uri.parse('https://example.com/a/b/index.html')),
        isFalse,
      );
      expect(
        MiniappWebOrigin.owns(
          Uri.parse('http://miniapp.lemonlite.local/a/b/index.html'),
        ),
        isFalse,
      );
      expect(
        MiniappWebOrigin.owns(Uri.file('/tmp/a/b/index.html')),
        isFalse,
      );
    });

    test('只有 .html / .htm 是页面', () {
      Uri u(String path) => Uri.parse('https://miniapp.lemonlite.local/a/b/$path');
      expect(MiniappWebOrigin.isDocument(u('index.html')), isTrue);
      expect(MiniappWebOrigin.isDocument(u('INDEX.HTM')), isTrue);
      expect(MiniappWebOrigin.isDocument(u('app.js')), isFalse);
      expect(MiniappWebOrigin.isDocument(u('styles.css')), isFalse);
    });
  });

  group('路径映射', () {
    test('正常路径 → 包目录下的文件', () {
      final Uri url = MiniappWebOrigin.entryUrl(
        appId: 'com.lemon.weather',
        version: '1.0.0',
        entry: 'index.html',
      );
      final File? file = MiniappWebOrigin.resolve(url, root);
      expect(file, isNotNull);
      expect(
        p.normalize(file!.path),
        p.normalize(p.join(root.path, 'com.lemon.weather', '1.0.0', 'index.html')),
      );
    });

    test('子资源也落在同一个包目录里', () {
      final Uri url = Uri.parse(
        'https://miniapp.lemonlite.local/app/1.0.0/assets/icons/logo.svg',
      );
      final File? file = MiniappWebOrigin.resolve(url, root);
      expect(file, isNotNull);
      expect(file!.path, endsWith(p.join('assets', 'icons', 'logo.svg')));
    });

    test('.. 越界被挡（Uri 会先规范化点段，逃出包目录就只剩 404）', () {
      for (final String path in <String>[
        // 明文点段由 Uri 规范化消掉 → 段数不足
        'https://miniapp.lemonlite.local/app/1.0.0/../../../etc/passwd',
        // 编码的点段同样被 Uri 按 RFC 3986 规范化，一样逃不出去
        'https://miniapp.lemonlite.local/app/1.0.0/%2e%2e/%2e%2e/secret.txt',
        'https://miniapp.lemonlite.local/app/1.0.0/%2e%2e/%2e%2e/%2e%2e/%2e%2e/tmp/x.txt',
      ]) {
        expect(
          MiniappWebOrigin.resolve(Uri.parse(path), root),
          isNull,
          reason: path,
        );
      }
    });

    test('段数不足 / 空段 / 反斜杠 / NUL 都被挡', () {
      for (final String path in <String>[
        'https://miniapp.lemonlite.local/',
        'https://miniapp.lemonlite.local/index.html',
        'https://miniapp.lemonlite.local/app//index.html',
        'https://miniapp.lemonlite.local/app/1.0.0/a%5Cb.js',
        'https://miniapp.lemonlite.local/app/1.0.0/a%00b.js',
      ]) {
        expect(
          MiniappWebOrigin.resolve(Uri.parse(path), root),
          isNull,
          reason: path,
        );
      }
    });

    test('跨包请求不属于当前会话（A 读不到 B 的文件）', () {
      final Uri other = Uri.parse(
        'https://miniapp.lemonlite.local/com.other.app/1.0.0/index.html',
      );
      expect(
        MiniappWebOrigin.belongsTo(
          other,
          appId: 'com.lemon.weather',
          version: '1.0.0',
        ),
        isFalse,
      );

      final Uri mine = MiniappWebOrigin.entryUrl(
        appId: 'com.lemon.weather',
        version: 'dev-1',
        entry: 'index.html',
      );
      expect(
        MiniappWebOrigin.belongsTo(
          mine,
          appId: 'com.lemon.weather',
          version: 'dev-1',
        ),
        isTrue,
      );
      // 版本不同也算越界：旧版本目录可能还没删
      expect(
        MiniappWebOrigin.belongsTo(
          mine,
          appId: 'com.lemon.weather',
          version: 'dev-2',
        ),
        isFalse,
      );
    });
  });

  group('MIME', () {
    test('字体 / wasm / 脚本给出会被 Chromium 接受的类型', () {
      expect(MiniappWebOrigin.mimeFor('a/b/material-symbols.ttf'), 'font/ttf');
      expect(MiniappWebOrigin.mimeFor('a/b/app.wasm'), 'application/wasm');
      expect(MiniappWebOrigin.mimeFor('a/b/app.js'), startsWith('text/javascript'));
      expect(MiniappWebOrigin.mimeFor('a/b/index.html'), startsWith('text/html'));
      expect(MiniappWebOrigin.mimeFor('a/b/x.unknown'), 'application/octet-stream');
    });
  });
}

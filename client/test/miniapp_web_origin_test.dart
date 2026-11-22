
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
    test('入口地址带 appId / 包内路径，版本退化成查询串', () {
      final Uri url = MiniappWebOrigin.entryUrl(
        appId: 'com.lemon.weather',
        version: 'dev-1794823163572',
        entry: 'index.html',
      );
      expect(
        url.toString(),
        'https://miniapp.lemonlite.local/com.lemon.weather/index.html'
        '?v=dev-1794823163572',
      );
      expect(MiniappWebOrigin.owns(url), isTrue);
    });

    test('子目录入口逐段编码，斜杠不丢', () {
      final Uri url = MiniappWebOrigin.entryUrl(
        appId: 'a.b',
        version: '1.0.0',
        entry: 'pages/home index.html',
      );
      expect(url.pathSegments, <String>['a.b', 'pages', 'home index.html']);
    });

    test('版本为空时不带查询串（本地导入没有版本号的情况）', () {
      final Uri url = MiniappWebOrigin.entryUrl(
        appId: 'a.b',
        version: '',
        entry: 'index.html',
      );
      expect(url.toString(), 'https://miniapp.lemonlite.local/a.b/index.html');
    });

    test('不是我们的 host / scheme 一律不接管', () {
      expect(
        MiniappWebOrigin.owns(Uri.parse('https://example.com/a/index.html')),
        isFalse,
      );
      expect(
        MiniappWebOrigin.owns(
          Uri.parse('http://miniapp.lemonlite.local/a/index.html'),
        ),
        isFalse,
      );
      expect(MiniappWebOrigin.owns(Uri.file('/tmp/a/index.html')), isFalse);
    });

    test('只有 .html / .htm 是页面', () {
      Uri u(String path) => Uri.parse('https://miniapp.lemonlite.local/a/$path');
      expect(MiniappWebOrigin.isDocument(u('index.html')), isTrue);
      expect(MiniappWebOrigin.isDocument(u('INDEX.HTM')), isTrue);
      expect(MiniappWebOrigin.isDocument(u('app.js')), isFalse);
      expect(MiniappWebOrigin.isDocument(u('styles.css')), isFalse);
    });
  });

  group('路径映射', () {
    test('正常路径 → app/<appId>/<相对路径>', () {
      final Uri url = MiniappWebOrigin.entryUrl(
        appId: 'com.lemon.weather',
        version: '1.0.0',
        entry: 'index.html',
      );
      final File? file = MiniappWebOrigin.resolve(url, root);
      expect(file, isNotNull);
      expect(
        p.normalize(file!.path),
        p.normalize(p.join(root.path, 'com.lemon.weather', 'index.html')),
      );
    });

    test('子资源也落在同一个应用目录里', () {
      final Uri url = Uri.parse(
        'https://miniapp.lemonlite.local/app/assets/icons/logo.svg',
      );
      final File? file = MiniappWebOrigin.resolve(url, root);
      expect(file, isNotNull);
      expect(file!.path, endsWith(p.join('assets', 'icons', 'logo.svg')));
    });

    test('各种点段写法都跑不出 app/ 根目录', () {
      for (final String path in <String>[
        'https://miniapp.lemonlite.local/app/%2e%2e/%2e%2e/secret.txt',
        'https://miniapp.lemonlite.local/app/%2e%2e/%2e%2e/%2e%2e/tmp/x.txt',
        'https://miniapp.lemonlite.local/app/../../../etc/passwd',
      ]) {
        final File? file = MiniappWebOrigin.resolve(Uri.parse(path), root);
        if (file != null) {
          expect(
            p.isWithin(p.normalize(root.path), p.normalize(file.path)),
            isTrue,
            reason: path,
          );
        }
      }
    });

    test('点段被规范化成别的应用名时，belongsTo 兜住', () {
      // ../../.. 在解析阶段就没了，剩下的 /etc/passwd 会被当成 appId=etc。
      // 资源服务器先问 belongsTo —— 不是当前会话的包，一律 404。
      final Uri escaped = Uri.parse(
        'https://miniapp.lemonlite.local/app/../../../etc/passwd',
      );
      expect(MiniappWebOrigin.belongsTo(escaped, appId: 'app'), isFalse);
    });

    test('段数不足 / 空段 / 反斜杠 / NUL 都被挡', () {
      for (final String path in <String>[
        'https://miniapp.lemonlite.local/',
        'https://miniapp.lemonlite.local/index.html',
        'https://miniapp.lemonlite.local/app//index.html',
        'https://miniapp.lemonlite.local/app/a%5Cb.js',
        'https://miniapp.lemonlite.local/app/a%00b.js',
      ]) {
        expect(
          MiniappWebOrigin.resolve(Uri.parse(path), root),
          isNull,
          reason: path,
        );
      }
    });

    test('点开头的路径不被服务（安装信息 / app.zip 之外的内部文件）', () {
      for (final String path in <String>[
        'https://miniapp.lemonlite.local/app/.install.json',
        'https://miniapp.lemonlite.local/app/.complete',
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
        'https://miniapp.lemonlite.local/com.other.app/index.html',
      );
      expect(
        MiniappWebOrigin.belongsTo(other, appId: 'com.lemon.weather'),
        isFalse,
      );

      final Uri mine = MiniappWebOrigin.entryUrl(
        appId: 'com.lemon.weather',
        version: 'dev-1',
        entry: 'index.html',
      );
      expect(
        MiniappWebOrigin.belongsTo(mine, appId: 'com.lemon.weather'),
        isTrue,
      );
    });
  });

  group('MIME', () {
    test('字体 / wasm / 脚本给出会被 Chromium 接受的类型', () {
      expect(MiniappWebOrigin.mimeFor('a/material-symbols.ttf'), 'font/ttf');
      expect(MiniappWebOrigin.mimeFor('a/app.wasm'), 'application/wasm');
      expect(MiniappWebOrigin.mimeFor('a/app.js'), startsWith('text/javascript'));
      expect(MiniappWebOrigin.mimeFor('a/index.html'), startsWith('text/html'));
      expect(MiniappWebOrigin.mimeFor('a/x.unknown'), 'application/octet-stream');
    });
  });
}

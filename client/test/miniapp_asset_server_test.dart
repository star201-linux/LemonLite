// test/miniapp_asset_server_test.dart
//
// 拦截回调的业务逻辑：虚拟源请求 → 文件响应。
//
// 这里是「小程序能不能真的跑起来」的那一层，所以钉得细一点：
//   * 页面要交给 MD3E 改写（样式必须先进解析器）；
//   * 脚本 / 字体要给对 MIME，二进制不能声明 utf-8；
//   * 缺文件 / 跨包 / 越界一律 404 —— 返回 null 会让 WebView 去 DNS 解析
//     miniapp.lemonlite.local，错误信息会变成「网络不可用」，没法排障。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/core/miniapp_asset_server.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory pkg;
  late MiniappAssetServer server;

  Uri asset(String path) => Uri.parse(
    'https://miniapp.lemonlite.local/com.lemon.weather/$path',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('miniapp-assets-');
    pkg = Directory(p.join(root.path, 'com.lemon.weather'))
      ..createSync(recursive: true);
    File(p.join(pkg.path, 'index.html')).writeAsStringSync(
      '<html><head></head><body>hi</body></html>',
    );
    File(p.join(pkg.path, 'app.js')).writeAsStringSync(
      "import { Icons } from './icons.js';\nconsole.log(Icons);",
    );
    Directory(p.join(pkg.path, 'fonts')).createSync();
    File(p.join(pkg.path, 'fonts', 'sym.ttf')).writeAsBytesSync(
      <int>[0, 1, 2, 3, 255, 254],
    );

    server = MiniappAssetServer(root: root, appId: 'com.lemon.weather');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('页面交给改写器，返回改写后的 HTML', () async {
    Uri? seenUrl;
    File? seenFile;
    final response = await server.respond(
      asset('index.html'),
      documentRenderer: (Uri url, File file) async {
        seenUrl = url;
        seenFile = file;
        return MiniappAssetServer.notFound(url);
      },
    );

    expect(seenUrl, asset('index.html'));
    expect(seenFile!.path, endsWith(p.join('com.lemon.weather', 'index.html')));
    // 返回值就是改写器的返回值：调用链没有偷偷把原文再包一层
    expect(response!.statusCode, 404);
  });

  test('脚本按 text/javascript + utf-8 返回，内容一字节不差', () async {
    final String source = File(p.join(pkg.path, 'app.js')).readAsStringSync();
    final response = await server.respond(asset('app.js'));

    expect(response!.statusCode, 200);
    expect(response.contentType, startsWith('text/javascript'));
    expect(response.contentEncoding, 'utf-8');
    expect(utf8.decode(response.data!), source);
    expect(response.headers!['Cache-Control'], 'no-store');
  });

  test('字体是二进制：MIME 正确且不声明文本编码', () async {
    final response = await server.respond(asset('fonts/sym.ttf'));

    expect(response!.statusCode, 200);
    expect(response.contentType, 'font/ttf');
    expect(
      response.contentEncoding,
      isNull,
      reason: '给 ttf 声明 utf-8 会被当文本解码，字体静默失效',
    );
    expect(response.data, <int>[0, 1, 2, 3, 255, 254]);
  });

  test('文件不存在 → 404（不是 null，别让 WebView 去解析域名）', () async {
    final response = await server.respond(asset('nope.js'));
    expect(response, isNotNull);
    expect(response!.statusCode, 404);
  });

  test('跨包 → 404：A 读不到 B 的文件', () async {
    final Directory other = Directory(
      p.join(root.path, 'com.other.app'),
    )..createSync(recursive: true);
    File(p.join(other.path, 'index.html')).writeAsStringSync('secret');

    final response = await server.respond(
      Uri.parse('https://miniapp.lemonlite.local/com.other.app/index.html'),
    );
    expect(response!.statusCode, 404);
  });

  test('越界路径 → 404', () async {
    // Uri 会把明文点段规范化掉，这里用编码形式确保「解码后才是 ..」也挡得住
    final Uri escaped = Uri.parse(
      'https://miniapp.lemonlite.local/com.lemon.weather/%2e%2e/%2e%2e/etc/passwd',
    );
    expect((await server.respond(escaped))!.statusCode, 404);
  });

  test('外链 / 其它 host → null（交回 WebView）', () async {
    expect(
      await server.respond(Uri.parse('https://example.com/a.js')),
      isNull,
    );
    expect(await server.respond(Uri.parse('https://uapis.cn/api/v1/x')), isNull);
  });
}

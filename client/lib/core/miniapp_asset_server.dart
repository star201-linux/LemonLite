// lib/core/miniapp_asset_server.dart
//
// 把「虚拟源的请求」翻译成「本地文件的响应」。
//
// 这层单独拎出来有两个原因：
//   1. 它是 WebView 拦截回调的**全部业务逻辑**，放在 State 里没法测；
//   2. 它必须能回答「这个请求能不能出、出什么 MIME、缺文件怎么办」，
//      而这些问题跟 Widget 生命周期毫无关系。
//
// 约定：
//   * 不属于虚拟源（外链 / 其它 scheme）→ 返回 null，交回 WebView 默认流程；
//   * 属于虚拟源但路径不合法 / 文件不存在 / 跨包 → 返回 404，**绝不返回 null**。
//     返回 null 会让 Chromium 去 DNS 解析 miniapp.lemonlite.local，
//     页面会变成莫名其妙的网络错误，而不是一个可以说清楚的 404。
//
// 页面（.html）的改写由调用方注入 [documentRenderer]：core 不认识主题系统，
// 主题也不该反过来 import 这里。测试里传一个替身就能验证「页面确实被改写」。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'globals.dart';
import 'miniapp_web_origin.dart';

/// 页面改写器：拿到虚拟 URL 与真实文件，返回最终响应（返回 null = 按原样加载）。
typedef MiniappDocumentRenderer =
    Future<WebResourceResponse?> Function(Uri url, File file);

class MiniappAssetServer {
  MiniappAssetServer({required this.root, required this.appId});

  /// `app/` 根目录（每个小程序一个子目录）
  final Directory root;

  /// 当前会话的应用。只服务它的资源。
  final String appId;

  /// 处理一个请求。[documentRenderer] 只对 .html 生效。
  Future<WebResourceResponse?> respond(
    Uri url, {
    MiniappDocumentRenderer? documentRenderer,
  }) async {
    if (!MiniappWebOrigin.owns(url)) return null;

    // 包里的脚本可以随便拼 URL，但拼到别的应用身上一律 404
    if (!MiniappWebOrigin.belongsTo(url, appId: appId)) {
      lemonLog('Miniapp', '拒绝跨包资源：${url.path}');
      return notFound(url);
    }

    final File? file = MiniappWebOrigin.resolve(url, root);
    if (file == null || !file.existsSync()) {
      lemonLog('Miniapp', '资源不存在：${url.path}');
      return notFound(url);
    }

    if (MiniappWebOrigin.isDocument(url)) {
      final MiniappDocumentRenderer? render = documentRenderer;
      if (render != null) return render(url, file);
    }

    try {
      final Uint8List bytes = await file.readAsBytes();
      final String mime = MiniappWebOrigin.mimeFor(file.path);
      final bool textual = mime.startsWith('text/') ||
          mime.contains('json') ||
          mime.contains('javascript') ||
          mime.contains('xml') ||
          mime.contains('svg');
      return WebResourceResponse(
        contentType: mime,
        // 二进制（字体 / 图片 / wasm）不要声明编码：Chromium 会按文本解码，
        // 1MB 的 ttf 直接被当垃圾读，字体就静默失效了。
        contentEncoding: textual ? 'utf-8' : null,
        data: bytes,
        statusCode: 200,
        reasonPhrase: 'OK',
        // 重新导入 / 升级之后同一个 URL 下面的文件会变，
        // 不让 WebView 拿旧的内存缓存。
        headers: const <String, String>{'Cache-Control': 'no-store'},
      );
    } catch (e) {
      lemonLog('Miniapp', '资源读取失败：${url.path} · $e');
      return notFound(url);
    }
  }

  /// 404 响应。静态方法：调用方在拿到根目录之前也可能要用它。
  static WebResourceResponse notFound(Uri url) => WebResourceResponse(
    contentType: 'text/plain; charset=utf-8',
    contentEncoding: 'utf-8',
    data: Uint8List.fromList(utf8.encode('404 Not Found: ${url.path}')),
    statusCode: 404,
    reasonPhrase: 'Not Found',
    headers: const <String, String>{'Cache-Control': 'no-store'},
  );
}

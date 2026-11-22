
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

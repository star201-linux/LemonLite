
import 'dart:io';

import 'package:path/path.dart' as p;

/// 小程序本地包的虚拟源。纯路径逻辑，不依赖 WebView 包，便于单测。
class MiniappWebOrigin {
  const MiniappWebOrigin._();

  static const String scheme = 'https';
  static const String host = 'miniapp.lemonlite.local';
  static const String _root = '$scheme://$host';

  /// 入口地址。
  ///
  /// `entry` 允许带子目录（`pages/index.html`），逐段编码；appId 里的点
  /// （`com.lemon.weather`）不需要转义，encodeComponent 也不会动它。
  /// `version` 只进查询串，不参与文件映射。
  static Uri entryUrl({
    required String appId,
    required String version,
    required String entry,
  }) {
    final String path = entry
        .split('/')
        .where((String s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final String query = version.trim().isEmpty
        ? ''
        : '?v=${Uri.encodeQueryComponent(version)}';
    return Uri.parse(
      '$_root/${Uri.encodeComponent(appId)}/$path$query',
    );
  }

  /// 这个请求是不是「我们自己的」。
  static bool owns(Uri url) => url.scheme == scheme && url.host == host;

  static bool belongsTo(Uri url, {required String appId}) {
    if (!owns(url)) return false;
    final List<String> segments = url.pathSegments;
    return segments.length >= 2 && segments[0] == appId;
  }

  /// 是不是要交给 MD3E 改写的主文档（页面）。
  static bool isDocument(Uri url) {
    final String path = url.path.toLowerCase();
    return path.endsWith('.html') || path.endsWith('.htm');
  }

  /// 请求 → 本地文件。越界 / 段数不对 / 含 .. 一律返回 null。
  ///
  /// 注意：Uri 解析时已经做过点段规范化，所以明文 `a/../../b` 到不了这里
  /// （它早就变成 `b`）。这里挡的是**解码之后**才变成点的写法（`%2e%2e`），
  /// 以及「解析结果跑出包目录」的各种组合。
  static File? resolve(Uri url, Directory root) {
    if (!owns(url)) return null;

    final List<String> segments = url.pathSegments;
    // 至少 appId / 文件 两段，少了就不可能是合法资源
    if (segments.length < 2) return null;
    for (final String segment in segments) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.startsWith('.') ||
          segment.contains('\\') ||
          segment.contains('\u0000')) {
        return null;
      }
    }

    final String rootPath = p.normalize(root.absolute.path);
    // 只允许落在 <root>/<appId>/ 里：跨应用读别人的包也不行
    final String packageRoot = p.normalize(p.join(rootPath, segments[0]));
    final String target = p.normalize(
      p.joinAll(<String>[packageRoot, ...segments.skip(1)]),
    );
    if (!p.isWithin(packageRoot, target)) return null;
    return File(target);
  }

  /// 扩展名 → Content-Type。
  ///
  /// 字体与 wasm 必须给对：Chromium 对字体有 MIME 白名单，
  /// 给成 application/octet-stream 会被拒（Material Symbols 就是 1MB 的 ttf）。
  static String mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.html':
      case '.htm':
        return 'text/html; charset=utf-8';
      case '.js':
      case '.mjs':
        return 'text/javascript; charset=utf-8';
      case '.css':
        return 'text/css; charset=utf-8';
      case '.json':
      case '.map':
        return 'application/json; charset=utf-8';
      case '.svg':
        return 'image/svg+xml';
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.ico':
        return 'image/x-icon';
      case '.ttf':
        return 'font/ttf';
      case '.otf':
        return 'font/otf';
      case '.woff':
        return 'font/woff';
      case '.woff2':
        return 'font/woff2';
      case '.wasm':
        return 'application/wasm';
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.mp4':
        return 'video/mp4';
      case '.webm':
        return 'video/webm';
      case '.txt':
        return 'text/plain; charset=utf-8';
      case '.xml':
        return 'application/xml';
      case '.pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }
}

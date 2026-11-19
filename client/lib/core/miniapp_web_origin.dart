// lib/core/miniapp_web_origin.dart
//
// 小程序包的「虚拟站点」：把本机解压目录暴露成
//   https://miniapp.lemonlite.local/<appId>/<version>/<包内相对路径>
//
// 为什么不再用 file://
// ---------------------------------------------------------------
// 现在的小程序包会用 `<script type="module" src="app.js">` + `import './icons.js'`。
// ES module 的获取**走 CORS 模式**，而 Chromium 明确只允许
// chrome / chrome-untrusted / data / http / https 这几种 scheme，
// file:// 页面的 origin 又是 null，于是控制台只会留下一行：
//
//   Access to script at 'file:///…/app.js' from origin 'null'
//   has been blocked by CORS policy
//
// 主文档照样渲染（骨架、样式都在），脚本却一行不跑 —— 看起来像「页面空了」，
// 实际是整包哑了。把 allowFileAccessFromFileURLs 打开也救不了：
// 那道闸管的是「页面能不能读别的本地文件」，module script 走的是另一条 CORS 规则。
//
// 所以给每个包一个真正的 https 源，由 shouldInterceptRequest 从磁盘喂内容：
//   * 同源 → module / 动态 import / fetch / Worker / localStorage 都按正常网页工作；
//   * 安全上下文（https）→ getUserMedia 等需要 secure context 的能力才谈得上可用；
//   * 依然是纯本地：这个 host 只在本进程的拦截器里存在，永远不会真的发 DNS 请求。
//
// 代价是「页面里的相对路径必须能映射回文件」，所以路径规则要严格：
//   * 只接受 /<appId>/<相对路径> 且每段都非空、不是 . / ..；
//   * 规范化之后必须仍在 app/<appId>/ 里（p.isWithin），否则当 404 ——
//     目录穿越在这里是「读到别的应用的文件」，不能只靠前端不写坏路径。
//
// 版本号不再是路径的一部分（安装布局是 app/<appId>/ 平铺，见
// data/services/miniapp_package_service.dart）：它退化成 `?v=` 查询参数，
// 只用来让 WebView 在升级后不会复用旧的内存缓存。

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

  /// 这个请求是不是**指定应用**的资源。
  ///
  /// 包里的脚本可以随便拼 URL，拼到别的应用身上必须当 404：
  /// 包里没有秘密，可「A 能读到 B 的文件」这种边界不该靠自觉。
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

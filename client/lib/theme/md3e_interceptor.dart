
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/globals.dart';
import '../core/miniapp_web_origin.dart';
import 'md3e_styles.dart';

/// 单条拦截缓存：文件没变、主题没变就直接复用上次的改写结果。
class _CacheEntry {
  const _CacheEntry({
    required this.modified,
    required this.length,
    required this.themeHash,
    required this.html,
  });

  final DateTime modified;
  final int length;
  final String themeHash;
  final String html;
}

class Md3eInterceptor {
  const Md3eInterceptor._();

  /// 缓存上限。小程序包最多几十个页面，8 条足够覆盖主文档的来回切换。
  static const int _maxCache = 8;
  static final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  static bool shouldIntercept(Uri url) =>
      MiniappWebOrigin.owns(url) && MiniappWebOrigin.isDocument(url);

  /// 主文档拦截入口。返回 null 表示「按原样加载」。
  ///
  /// [file] 是虚拟 URL 映射出来的真实文件（调用方已做越界检查）。
  /// [payload] 是 ThemeInjector.toThemePayload 的结果 —— 文档里直接内联
  /// `--md-*` 变量，保证首帧颜色就是对的（不用等 UserScript 跑完）。
  static Future<WebResourceResponse?> intercept({
    required Uri url,
    required File file,
    required Map<String, dynamic> payload,
  }) async {
    final String path = url.path;
    final String cacheKey = url.toString();

    FileStat stat;
    try {
      stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
    } catch (e) {
      lemonLog('Md3e', '拦截时读不到文件：$path · $e');
      return null;
    }

    final String themeHash = _themeHash(payload);
    final _CacheEntry? cached = _cache[cacheKey];
    if (cached != null &&
        cached.length == stat.size &&
        cached.modified == stat.modified &&
        cached.themeHash == themeHash) {
      return _response(cached.html);
    }

    String html;
    try {
      // 小程序包由我们解压，UTF-8 是唯一约定；坏字节不应该让整页打不开
      final Uint8List bytes = await file.readAsBytes();
      html = utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      lemonLog('Md3e', '拦截时读取失败：$path · $e');
      return null;
    }

    final String rewritten = rewriteHtml(html, payload);
    _cache[cacheKey] = _CacheEntry(
      modified: stat.modified,
      length: stat.size,
      themeHash: themeHash,
      html: rewritten,
    );
    if (_cache.length > _maxCache) {
      _cache.remove(_cache.keys.first);
    }

    lemonLog('Md3e', '已拦截主文档：$path（${html.length} → ${rewritten.length} 字符）');
    return _response(rewritten);
  }

  static WebResourceResponse _response(String html) => WebResourceResponse(
    contentType: 'text/html',
    contentEncoding: 'utf-8',
    data: Uint8List.fromList(utf8.encode(html)),
    statusCode: 200,
    reasonPhrase: 'OK',
    headers: <String, String>{
      // 文档已经改写，不要让 WebView 的 HTTP 缓存拿旧版本
      'Cache-Control': 'no-store',
    },
  );

  /// 把「样式表 + DOM 拦截脚本」插到 `<head>` 最前面。
  ///
  /// 顺序：主题变量 → MD3E 基础样式 → DOM 拦截脚本。
  /// 脚本放最后，保证 `document.head` 已经存在、样式节点已经可以查到。
  static String rewriteHtml(String html, Map<String, dynamic> payload) {
    if (html.contains('id="lemonlite-md3e"')) return html; // 已经处理过

    final String injection = _buildHeadInjection(payload);
    final String lower = html.toLowerCase();

    // 1) 有 <head>：插在它的开标签后面（最早的位置，先于任何作者样式）
    final int headIndex = lower.indexOf('<head');
    if (headIndex >= 0) {
      final int headEnd = lower.indexOf('>', headIndex);
      if (headEnd >= 0) {
        return '${html.substring(0, headEnd + 1)}$injection'
          '${html.substring(headEnd + 1)}';
      }
    }

    // 2) 没有 head 但有 <html>：自己补一个 head
    final int htmlIndex = lower.indexOf('<html');
    if (htmlIndex >= 0) {
      final int htmlEnd = lower.indexOf('>', htmlIndex);
      if (htmlEnd >= 0) {
        return '${html.substring(0, htmlEnd + 1)}<head>$injection</head>'
            '${html.substring(htmlEnd + 1)}';
      }
    }

    // 3) 片段（没有 html/head）：整个包一层。浏览器会自己补 head，
    //    但我们要保证样式在最前面，所以显式给一个文档骨架。
    return '<!DOCTYPE html><html data-md3e="auto"><head>$injection</head>'
        '<body>$html</body></html>';
  }

  static String _buildHeadInjection(Map<String, dynamic> payload) {
    final String vars = _themeVariables(payload);
    final String css = Md3eStyles.css;
    return '<style id="lemonlite-md3e" data-lemonlite="md3e">'
        '$vars\n$css</style>\n'
        '<script id="lemonlite-md3e-dom">${Md3eStyles.buildDomScript()}</script>';
  }

  /// `:root { --md-primary: #...; }` —— 首帧就要用的颜色。
  static String _themeVariables(Map<String, dynamic> payload) {
    final Object? raw = payload['cssVariables'];
    final StringBuffer buffer = StringBuffer(':root{');
    if (raw is Map) {
      raw.forEach((Object? key, Object? value) {
        final String name = key.toString();
        if (!name.startsWith('--')) return;
        buffer.write('$name:${value.toString()};');
      });
    }
    buffer.write('}');
    return buffer.toString();
  }

  static String _themeHash(Map<String, dynamic> payload) {
    final Object? raw = payload['cssVariables'];
    if (raw is Map) return raw.toString();
    return payload['mode'].toString();
  }

  /// 清缓存（服务器地址变更 / 小程序更新后调用）。
  static void clearCache() => _cache.clear();
}

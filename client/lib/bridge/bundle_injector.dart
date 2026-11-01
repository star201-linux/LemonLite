// lib/bridge/bundle_injector.dart
//
// 把「模块 / 扩展」包的内容变成可以注入 WebView 的 JS。
//
// 注入位置与主题、SDK 一起排在 document-start / document-end 两个 UserScript 里：
//   主题数据 → JS SDK → 模块/扩展
// 放在 SDK 之后，是为了让扩展脚本一上来就能用 window.lemonlite.*。
//
// 几个刻意的取舍：
//   * 扩展的 JS 一律包进 IIFE —— 扩展作者不该能把变量漏到页面全局上互相污染
//   * 扩展的 JS/CSS 用「建 <script>/<style> 再插入」的方式执行，而不是拼进主脚本：
//     这样扩展代码自己抛错时，宿主框架仍然正常，错误落到 window.onerror 而不是崩掉注入
//   * 模块声明的桥接方法生成 `lemonlite.<name>()` 包装，脚本仍走同一条 callHandler 通道，
//     不额外开后门

import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/models/bundle_manifest.dart';
import '../data/repositories/bundle_repository.dart';

class BundleInjector {
  const BundleInjector._();

  /// 按注入时机分组：documentStart 的先走，documentEnd 的后走
  static Map<BundleRunAt, List<BundlePayload>> groupByRunAt(
    List<BundlePayload> payloads,
  ) {
    final Map<BundleRunAt, List<BundlePayload>> grouped =
        <BundleRunAt, List<BundlePayload>>{
          BundleRunAt.documentStart: <BundlePayload>[],
          BundleRunAt.documentEnd: <BundlePayload>[],
        };
    for (final BundlePayload payload in payloads) {
      grouped[payload.runAt]!.add(payload);
    }
    return grouped;
  }

  static UserScriptInjectionTime toInjectionTime(BundleRunAt runAt) =>
      runAt == BundleRunAt.documentStart
      ? UserScriptInjectionTime.AT_DOCUMENT_START
      : UserScriptInjectionTime.AT_DOCUMENT_END;

  /// 生成注入脚本。空列表返回空串（调用方据此跳过 UserScript）。
  static String buildScript(List<BundlePayload> payloads) {
    if (payloads.isEmpty) return '';

    final StringBuffer buffer = StringBuffer()
      ..writeln('/* LemonLite 模块 / 扩展注入 */')
      ..writeln('(function () {')
      ..writeln("  'use strict';")
      ..write(_preamble);

    for (final BundlePayload payload in payloads) {
      _writePayload(buffer, payload);
    }

    buffer.writeln('})();');
    return buffer.toString();
  }

  static void _writePayload(StringBuffer buffer, BundlePayload payload) {
    final BundleManifest manifest = payload.manifest;
    final String id = manifest.id;
    final String injectionId = payload.injectionKey ?? id;

    // 这里只有一条语句，用 `.` 而不是 `..` 免得 analyzer 提示多余级联
    buffer.writeln(
      '  // ===== ${manifest.type.label} ${manifest.name} v${manifest.version} =====',
    );

    if (payload.css.trim().isNotEmpty) {
      // 不同注入规则可能同时命中，分别命名以免互相覆盖。
      buffer
        ..writeln(
          "  __style('lemonlite-bundle-$injectionId-css', ${_jsString(payload.css)});",
        )
        ..writeln();
    }

    if (payload.js.trim().isNotEmpty) {
      // 包一层函数：作者写的顶层 const/let 不会漏到页面全局上互相污染
      final String wrapped = '(function () {\n${payload.js}\n})();';
      buffer
        ..writeln('  __script(${_jsString(wrapped)});')
        ..writeln();
    }

    if (manifest.bridgeMethods.isNotEmpty) {
      buffer.writeln('  // 模块声明的桥接方法：lemonlite.<name>(params)');
      for (final BundleBridgeMethod method in manifest.bridgeMethods) {
        buffer
          ..writeln(
            '  if (window.lemonlite && typeof window.lemonlite.__invoke === "function") {',
          )
          ..writeln(
            '    window.lemonlite[${_jsString(method.name)}] = function (params) {',
          )
          ..writeln(
            '      return window.lemonlite.__invoke(${_jsString(method.name)}, params || {});',
          )
          ..writeln('    };')
          ..writeln('  } else {')
          ..writeln(
            "    console.warn('[lemonlite 模块 $id] JS SDK 尚未就绪，${method.name} 未注册');",
          )
          ..writeln('  }');
      }
      buffer.writeln();
    }
  }

  /// 注入辅助函数。
  ///
  /// 为什么需要 `__inject`：runAt = documentStart 时页面往往还没解析出 `<head>`，
  /// 直接 appendChild 会抛错，连带整个扩展脚本都不执行。
  /// 这里统一兜底 —— 元素还没就绪就等 DOMContentLoaded。
  static const String _preamble = r'''
  function __inject(make) {
    function apply() {
      try {
        var target = document.head || document.documentElement;
        if (!target) { return; }
        target.appendChild(make());
      } catch (e) {
        console.warn('[lemonlite] 注入失败', e);
      }
    }
    if (document.head || document.documentElement) { apply(); }
    else { document.addEventListener('DOMContentLoaded', apply); }
  }

  function __style(id, css) {
    __inject(function () {
      var el = document.getElementById(id);
      if (!el) {
        el = document.createElement('style');
        el.id = id;
      }
      el.textContent = css;
      return el;
    });
  }

  function __script(src) {
    __inject(function () {
      var el = document.createElement('script');
      el.textContent = src;
      return el;
    });
  }
''';

  /// 页面里可以读的「当前生效了哪些包」，调试很方便
  static String buildRegistryScript(List<BundlePayload> payloads) {
    // 一个 Chrome 扩展可能有多条 content_scripts 规则；页面清单仍按扩展去重。
    final Map<String, List<BundlePayload>> grouped =
        <String, List<BundlePayload>>{};
    for (final BundlePayload payload in payloads) {
      grouped
          .putIfAbsent(payload.manifest.id, () => <BundlePayload>[])
          .add(payload);
    }
    final List<Map<String, dynamic>> list = <Map<String, dynamic>>[
      for (final List<BundlePayload> group in grouped.values)
        <String, dynamic>{
          'id': group.first.manifest.id,
          'name': group.first.manifest.name,
          'type': group.first.manifest.type.wireName,
          'version': group.first.manifest.version,
          'author': group.first.manifest.author,
          'hasCss': group.any(
            (BundlePayload item) => item.css.trim().isNotEmpty,
          ),
          'hasJs': group.any((BundlePayload item) => item.js.trim().isNotEmpty),
          'bridge': <String>[
            for (final BundleBridgeMethod m
                in group.first.manifest.bridgeMethods)
              m.name,
          ],
        },
    ];
    return 'window.__LEMONLITE_BUNDLES__ = ${jsonEncode(list)};';
  }

  /// 用 JSON 编码产出 JS 字符串字面量：换行、引号、反斜杠都会正确转义
  static String _jsString(String value) => jsonEncode(value);
}

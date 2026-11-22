
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
      ..writeln('/* LemonLite 模块注入 */')
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
    // 一个模块可能有多条 contentScripts 规则；页面清单仍按模块去重。
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

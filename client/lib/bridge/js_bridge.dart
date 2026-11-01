// lib/bridge/js_bridge.dart
//
// JavaScriptHandler 注册 + 统一错误包装。
//
// 这一层只做三件事，故意保持很薄：
//   1. 注册名为 `lemonlite` 的 handler（JS 侧 window.flutter_inappwebview.callHandler 的名字）
//   2. 解析 JS 传来的 `{ method, params }`
//   3. 把 BridgeApi 的返回值 / 异常统一包装成 `{ code, data }` / `{ code, message }`
//
// 注册示例：
//   JsBridge.attach(controller: controller, api: api);
//
// JS 侧调用示例（injected_js.dart 里已封装成 Promise，小程序直接这样写）：
//   const info = await lemonlite.getSystemInfo();
//   const theme = await lemonlite.getTheme();
//   await lemonlite.setTitle('我的小程序');
//   await lemonlite.showToast('保存成功');
//   await lemonlite.navigateBack();
//   await lemonlite.openUrl('https://flutter.dev');
//   const res = await lemonlite.request({ url: 'https://example.com/api', method: 'GET' });
//   await lemonlite.setStorage('k', { a: 1 });
//   const v = await lemonlite.getStorage('k', null);
//   await lemonlite.removeStorage('k');

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/globals.dart';
import 'bridge_api.dart';

class JsBridge {
  const JsBridge._();

  /// 必须是常量：JS 侧 `callHandler('lemonlite', ...)` 与它一一对应
  static const String handlerName = 'lemonlite';

  /// 把 BridgeApi 挂到 WebView 控制器上
  static void attach({
    required InAppWebViewController controller,
    required BridgeApi api,
  }) {
    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (List<dynamic> args) async {
        // ---- 1. 解析调用 ----
        final _BridgeCall call;
        try {
          call = _BridgeCall.parse(args);
        } on LemonBridgeException catch (e) {
          return _failure(e.code, e.message);
        }

        // ---- 2. 执行 + 3. 包装结果 ----
        try {
          final Object? data = await api.dispatch(call.method, call.params);
          return <String, dynamic>{'code': BridgeErrorCode.ok, 'data': data};
        } on LemonBridgeException catch (e) {
          // 业务层可预期的失败：只记一行日志，不打印堆栈
          lemonLog('Bridge', '${call.method} 失败：${e.code} ${e.message}');
          return _failure(e.code, e.message);
        } catch (e, stack) {
          // 未预料的异常也必须变成结构化错误回给 JS，绝不让 WebView 侧 Promise 永远 pending
          lemonLog('Bridge', '${call.method} 内部异常：$e\n$stack');
          return _failure(BridgeErrorCode.internal, '内部错误：$e');
        }
      },
    );
    lemonLog('Bridge', '已注册 JavaScriptHandler "$handlerName"');
  }

  static Map<String, dynamic> _failure(int code, String message) =>
      <String, dynamic>{'code': code, 'message': message};
}

/// 解析后的调用请求
class _BridgeCall {
  const _BridgeCall({required this.method, required this.params});

  final String method;
  final Map<String, dynamic> params;

  /// 兼容两种调用形态：
  ///   callHandler('lemonlite', { method: 'getTheme', params: {} })   ← SDK 使用这种
  ///   callHandler('lemonlite', 'getTheme', { })                     ← 手写页面更省事
  static _BridgeCall parse(List<dynamic> args) {
    if (args.isEmpty) {
      throw const LemonBridgeException(BridgeErrorCode.invalidArgument, '缺少调用参数');
    }

    final Object? first = args.first;

    if (first is String) {
      final Map<String, dynamic>? extra = args.length > 1 ? _asMap(args[1]) : null;
      return _BridgeCall(
        method: first,
        params: extra ?? const <String, dynamic>{},
      );
    }

    final Map<String, dynamic>? payload = _asMap(first);
    if (payload == null) {
      throw const LemonBridgeException(BridgeErrorCode.invalidArgument, '调用参数必须是对象');
    }

    final String method = payload['method']?.toString() ?? '';
    if (method.isEmpty) {
      throw const LemonBridgeException(BridgeErrorCode.invalidArgument, '缺少 method 字段');
    }

    return _BridgeCall(
      method: method,
      params: _asMap(payload['params']) ?? const <String, dynamic>{},
    );
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    }
    return null;
  }
}

// lib/core/nfc_bridge.dart
//
// NFC 原生能力的 Dart 侧封装。
//
// 为什么读卡是「一次调用等一张卡」而不是持续回调：
//   JSBridge 目前只有请求/响应，没有服务端推送；与其发一套事件通道，
//   不如让页面明确地说「我现在要读一张卡，最多等 N 秒」——这正是
//   Android Reader Mode 的模型，也不会出现「页面已经退出还在监听」的泄漏。
//   （蓝牙的 notify 用到了桌面/移动端通用的事件通道，见 injected_js.dart。）
//
// 跨平台：公共 API 只依赖 [NfcBackend]，Android 用 `lemonlite/nfc` 通道实现；
// 将来 iOS（CoreNFC）/ 桌面只要注册一个实现即可。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NfcException implements Exception {
  const NfcException(this.code, this.message);

  /// 原生 error code：unsupported / disabled / timeout / cancelled /
  /// not_writable / write_failed / busy / native_error …
  final String code;

  final String message;

  @override
  String toString() => 'NfcException($code): $message';
}

/// 平台后端接口。
abstract interface class NfcBackend {
  bool get isSupported;

  Future<Map<String, dynamic>> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]);
}

/// Android 实现：`lemonlite/nfc` 通道。
class MethodChannelNfcBackend implements NfcBackend {
  static const MethodChannel _channel = MethodChannel('lemonlite/nfc');

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<Map<String, dynamic>> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final Object? raw = await _channel.invokeMethod<Object?>(method, arguments);
    if (raw is Map) {
      return raw.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    }
    return <String, dynamic>{};
  }
}

/// 没有任何平台实现时的后端：明确不支持。
class UnsupportedNfcBackend implements NfcBackend {
  const UnsupportedNfcBackend();

  @override
  bool get isSupported => false;

  @override
  Future<Map<String, dynamic>> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    throw const NfcException('unsupported', '当前平台不支持 NFC');
  }
}

class NfcBridge {
  const NfcBridge._();

  static NfcBackend _backend = MethodChannelNfcBackend();

  static NfcBackend get backend => _backend;

  /// 注册一个平台实现（将来 iOS CoreNFC 等）。
  static void registerBackend(NfcBackend backend) => _backend = backend;

  static bool get isSupported => _backend.isSupported;

  /// 设备是否有 NFC、NFC 是否打开
  static Future<Map<String, dynamic>> status() async {
    if (!isSupported) {
      return <String, dynamic>{'supported': false, 'enabled': false};
    }
    return _invokeMap('status');
  }

  /// 等待用户贴一张 NFC 标签，返回标签信息（UID / 技术清单 / NDEF 记录）。
  ///
  /// [timeoutMs] 由原生侧计时；到点没贴卡就抛 [NfcException]（timeout）。
  static Future<Map<String, dynamic>> read({int timeoutMs = 15000}) async {
    if (!isSupported) {
      throw const NfcException('unsupported', '当前平台不支持 NFC');
    }
    return _invokeMap('read', <String, Object?>{
      'timeoutMs': timeoutMs.clamp(2000, 60000),
    });
  }

  /// 取消正在等待的读卡 / 写卡。
  static Future<void> cancel() async {
    if (!isSupported) return;
    try {
      await _backend.invoke('cancel');
    } on PlatformException {
      // 没有正在进行的操作：取消本来就是幂等的
    } on MissingPluginException {
      // 忽略
    }
  }

  /// 等待用户贴卡，并写入一条 NDEF Text 记录。
  static Future<Map<String, dynamic>> writeText({
    required String text,
    int timeoutMs = 15000,
    bool formatIfNeeded = true,
  }) async {
    if (!isSupported) {
      throw const NfcException('unsupported', '当前平台不支持 NFC');
    }
    return _invokeMap('writeText', <String, Object?>{
      'text': text,
      'timeoutMs': timeoutMs.clamp(2000, 60000),
      'formatIfNeeded': formatIfNeeded,
    });
  }

  static Future<Map<String, dynamic>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _backend.invoke(method, arguments);
    } on PlatformException catch (e) {
      throw NfcException(e.code, e.message ?? 'NFC 操作失败');
    } on MissingPluginException {
      throw const NfcException('unsupported', 'NFC 通道未注册（仅 Android 支持）');
    }
  }
}

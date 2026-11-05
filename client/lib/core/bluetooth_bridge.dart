// lib/core/bluetooth_bridge.dart
//
// 蓝牙（BLE）原生能力的 Dart 侧封装。
//
// 为什么单独一个文件而不是塞进 NativeBridge：
//   NativeBridge 管的是「窗口级、失败就静默降级」的能力（音量 / 亮度 / 方向）。
//   蓝牙的失败**必须告诉小程序**——「没开蓝牙」「没给权限」「连不上这个设备」
//   是三种完全不同的处理路径，静默返回 null 会让页面无从下手。
//   所以这里的方法失败时抛 [BluetoothException]，由桥接层转成结构化错误码。
//
// 跨平台怎么接（重要）：
//   公共 API（BluetoothBridge.xxx）只依赖 [BluetoothBackend] 这个窄接口。
//   Android 用 `lemonlite/bluetooth` 平台通道实现；将来 iOS / 桌面 / Web
//   只要实现同一个接口并在启动时 `BluetoothBridge.registerBackend(...)`，
//   桥接层、JS SDK、权限弹窗、页面都不需要改一行。
//   通道的方法名与事件名是一份跨平台契约（见 MethodChannelBluetoothBackend）。
//
// 能力范围：
//   * BLE：扫描（可带服务过滤 / 实时 scanResult 事件）、连接、GATT 服务、
//     特征值 read/write、notify/indicate 订阅、RSSI、MTU、连接状态事件；
//   * 经典蓝牙：扫描、配对（createBond）、配对状态事件；
//   * 请求打开蓝牙、当前连接列表。
//   经典蓝牙的 SPP 字节流没有适合网页的通用语义，所以只做发现与配对。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 蓝牙操作的预期失败（原生侧用 error code 区分）。
class BluetoothException implements Exception {
  const BluetoothException(this.code, this.message);

  /// 原生 error code：permission_denied / disabled / unsupported /
  /// timeout / not_connected / busy / bad_args / native_error …
  final String code;

  final String message;

  @override
  String toString() => 'BluetoothException($code): $message';
}

/// 平台后端接口。Android 现在是唯一的实现；未来平台新增一个实现即可。
abstract interface class BluetoothBackend {
  bool get isSupported;

  /// 调用一个平台方法；失败时抛 [PlatformException] / [MissingPluginException]。
  Future<Map<String, dynamic>> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]);

  /// 原生主动事件（notification / connectionState / scanResult / bondState）。
  Stream<Map<String, dynamic>> get events;
}

/// Android 实现：`lemonlite/bluetooth` 通道。
class MethodChannelBluetoothBackend implements BluetoothBackend {
  MethodChannelBluetoothBackend() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  /// 与 Kotlin 侧 `BluetoothBridge.CHANNEL_NAME` 逐字一致。
  static const MethodChannel _channel = MethodChannel('lemonlite/bluetooth');

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// 原生 → Dart 的主动事件。事件名固定为 `event`，参数是一个 Map：
  /// `{ type: 'notification'|'connectionState'|'scanResult'|'bondState', ... }`
  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'event') return;
    final Object? raw = call.arguments;
    if (raw is! Map) return;
    _events.add(
      raw.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      ),
    );
  }

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

/// 没有任何平台实现时使用的后端：明确「不支持」，而不是假装成功。
class UnsupportedBluetoothBackend implements BluetoothBackend {
  const UnsupportedBluetoothBackend();

  @override
  bool get isSupported => false;

  @override
  Stream<Map<String, dynamic>> get events =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<Map<String, dynamic>> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
  }
}

class BluetoothBridge {
  const BluetoothBridge._();

  /// 当前后端。测试 / 未来平台可以替换它，公共 API 不变。
  static BluetoothBackend _backend = MethodChannelBluetoothBackend();

  static BluetoothBackend get backend => _backend;

  /// 注册一个平台实现（例如将来 iOS 的 `IosBluetoothBackend()`）。
  static void registerBackend(BluetoothBackend backend) => _backend = backend;

  static bool get isSupported => _backend.isSupported;

  /// 原生主动事件流（只暴露给桥接层；小程序通过 JS 的 onXxx 订阅）。
  static Stream<Map<String, dynamic>> get events => _backend.events;

  /// 适配器是否可用 / 是否已打开 / 是否支持 BLE
  static Future<Map<String, dynamic>> status() async {
    if (!isSupported) {
      return <String, dynamic>{
        'supported': false,
        'enabled': false,
        'bleSupported': false,
        'permissionGranted': false,
      };
    }
    return _invokeMap('status');
  }

  /// 已配对（已绑定）的设备
  static Future<List<Map<String, dynamic>>> listPaired() async {
    if (!isSupported) return const <Map<String, dynamic>>[];
    final Map<String, dynamic> data = await _invokeMap('listPaired');
    return _deviceList(data);
  }

  /// 当前已连接的设备（只有本 App 建立的连接）
  static Future<List<Map<String, dynamic>>> connections() async {
    if (!isSupported) return const <Map<String, dynamic>>[];
    final Map<String, dynamic> data = await _invokeMap('connections');
    return _deviceList(data);
  }

  /// BLE / 经典蓝牙扫描。
  ///
  /// [mode]：`ble`（默认）/ `classic` / `auto`（两者同时，结果合并）。
  /// [serviceUuids] 只对 BLE 生效；[namePrefix] 在原生侧按名称过滤。
  /// 扫描过程中原生会持续发 `scanResult` 事件；返回值是最终去重后的列表。
  static Future<List<Map<String, dynamic>>> scan({
    int durationMs = 5000,
    String mode = 'ble',
    List<String> serviceUuids = const <String>[],
    String namePrefix = '',
  }) async {
    if (!isSupported) return const <Map<String, dynamic>>[];
    final Map<String, dynamic> data =
        await _invokeMap('scan', <String, Object?>{
          'durationMs': durationMs.clamp(1000, 20000),
          'mode': mode,
          'serviceUuids': serviceUuids,
          'namePrefix': namePrefix,
        });
    return _deviceList(data);
  }

  /// 请求系统打开蓝牙（会弹系统确认框；结果用 status() 轮询）。
  static Future<Map<String, dynamic>> requestEnable() async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    return _invokeMap('requestEnable');
  }

  /// 连接 BLE 设备，返回服务 / 特征值清单。
  static Future<Map<String, dynamic>> connect(String address) async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    return _invokeMap('connect', <String, Object?>{'address': address});
  }

  static Future<void> disconnect(String address) async {
    if (!isSupported) return;
    await _invokeMap('disconnect', <String, Object?>{'address': address});
  }

  /// 断开全部连接（清理用；小程序退出 / 页面切换时可以调）。
  static Future<void> disconnectAll() async {
    if (!isSupported) return;
    await _invokeMap('disconnectAll');
  }

  /// 读一个特征值，返回 base64 字符串（二进制不能直接过 JSON）。
  static Future<String> read({
    required String address,
    required String service,
    required String characteristic,
  }) async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    final Map<String, dynamic> data = await _invokeMap(
      'read',
      <String, Object?>{
        'address': address,
        'service': service,
        'characteristic': characteristic,
      },
    );
    return (data['value'] ?? '').toString();
  }

  /// 写特征值。[data] 是 base64。
  static Future<void> write({
    required String address,
    required String service,
    required String characteristic,
    required String data,
    bool withResponse = true,
  }) async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    await _invokeMap('write', <String, Object?>{
      'address': address,
      'service': service,
      'characteristic': characteristic,
      'data': data,
      'withResponse': withResponse,
    });
  }

  /// 订阅 / 取消订阅特征值通知（notify / indicate）。
  ///
  /// 订阅后原生会持续发 `notification` 事件；Dart 侧再转给 JS 的
  /// `lemonlite.bluetooth.onNotification(cb)`。
  static Future<void> subscribe({
    required String address,
    required String service,
    required String characteristic,
    bool enable = true,
  }) async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    await _invokeMap('subscribe', <String, Object?>{
      'address': address,
      'service': service,
      'characteristic': characteristic,
      'enable': enable,
    });
  }

  /// 读取当前连接信号强度（RSSI）。
  static Future<int> getRssi(String address) async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    final Map<String, dynamic> data = await _invokeMap(
      'getRssi',
      <String, Object?>{'address': address},
    );
    return (data['rssi'] as num?)?.toInt() ?? 0;
  }

  /// 请求更大的 MTU（Android 13+ 会尽量协商，返回实际值）。
  static Future<int> requestMtu(String address, int mtu) async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    final Map<String, dynamic> data = await _invokeMap(
      'requestMtu',
      <String, Object?>{'address': address, 'mtu': mtu.clamp(23, 517)},
    );
    return (data['mtu'] as num?)?.toInt() ?? 23;
  }

  /// 发起配对（经典蓝牙 / 双模设备）。结果通过 `bondState` 事件通知。
  static Future<Map<String, dynamic>> pair(String address) async {
    if (!isSupported) {
      throw const BluetoothException('unsupported', '当前平台不支持蓝牙');
    }
    return _invokeMap('pair', <String, Object?>{'address': address});
  }

  static List<Map<String, dynamic>> _deviceList(Map<String, dynamic> data) {
    final Object? raw = data['devices'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map(
          (Map m) => m.map<String, dynamic>(
            (Object? k, Object? v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
        )
        .toList(growable: false);
  }

  static Future<Map<String, dynamic>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _backend.invoke(method, arguments);
    } on PlatformException catch (e) {
      throw BluetoothException(e.code, e.message ?? '蓝牙操作失败');
    } on MissingPluginException {
      throw const BluetoothException('unsupported', '蓝牙通道未注册（仅 Android 支持）');
    }
  }
}

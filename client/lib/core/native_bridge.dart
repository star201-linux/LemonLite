
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'globals.dart';

/// 页面方向标记（小程序用 SDK 设置；auto = 跟随系统）
enum MiniappOrientation {
  portrait,
  landscape,
  portraitReverse,
  landscapeReverse,
  auto,
}

/// 音量快照
class VolumeInfo {
  const VolumeInfo({
    required this.level,
    required this.max,
    required this.percent,
  });

  final int level; // 当前档位
  final int max; // 最大档位
  final double percent; // level / max

  /// 从通道返回的 Map 组装；结构不符合约定时返回 null（调用方按「能力不可用」处理）。
  static VolumeInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final int level = _asInt(raw['level']);
    final int max = _asInt(raw['max']);
    final Object? rawPercent = raw['percent'];
    // percent 优先用原生算好的值；万一字段缺失（旧版本 / 自定义实现）就本地兜底再算一遍。
    final double percent = rawPercent is num
        ? rawPercent.toDouble()
        : (max > 0 ? level / max : 0.0);
    return VolumeInfo(level: level, max: max, percent: percent);
  }

  @override
  String toString() =>
      'VolumeInfo(level: $level, max: $max, percent: $percent)';
}

/// 亮度快照（0~1）
class BrightnessInfo {
  const BrightnessInfo({required this.window, required this.system});

  final double window; // 当前窗口亮度；-1 表示「跟随系统」
  final double system; // 系统亮度 0~1（只读，仅供参考）

  /// 从通道返回的 Map 组装；结构不符合约定时返回 null。
  static BrightnessInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    // window 缺字段时兜底成 -1（跟随系统）：比兜底成 0（全黑）安全得多。
    return BrightnessInfo(
      window: _asDouble(raw['window'], -1.0),
      system: _asDouble(raw['system']),
    );
  }

  @override
  String toString() => 'BrightnessInfo(window: $window, system: $system)';
}

/// 原生能力通道。
///
/// 通道名 `lemonlite/native` 与 Kotlin 侧 `MainActivity.CHANNEL_NAME` 必须逐字一致；
/// method 名同理（getVolume / setVolume / getBrightness / setBrightness /
/// setKeepScreenOn / setOrientation），改任何一端都要同步改另一端。
class NativeBridge {
  const NativeBridge._();

  static const MethodChannel channel = MethodChannel('lemonlite/native');

  /// 是否支持（只有 Android 走平台通道；其它平台一律 false，调用方要降级）
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 取媒体音量；失败或不支持返回 null
  static Future<VolumeInfo?> getVolume() async {
    if (!isSupported) return null;
    try {
      final Object? raw = await channel.invokeMethod<Object?>('getVolume');
      return VolumeInfo.fromMap(raw);
    } on PlatformException catch (e) {
      _logFailure('getVolume', e);
      return null;
    } on MissingPluginException catch (e) {
      _logFailure('getVolume', e);
      return null;
    } catch (e) {
      // 通道被打断、返回结构不符等意外情况：同样降级，绝不把异常抛给页面
      _logFailure('getVolume', e);
      return null;
    }
  }

  /// 设置媒体音量（percent 会 clamp 到 0~1）；成功返回设置后的快照
  static Future<VolumeInfo?> setVolume(double percent) async {
    if (!isSupported) return null;
    try {
      final Object? raw = await channel.invokeMethod<Object?>(
        'setVolume',
        <String, Object?>{'percent': _clampUnit(percent)},
      );
      return VolumeInfo.fromMap(raw);
    } on PlatformException catch (e) {
      _logFailure('setVolume', e);
      return null;
    } on MissingPluginException catch (e) {
      _logFailure('setVolume', e);
      return null;
    } catch (e) {
      _logFailure('setVolume', e);
      return null;
    }
  }

  /// 取亮度：window 为当前窗口亮度（-1 表示跟随系统），system 为系统亮度 0~1
  static Future<BrightnessInfo?> getBrightness() async {
    if (!isSupported) return null;
    try {
      final Object? raw = await channel.invokeMethod<Object?>('getBrightness');
      return BrightnessInfo.fromMap(raw);
    } on PlatformException catch (e) {
      _logFailure('getBrightness', e);
      return null;
    } on MissingPluginException catch (e) {
      _logFailure('getBrightness', e);
      return null;
    } catch (e) {
      _logFailure('getBrightness', e);
      return null;
    }
  }

  /// 设置窗口亮度：0~1；传 -1 恢复「跟随系统」
  static Future<bool> setBrightness(double value) async {
    if (!isSupported) return false;
    try {
      // 归一化：任何负数（含约定的 -1）都当成 -1 = 跟随系统；NaN 也归到跟随系统，
      // 因为窗口亮度是 float，NaN 会让当前窗口直接变黑且无法自愈。
      final double normalized = _normalizeBrightness(value);
      final bool? ok = await channel.invokeMethod<bool>(
        'setBrightness',
        <String, Object?>{'value': normalized},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('setBrightness', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('setBrightness', e);
      return false;
    } catch (e) {
      _logFailure('setBrightness', e);
      return false;
    }
  }

  /// 屏幕常亮（true = 不允许熄屏）
  static Future<bool> setKeepScreenOn(bool enabled) async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>(
        'setKeepScreenOn',
        <String, Object?>{'enabled': enabled},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('setKeepScreenOn', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('setKeepScreenOn', e);
      return false;
    } catch (e) {
      _logFailure('setKeepScreenOn', e);
      return false;
    }
  }

  /// 设置 Activity 方向；auto = 恢复跟随系统
  static Future<bool> setOrientation(MiniappOrientation orientation) async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>(
        'setOrientation',
        <String, Object?>{'value': _orientationValue(orientation)},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('setOrientation', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('setOrientation', e);
      return false;
    } catch (e) {
      _logFailure('setOrientation', e);
      return false;
    }
  }

  static Future<bool> setTaskDescription({
    required String label,
    String? iconPath,
  }) async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>(
        'setTaskDescription',
        <String, Object?>{'label': label, 'iconPath': iconPath},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('setTaskDescription', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('setTaskDescription', e);
      return false;
    } catch (e) {
      _logFailure('setTaskDescription', e);
      return false;
    }
  }

  /// 把「最近任务」卡片恢复成宿主自己的名字和图标。
  ///
  /// 调用时机：小程序转后台 / 关闭 / 全部退出 —— 那一刻屏幕上确实是轻柠，
  /// 卡片上还挂着小程序名字会让人以为小程序还在前台。
  static Future<bool> resetTaskDescription() async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>('resetTaskDescription');
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('resetTaskDescription', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('resetTaskDescription', e);
      return false;
    } catch (e) {
      _logFailure('resetTaskDescription', e);
      return false;
    }
  }

  static Future<bool> openMiniappWindow({
    required String appId,
    required String title,
    String? iconPath,
  }) async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>(
        'openMiniappWindow',
        <String, Object?>{
          'appId': appId,
          'title': title,
          'iconPath': iconPath,
        },
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('openMiniappWindow', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('openMiniappWindow', e);
      return false;
    } catch (e) {
      _logFailure('openMiniappWindow', e);
      return false;
    }
  }

  /// 结束当前这条任务（只在小程序窗口里有效）。
  ///
  /// 在宿主里调用会返回 false 而**不会**关掉 App —— 那条判断在原生侧，
  /// 因为「我是不是一个窗口」只有 Activity 自己知道。
  static Future<bool> finishTask() async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>('finishTask');
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('finishTask', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('finishTask', e);
      return false;
    } catch (e) {
      _logFailure('finishTask', e);
      return false;
    }
  }

  static Future<bool> requestRuntimePermissions(
    List<String> permissions,
  ) async {
    if (permissions.isEmpty) return true;
    if (!isSupported) return true;
    try {
      final bool? granted = await channel.invokeMethod<bool>(
        'requestRuntimePermissions',
        <String, Object?>{'permissions': permissions},
      );
      return granted ?? false;
    } on PlatformException catch (e) {
      _logFailure('requestRuntimePermissions', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('requestRuntimePermissions', e);
      return false;
    } catch (e) {
      _logFailure('requestRuntimePermissions', e);
      return false;
    }
  }

  static Future<bool> openAppSettings() async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>('openAppSettings');
      return ok ?? false;
    } on PlatformException catch (e) {
      _logFailure('openAppSettings', e);
      return false;
    } on MissingPluginException catch (e) {
      _logFailure('openAppSettings', e);
      return false;
    } catch (e) {
      _logFailure('openAppSettings', e);
      return false;
    }
  }
}

/// 枚举 → 通道字符串。
///
/// 刻意不发枚举下标（index）：下标会随枚举顺序变动而错位，字符串字面量是两端唯一的契约。
/// Kotlin 侧只认这几个值，不认识的值一律按 auto 处理。
String _orientationValue(MiniappOrientation orientation) =>
    switch (orientation) {
      MiniappOrientation.portrait => 'portrait',
      MiniappOrientation.landscape => 'landscape',
      MiniappOrientation.portraitReverse => 'portraitReverse',
      MiniappOrientation.landscapeReverse => 'landscapeReverse',
      MiniappOrientation.auto => 'auto',
    };

/// 把 0~1 的百分比规整到合法区间；NaN 视为 0（传 NaN 给原生只会得到更糟的结果）。
double _clampUnit(double value) {
  if (value.isNaN) return 0.0;
  return value.clamp(0.0, 1.0).toDouble();
}

/// 亮度归一化：负数（含 -1）= 跟随系统；NaN 也按跟随系统处理。
double _normalizeBrightness(double value) {
  if (value.isNaN || value < 0) return -1.0;
  return value.clamp(0.0, 1.0).toDouble();
}

/// 容错读 int：通道返回的类型不是 num 时用兜底值，避免一个字段的类型问题把整次调用炸掉。
int _asInt(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

/// 容错读 double。
double _asDouble(Object? value, [double fallback = 0]) =>
    value is num ? value.toDouble() : fallback;

/// 通道异常统一降级日志：只记一行、不抛出，调用方按「能力不可用」处理。
void _logFailure(String method, Object error) {
  if (error is PlatformException) {
    lemonLog('Native', '$method 失败：${error.code} ${error.message}');
  } else if (error is MissingPluginException) {
    lemonLog('Native', '$method 失败：通道未注册（${error.message}）');
  } else {
    lemonLog('Native', '$method 失败：$error');
  }
}

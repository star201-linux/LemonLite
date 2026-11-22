
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../data/models/miniapp_permission.dart';

/// 一次网页权限请求翻译成框架权限的结果。
///
/// 之所以要这个中间结构：一次 `onPermissionRequest` 可能同时请求多个资源
/// （`getUserMedia({video:true, audio:true})` 就是 CAMERA + MICROPHONE），
/// 而我们的模型是「一项权限一次询问」。所以先翻译、再逐项问、
/// 最后把允许的那些资源合并成一个 `PermissionResponse` 回给 Chromium。
class WebPermissionAsk {
  const WebPermissionAsk({required this.resources, required this.permissions});

  /// Chromium 请求的原始资源（回 PermissionResponse 时要原样带上允许的那些）
  final List<PermissionResourceType> resources;

  /// 翻译出来的框架权限，顺序与 [MiniappPermission.values] 一致（稳定）
  final List<MiniappPermission> permissions;

  bool get isUnmanaged => permissions.isEmpty;

  /// 从 Chromium 的资源列表翻译。
  ///
  /// 映射规则（Web 语义 → 框架权限）：
  ///   CAMERA                        → camera
  ///   MICROPHONE                    → microphone
  ///   CAMERA_AND_MICROPHONE         → camera + microphone（两个都问）
  ///   FILE_READ_WRITE               → sdcard
  ///   CLIPBOARD_READ                → clipboard
  ///   NOTIFICATIONS                 → notifications
  ///   MIDI_SYSEX                    → midi（Web MIDI 的系统专用消息）
  ///   OTHER_SENSORS                 → accelerometer + gyroscope
  ///   LOCAL_FONTS                   → localFonts
  ///
  /// **GEOLOCATION 刻意不在这里**：Android WebView 的 onPermissionRequest
  /// 根本不回调定位请求 —— 定位走的是 WebChromeClient 上另一个回调
  /// `onGeolocationPermissionsShowPrompt`，而且定位的精度/后台是两个
  /// 独立维度（见 LocationGrant）。所以定位的拦截在 miniapp_page.dart
  /// 的那个回调里。把 GEOLOCATION 写进这张表只会让人以为它在这儿被拦了。
  ///
  /// 其余资源（AUTOPLAY / PROTECTED_MEDIA_ID / WINDOW_MANAGEMENT …）
  /// 不纳入权限模型：与小程序场景无关。返回空列表表示「不认识」，由调用方放行。
  static WebPermissionAsk from(PermissionRequest request) {
    final List<PermissionResourceType> resources = request.resources;
    final Set<MiniappPermission> wanted = <MiniappPermission>{};

    for (final PermissionResourceType resource in resources) {
      if (resource == PermissionResourceType.CAMERA) {
        wanted.add(MiniappPermission.camera);
      } else if (resource == PermissionResourceType.MICROPHONE) {
        wanted.add(MiniappPermission.microphone);
      } else if (resource == PermissionResourceType.CAMERA_AND_MICROPHONE) {
        wanted.add(MiniappPermission.camera);
        wanted.add(MiniappPermission.microphone);
      } else if (resource == PermissionResourceType.FILE_READ_WRITE) {
        wanted.add(MiniappPermission.sdcard);
      } else if (resource == PermissionResourceType.CLIPBOARD_READ) {
        wanted.add(MiniappPermission.clipboard);
      } else if (resource == PermissionResourceType.NOTIFICATIONS) {
        wanted.add(MiniappPermission.notifications);
      } else if (resource == PermissionResourceType.MIDI_SYSEX) {
        wanted.add(MiniappPermission.midi);
      } else if (resource == PermissionResourceType.OTHER_SENSORS) {
        // devicemotion 同时涵盖加速度与转动，两类传感器一起问
        wanted.add(MiniappPermission.accelerometer);
        wanted.add(MiniappPermission.gyroscope);
      }
    }

    // 按枚举顺序输出，保证弹窗与日志里的顺序稳定
    final List<MiniappPermission> ordered = MiniappPermission.values
        .where(wanted.contains)
        .toList(growable: false);

    return WebPermissionAsk(resources: resources, permissions: ordered);
  }

  static PermissionResponse response({
    required WebPermissionAsk ask,
    required Set<MiniappPermission> granted,
  }) {
    if (granted.isEmpty) {
      return PermissionResponse(action: PermissionResponseAction.DENY);
    }
    final List<PermissionResourceType> allowed = <PermissionResourceType>[];
    for (final PermissionResourceType resource in ask.resources) {
      final Set<MiniappPermission> needs = _needsOf(resource);
      if (needs.isEmpty) {
        allowed.add(resource);
        continue;
      }
      if (needs.every(granted.contains)) allowed.add(resource);
    }
    if (allowed.isEmpty) {
      return PermissionResponse(action: PermissionResponseAction.DENY);
    }
    return PermissionResponse(
      action: PermissionResponseAction.GRANT,
      resources: allowed,
    );
  }

  /// 某个原始资源需要哪些框架权限。
  static Set<MiniappPermission> _needsOf(PermissionResourceType resource) {
    if (resource == PermissionResourceType.CAMERA) {
      return <MiniappPermission>{MiniappPermission.camera};
    }
    if (resource == PermissionResourceType.MICROPHONE) {
      return <MiniappPermission>{MiniappPermission.microphone};
    }
    if (resource == PermissionResourceType.CAMERA_AND_MICROPHONE) {
      return <MiniappPermission>{
        MiniappPermission.camera,
        MiniappPermission.microphone,
      };
    }
    if (resource == PermissionResourceType.FILE_READ_WRITE) {
      return <MiniappPermission>{MiniappPermission.sdcard};
    }
    if (resource == PermissionResourceType.CLIPBOARD_READ) {
      return <MiniappPermission>{MiniappPermission.clipboard};
    }
    if (resource == PermissionResourceType.NOTIFICATIONS) {
      return <MiniappPermission>{MiniappPermission.notifications};
    }
    if (resource == PermissionResourceType.MIDI_SYSEX) {
      return <MiniappPermission>{MiniappPermission.midi};
    }
    if (resource == PermissionResourceType.OTHER_SENSORS) {
      return <MiniappPermission>{
        MiniappPermission.accelerometer,
        MiniappPermission.gyroscope,
      };
    }
    if (resource == PermissionResourceType.GEOLOCATION) {
      return <MiniappPermission>{MiniappPermission.location};
    }
    return <MiniappPermission>{};
  }
}

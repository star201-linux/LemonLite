// lib/bridge/web_permission.dart
//
// WebView 权限拦截：把网页（小程序）发起的**浏览器权限请求**接到本框架的权限模型上。
//
// 为什么是这个方向，而不是自己实现摄像头/麦克风：
//   小程序就是 WebView 里的网页，网页要拿摄像头只会走 `navigator.mediaDevices
//   .getUserMedia()`。这条路径由 Chromium 自己实现（采集、编码、生命周期、
//   与页面 video 元素的对接），宿主**一行原生采集代码都不需要写**。
//   宿主真正该做的只有一件事：在 Chromium 弹出它的默认授权框之前把它拦住，
//   换成我们自己的权限模型 —— 也就是这个文件。
//
//   flutter_inappwebview 的 `onPermissionRequest` 正是这个拦截点：
//   它对应 Android 的 `WebChromeClient.onPermissionRequest`，
//   网页请求的资源以 `PermissionResourceType` 列表给出，我们回一个
//   `PermissionResponse`（ALLOW / DENY）即可。Chromium 拿到 ALLOW 之后
//   才会真正去开摄像头。
//
// 由此产生的一条**重要结论**：应用内授权（这里的 PermissionResponse）与
//   Android 运行时权限（CAMERA / RECORD_AUDIO）是两层，缺一不可。
//   Chromium 自己会去申请系统权限；系统没给，它最终仍会失败。
//   所以「手机存储」那种系统侧还有一层授权的权限，在这里放行之后
//   依然可能失败 —— 弹窗里必须把这件事说清楚（见 permission_prompt.dart）。

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

  /// 没有任何一项能映射到框架权限 —— 例如 AUTOPLAY、GEOLOCATION 这些
  /// 我们目前不管理的资源。调用方应当**直接放行**，让 Chromium 用它的默认行为，
  /// 而不是因为我们不认识就把页面功能掐掉。
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
        // File System Access API：网页请求读写用户选中的文件/目录。
        // 在小程序语境里这就是「读手机存储（sdcard）」。
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

  /// 构造放行/拒绝的响应。
  ///
  /// [granted] 是**已经拿到用户同意**的框架权限集合；
  /// 只有对应资源被同意时才放进 resources —— Chromium 会按这个列表
  /// 逐项决定给不给页面，混进去一个没同意的就等于偷偷放行。
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
        // 我们不管理的资源：既然整体已经决定放行，就原样带上，
        // 否则会把 AUTOPLAY 这类无关能力一起掐掉。
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

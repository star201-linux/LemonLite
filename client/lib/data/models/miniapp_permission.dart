// lib/data/models/miniapp_permission.dart
//
// 框架级「权限」定义。
//
// 这一版把「权限」收窄成**浏览器的受控资源**：摄像头、麦克风、文件系统访问。
//
// 为什么是这三个而不是别的：小程序就是 WebView 里的网页，它能拿到的受控资源
// 由 Chromium 决定，网页请求它们的唯一途径是标准 Web API
// （`getUserMedia()`、File System Access API…）。宿主该做的是在 Chromium
// 弹出默认授权框之前把它拦下来，换成自己的权限模型 —— 拦截点见
// bridge/web_permission.dart，采集本身完全交给 Chromium，
// 宿主不写任何原生采集代码。
//
// 之前那份清单把音量、亮度、屏幕方向、后台运行也当成权限来管，那是不对的：
// Android 本来就不禁止应用调整音量与亮度，把它们摆在权限管理器里只会让用户
// 面对一堆「点了也没有实际意义」的开关，真正的风险项反而被淹没。
// 这些能力现在一律直接放行。
//
// 权限管理器管的三项都必须由用户本人点头：
//   * camera / microphone —— 采集用户的影像与声音
//   * allFiles            —— 网页请求读写用户选中的文件/目录
//
// 这份清单同时就是权限管理器与「应用管理」里权限页的真相来源：
// 展示的条目、风险分级、分组全部由它推导。以后要纳入新的浏览器资源，
// 在这里加一个枚举值、并在 web_permission.dart 的映射表里接上即可。

import 'package:flutter/material.dart';

/// 权限风险等级。只用于 UI 分级展示，不参与授权判定。
enum PermissionRisk {
  normal('常规', '影响面小，一般不需要特别关注'),
  sensitive('敏感', '会访问用户的隐私数据'),
  dangerous('高风险', '能读写沙箱之外的文件，会产生持久副作用');

  const PermissionRisk(this.label, this.description);

  final String label;
  final String description;
}

/// 权限分组（管理器里的分节标题）
enum PermissionGroup {
  media('媒体采集'),
  location('位置'),
  storage('文件访问');

  const PermissionGroup(this.label);

  final String label;
}

/// 用户对某个权限的决定。
///
/// 三态而不是布尔：
///   * [ask]     —— 还没问过用户。默认就是这个状态，于是受控权限
///                  第一次被调用时都必须弹窗，宿主绝不替用户做主；
///   * [granted] —— 用户点了「允许」且勾掉了「仅本次生效」；
///   * [denied]  —— 用户点了「拒绝」且勾掉了「仅本次生效」。
///
/// 「仅本次生效」（默认勾选）不写进这里 —— 它压根不落盘，
/// 于是下一次调用时状态仍然是 [ask]，会重新问一遍。
enum PermissionDecision {
  ask('询问', '下次调用时弹窗询问'),
  granted('允许', '已经允许，不再询问'),
  denied('拒绝', '已经拒绝，网页请求会被浏览器拦下');

  const PermissionDecision(this.label, this.description);

  final String label;
  final String description;

  /// 持久化用的稳定字符串（**不要改**：改了等于把用户已有的决定丢掉）
  String get id => switch (this) {
    PermissionDecision.ask => 'ask',
    PermissionDecision.granted => 'granted',
    PermissionDecision.denied => 'denied',
  };

  static PermissionDecision? byId(String id) {
    for (final PermissionDecision d in values) {
      if (d.id == id) return d;
    }
    return null;
  }
}

/// 一次授权询问的答案。
///
/// [remember] 就是弹窗里那个**默认勾选**的「仅本次生效」的反面：
///   * remember == true  → 用户把复选框取消了，决定落盘，之后不再问；
///   * remember == false → 默认状态，只对这一次调用有效，下次照问。
///
/// 之所以把「仅本次」做成默认：权限弹窗最容易被用户当成一个必须点掉的拦路虎，
/// 手一快就点了「允许」，而这个决定会一直生效。默认不记住，
/// 就把「长期授权」变成一次需要用户主动取消勾选的、有意识的选择。
@immutable
class PermissionAnswer {
  const PermissionAnswer({required this.allowed, this.remember = false});

  /// 是否允许
  final bool allowed;

  /// 是否把这次决定记住（false = 仅本次生效）
  final bool remember;

  /// 只允许这一次
  static const PermissionAnswer allowOnce =
      PermissionAnswer(allowed: true, remember: false);

  /// 只拒绝这一次
  static const PermissionAnswer denyOnce =
      PermissionAnswer(allowed: false, remember: false);

  /// 允许并记住
  static const PermissionAnswer allowAlways =
      PermissionAnswer(allowed: true, remember: true);

  /// 拒绝并记住
  static const PermissionAnswer denyAlways =
      PermissionAnswer(allowed: false, remember: true);

  @override
  bool operator ==(Object other) =>
      other is PermissionAnswer &&
      other.allowed == allowed &&
      other.remember == remember;

  @override
  int get hashCode => Object.hash(allowed, remember);

  @override
  String toString() =>
      'PermissionAnswer(${allowed ? "allow" : "deny"}, '
      '${remember ? "remember" : "once"})';
}

/// 桥接层眼里的"要权限"动作：给定小程序与权限，返回用户的答案。
///
/// 放在模型层是有意的：桥接层只依赖这个签名，不认识 `showDialog` 也不 import
/// 任何页面，于是弹窗实现可以换（真实弹窗 / 自检模式下的自动回答 / 测试里的假实现），
/// 桥接层一行都不用改。
typedef PermissionPrompter = Future<PermissionAnswer> Function(
  String appId,
  MiniappPermission permission, {
  String? appName,
});

/// 一个受控权限。命名与 Android 的运行时权限一一对应（注释里标了对应的系统权限）。
enum MiniappPermission {
  camera(
    id: 'camera',
    label: '摄像头',
    description: '网页通过 navigator.mediaDevices.getUserMedia() 请求摄像头画面。'
        '同意后浏览器才会打开设备；底层还需要 Android 的 CAMERA 权限。',
    group: PermissionGroup.media,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>['android.permission.CAMERA'],
  ),
  microphone(
    id: 'microphone',
    label: '麦克风',
    description: '网页通过 navigator.mediaDevices.getUserMedia() 请求麦克风录音。'
        '同意后浏览器才会打开设备；底层还需要 Android 的 RECORD_AUDIO 权限。',
    group: PermissionGroup.media,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>['android.permission.RECORD_AUDIO'],
  ),
  /// 精确位置（细粒度）—— 对应 W3C Geolocation 的「精确」档。
  ///
  /// 为什么和模糊定位拆成两项而不是一个开关：
  ///   Android 12+ 把定位权限拆成了 FINE / COARSE 两档，系统授权框也让用户
  ///   二选一（「精确」/「大致」）。宿主如果只做一个「定位」开关，就等于替
  ///   用户决定了精度 —— 这正好是这次要避免的事。
  ///   拆开后：用户同意「大致」时我们只申请 COARSE，网页拿到的坐标会被
  ///   Android 自己模糊到街区级；同意「精确」才申请 FINE。
  geolocationFine(
    id: 'geolocationFine',
    label: '精确位置',
    description: '网页通过 navigator.geolocation 获取你的精确坐标（米级）。'
        '只在需要导航、附近搜索这类场景才该给；底层需要 ACCESS_FINE_LOCATION。',
    group: PermissionGroup.location,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>['android.permission.ACCESS_FINE_LOCATION'],
  ),

  /// 模糊位置（城市/街区级）。
  ///
  /// 注意 Android 的规则：**申请 FINE 时系统会同时要求 COARSE**，
  /// 只申请 COARSE 才是「我只要大致位置」。所以这里的 runtimePermissions
  /// 只有 COARSE —— 语义上它就是「我不要精确位置」。
  geolocationCoarse(
    id: 'geolocationCoarse',
    label: '大致位置',
    description: '网页通过 navigator.geolocation 获取你的大致位置（城市/街区级）。'
        '不需要精确坐标的场景选这个就够；底层只需 ACCESS_COARSE_LOCATION。',
    group: PermissionGroup.location,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>['android.permission.ACCESS_COARSE_LOCATION'],
  ),

  clipboard(
    id: 'clipboard',
    label: '剪贴板',
    description: '网页通过 navigator.clipboard 读写剪贴板。'
        '读剪贴板可能拿到你刚复制的密码、验证码，所以列为敏感项。',
    group: PermissionGroup.storage,
    risk: PermissionRisk.sensitive,
    // 现代 Chromium 的异步剪贴板不需要 Android 运行时权限（写入除外，
    // 但 WebView 里写入本来就不弹系统框）。读操作由 WebView 侧
    // 的 onPermissionRequest 拦。
    runtimePermissions: <String>[],
  ),

  notifications(
    id: 'notifications',
    label: '通知',
    description: '网页通过 Notification.requestPermission() 请求发送通知。'
        'Android 13+ 还需要 POST_NOTIFICATIONS 运行时权限。',
    group: PermissionGroup.media,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>['android.permission.POST_NOTIFICATIONS'],
  ),

  allFiles(
    id: 'allFiles',
    label: '管理所有文件',
    description: '网页通过 File System Access API 请求读写你选中的文件或目录。'
        '它越过小程序沙箱，因此单独列为高风险项。'
        '是否放行由你在这里与浏览器弹窗中决定。',
    group: PermissionGroup.storage,
    risk: PermissionRisk.dangerous,
    // File System Access API 由 Chromium 自己弹文件选择器，
    // 不需要 MANAGE_EXTERNAL_STORAGE 这类系统级授权。
    runtimePermissions: <String>[],
  );

  const MiniappPermission({
    required this.id,
    required this.label,
    required this.description,
    required this.group,
    required this.risk,
    required this.runtimePermissions,
  });

  /// 持久化用的稳定标识（**不要改**：改了等于把用户已有的授权全部丢掉）
  final String id;

  final String label;
  final String description;
  final PermissionGroup group;
  final PermissionRisk risk;

  /// 这一项在 Android 侧还需要哪些**运行时权限**。
  ///
  /// 这是「两层授权」里的第二层，绕不过去：
  ///   1. 应用内授权 —— 用户在权限弹窗里点「允许」（本文件的模型）；
  ///   2. 系统运行时权限 —— Chromium 打开采集设备前，Android 自己还会拦一道。
  ///
  /// **关键点**：WebView 的 `onPermissionRequest` 只告诉宿主「网页想要摄像头」，
  /// 它**不会**替宿主去申请 Android 运行时权限。所以宿主在放行之前必须先
  /// 把这一层拿到（见 NativeBridge.requestRuntimePermissions），
  /// 否则会出现「用户在弹窗里点了允许，摄像头却仍然打不开且没有报错」。
  ///
  /// 为空表示不需要系统层授权（例如 File System Access API 由 Chromium
  /// 自己弹文件选择器）。
  final List<String> runtimePermissions;

  /// 是否需要 Android 运行时权限
  bool get needsRuntimePermission => runtimePermissions.isNotEmpty;

  /// 用户还没做过决定时的状态 —— 一律是「询问」。
  ///
  /// 刻意没有"这个能力比较无害所以默认放行"的分支：哪些权限算无害，
  /// 是宿主单方面的判断，用户没理由信任它。
  PermissionDecision get defaultDecision => PermissionDecision.ask;

  /// 是否算敏感权限（风险等级高于「常规」）
  bool get isSensitive => risk != PermissionRisk.normal;

  /// 用户拒绝过系统运行时权限后，是否只能去系统设置里改回来。
  ///
  /// Android 的运行时权限一旦被「拒绝且不再询问」，应用就再也弹不出系统框了，
  /// 唯一出路是跳系统设置。所以这一项用来决定要不要给用户一个跳转入口。
  bool get needsSystemSettings => needsRuntimePermission;

  IconData get icon => switch (this) {
    MiniappPermission.camera => Icons.photo_camera_outlined,
    MiniappPermission.microphone => Icons.mic_none_outlined,
    MiniappPermission.geolocationFine => Icons.my_location,
    MiniappPermission.geolocationCoarse => Icons.location_searching,
    MiniappPermission.clipboard => Icons.content_paste,
    MiniappPermission.notifications => Icons.notifications_outlined,
    MiniappPermission.allFiles => Icons.folder_shared_outlined,
  };

  /// 精确/模糊定位是一对：用户选了其中一个，另一个的状态就不该再问。
  ///
  /// 为什么需要这条关系：Android 的 FINE 隐含 COARSE（申请 FINE 会让系统
  /// 同时给 COARSE）。如果两项各自独立判定，用户同意「精确」之后
  /// 网页再请求「大致」还会被问一次 —— 那是在问一个已经被回答过的问题。
  MiniappPermission? get pairedWith => switch (this) {
    MiniappPermission.geolocationFine => MiniappPermission.geolocationCoarse,
    MiniappPermission.geolocationCoarse => MiniappPermission.geolocationFine,
    _ => null,
  };

  /// 按分组聚合（管理器里按分节渲染）
  static Map<PermissionGroup, List<MiniappPermission>> grouped() {
    final Map<PermissionGroup, List<MiniappPermission>> result =
        <PermissionGroup, List<MiniappPermission>>{};
    for (final PermissionGroup group in PermissionGroup.values) {
      final List<MiniappPermission> items = values
          .where((MiniappPermission p) => p.group == group)
          .toList(growable: false);
      if (items.isNotEmpty) result[group] = items;
    }
    return result;
  }

  /// 全部敏感权限
  static List<MiniappPermission> get sensitiveList =>
      values.where((MiniappPermission p) => p.isSensitive).toList(growable: false);

  /// 从持久化的 id 反查；未知 id 返回 null（旧版本写入的权限被删掉时不至于崩）
  static MiniappPermission? byId(String id) {
    for (final MiniappPermission p in values) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 曾经是权限、但这一版**已经不再需要授权**的能力 id。
  ///
  /// 保留这份清单是为了把两种情况分开：
  ///   * `network` 这类 → 老数据里写着很正常，只是它现在不需要授权了，
  ///     不该在市场数据上打一个"写错了"的警告；
  ///   * 真正拼错的 id（例如 `camra`）→ 那才需要提醒维护者。
  ///
  /// 这些能力现在由桥接层直接放行，所以「不再需要授权」不等于「不能用了」。
  static const Set<String> retiredIds = <String>{
    'network',
    'storage',
    'file',
    'volume',
    'brightness',
    'screenOrientation',
    'keepScreenOn',
    'background',
    'openUrl',
    'wasm',
  };

  /// 判断一个声明里的 id 是不是「已退役」的旧权限
  static bool isRetired(String id) => retiredIds.contains(id);
}


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
  media('媒体与显示'),
  location('位置'),
  sensors('传感器'),
  input('输入与振动'),
  connectivity('连接与近场'),
  identity('身份与安全'),
  storage('文件与剪贴板'),
  system('系统与设备');

  const PermissionGroup(this.label);

  final String label;
}

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

/// 定位精度档位（对应 Android 的 FINE / COARSE）。
enum LocationPrecision {
  fine('fine', '精确', '米级坐标，可用于导航、附近搜索'),
  coarse('coarse', '近似', '模糊到约 3 平方公里，只能判断大致片区');

  const LocationPrecision(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static LocationPrecision? byId(String? id) {
    for (final LocationPrecision p in values) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 近似位置向下取整的经纬度网格（度）。
  ///
  /// 0.02° 在纬度上约 2.2 km，3 km² 量级的模糊效果与 Android 的
  /// 「大致位置」一致；精确位置不做任何取整。
  double get gridDegrees => this == LocationPrecision.coarse ? 0.02 : 0.0;

  /// 近似位置向页面报告的精度（米）。Android 的近似位置大约在公里级。
  double get reportedAccuracy => this == LocationPrecision.coarse ? 1500 : 0;
}

@immutable
class LocationGrant {
  const LocationGrant({
    required this.decision,
    required this.precision,
    required this.background,
  });

  final PermissionDecision decision;
  final LocationPrecision precision;

  /// 是否允许在小程序切到后台后继续获取位置
  final bool background;

  static const LocationGrant initial = LocationGrant(
    decision: PermissionDecision.ask,
    precision: LocationPrecision.fine,
    background: false,
  );

  bool get granted => decision == PermissionDecision.granted;

  /// 当前这次读取位置是否放行。[foreground] 表示小程序此刻是否在前台。
  bool allows({required bool foreground}) => granted && (foreground || background);

  String get state => switch (decision) {
    PermissionDecision.granted => 'granted',
    PermissionDecision.denied => 'denied',
    PermissionDecision.ask => 'ask',
  };

  Map<String, dynamic> toJs({required bool foreground}) => <String, dynamic>{
    'allowed': granted,
    'state': state,
    'precision': precision.id,
    'background': background,
    'foreground': foreground,
    // 页面侧按这个网格取整；精确位置是 0，即不取整。
    'grid': precision.gridDegrees,
    'accuracy': precision.reportedAccuracy,
  };

  LocationGrant copyWith({
    PermissionDecision? decision,
    LocationPrecision? precision,
    bool? background,
  }) => LocationGrant(
    decision: decision ?? this.decision,
    precision: precision ?? this.precision,
    background: background ?? this.background,
  );

  @override
  bool operator ==(Object other) =>
      other is LocationGrant &&
      other.decision == decision &&
      other.precision == precision &&
      other.background == background;

  @override
  int get hashCode => Object.hash(decision, precision, background);
}

@immutable
class PermissionAnswer {
  const PermissionAnswer({
    required this.allowed,
    this.remember = false,
    this.precision,
    this.background,
  });

  /// 是否允许
  final bool allowed;

  /// 是否把这次决定记住（false = 仅本次生效）
  final bool remember;

  /// 本次选择的定位精度（非定位权限为 null）
  final LocationPrecision? precision;

  /// 本次是否允许后台定位（非定位权限为 null）
  final bool? background;

  /// 只允许这一次
  static const PermissionAnswer allowOnce = PermissionAnswer(
    allowed: true,
    remember: false,
  );

  /// 只拒绝这一次
  static const PermissionAnswer denyOnce = PermissionAnswer(
    allowed: false,
    remember: false,
  );

  /// 允许并记住
  static const PermissionAnswer allowAlways = PermissionAnswer(
    allowed: true,
    remember: true,
  );

  /// 拒绝并记住
  static const PermissionAnswer denyAlways = PermissionAnswer(
    allowed: false,
    remember: true,
  );

  @override
  bool operator ==(Object other) =>
      other is PermissionAnswer &&
      other.allowed == allowed &&
      other.remember == remember &&
      other.precision == precision &&
      other.background == background;

  @override
  int get hashCode => Object.hash(allowed, remember, precision, background);

  @override
  String toString() =>
      'PermissionAnswer(${allowed ? "allow" : "deny"}, '
      '${remember ? "remember" : "once"}'
      '${precision == null ? "" : ", ${precision!.id}"}'
      '${background == null ? "" : ", background=$background"})';
}

/// 桥接层眼里的"要权限"动作：给定小程序与权限，返回用户的答案。
///
/// 放在模型层是有意的：桥接层只依赖这个签名，不认识 `showDialog` 也不 import
/// 任何页面，于是弹窗实现可以换（真实弹窗 / 自检模式下的自动回答 / 测试里的假实现），
/// 桥接层一行都不用改。
typedef PermissionPrompter =
    Future<PermissionAnswer> Function(
      String appId,
      MiniappPermission permission, {
      String? appName,
    });

/// 一个受控权限。id 尽量与浏览器 Permissions API 的名字保持一致。
enum MiniappPermission {
  // ---------------------------------------------------------------- 媒体与显示
  camera(
    id: 'camera',
    label: '摄像头',
    description:
        '网页通过 navigator.mediaDevices.getUserMedia() 请求摄像头画面。'
        '同意后浏览器才会打开设备；底层还需要 Android 的 CAMERA 权限。',
    webApi: 'MediaDevices.getUserMedia()',
    group: PermissionGroup.media,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>['android.permission.CAMERA'],
  ),
  microphone(
    id: 'microphone',
    label: '麦克风',
    description:
        '网页通过 navigator.mediaDevices.getUserMedia() 请求麦克风录音。'
        '同意后浏览器才会打开设备；底层还需要 Android 的 RECORD_AUDIO 权限。',
    webApi: 'MediaDevices.getUserMedia()',
    group: PermissionGroup.media,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>['android.permission.RECORD_AUDIO'],
  ),
  displayCapture(
    id: 'displayCapture',
    label: '屏幕捕获',
    description:
        '网页通过 navigator.mediaDevices.getDisplayMedia() 请求录制整个屏幕、'
        '某个应用窗口或浏览器标签页。系统会再弹一次「开始录制」的确认框。',
    webApi: 'MediaDevices.getDisplayMedia()',
    group: PermissionGroup.media,
    risk: PermissionRisk.sensitive,
    // MediaProjection 由系统自己弹确认框，不属于 Android 运行时权限。
    runtimePermissions: <String>[],
  ),
  speakerSelection(
    id: 'speakerSelection',
    label: '音频输出设备',
    description:
        '网页通过 HTMLMediaElement.setSinkId() / selectAudioOutput() 把声音'
        '路由到指定的扬声器、耳机或蓝牙音箱。',
    webApi: 'HTMLMediaElement.setSinkId()',
    group: PermissionGroup.media,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  pictureInPicture(
    id: 'pictureInPicture',
    label: '画中画',
    description:
        '网页通过 requestPictureInPicture() 让视频脱离页面，悬浮在其它应用之上播放。'
        '浏览器不弹系统授权框，由宿主这一层控制。',
    webApi: 'HTMLVideoElement.requestPictureInPicture()',
    group: PermissionGroup.media,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),

  location(
    id: 'location',
    label: '位置信息',
    description:
        '网页通过 navigator.geolocation 获取位置。可以只给近似位置（约 3 平方公里），'
        '也可以允许小程序切到后台后继续获取 —— 后台精度不会超过前台设置。',
    webApi: 'navigator.geolocation',
    group: PermissionGroup.location,
    risk: PermissionRisk.sensitive,
    // 运行时权限按精度/后台动态计算，见 PermissionService.locationRuntimePermissions。
    runtimePermissions: <String>[],
  ),

  // ------------------------------------------------------------------ 传感器
  accelerometer(
    id: 'accelerometer',
    label: '加速度计',
    description:
        '网页通过 new Accelerometer()（Generic Sensor API）或 devicemotion 事件'
        '读取设备的加速度，可用于计步、体感操作。',
    webApi: 'Accelerometer / DeviceMotionEvent',
    group: PermissionGroup.sensors,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  gyroscope(
    id: 'gyroscope',
    label: '陀螺仪',
    description:
        '网页通过 new Gyroscope() 或 deviceorientation 事件读取设备的旋转角速度，'
        '可用于体感游戏、画面防抖。',
    webApi: 'Gyroscope / DeviceOrientationEvent',
    group: PermissionGroup.sensors,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  magnetometer(
    id: 'magnetometer',
    label: '磁力计',
    description:
        '网页通过 new Magnetometer() 读取磁场方向，可用于指南针；'
        '与加速度计、陀螺仪一起可算出设备的绝对朝向。',
    webApi: 'Magnetometer',
    group: PermissionGroup.sensors,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  ambientLight(
    id: 'ambientLight',
    label: '环境光',
    description:
        '网页通过 new AmbientLightSensor() 读取环境光强度（部分设备不提供该传感器）。',
    webApi: 'AmbientLightSensor',
    group: PermissionGroup.sensors,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  proximity(
    id: 'proximity',
    label: '距离感应',
    description:
        '网页通过 new ProximitySensor() 判断是否有物体靠近（例如贴耳时熄屏），'
        '很多设备并不暴露这个传感器。',
    webApi: 'ProximitySensor',
    group: PermissionGroup.sensors,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),

  // -------------------------------------------------------------- 输入与振动
  gamepad(
    id: 'gamepad',
    label: '游戏手柄',
    description:
        '网页通过 navigator.getGamepads() 读取已连接手柄的按键与摇杆状态。',
    webApi: 'Gamepad API',
    group: PermissionGroup.input,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  vibrate(
    id: 'vibrate',
    label: '振动',
    description:
        '网页通过 navigator.vibrate() 让设备振动，常用于通知与游戏反馈。'
        'Android 的 VIBRATE 是安装期权限，这里仍然先问用户一次。',
    webApi: 'navigator.vibrate()',
    group: PermissionGroup.input,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  midi(
    id: 'midi',
    label: 'MIDI 设备',
    description:
        '网页通过 navigator.requestMIDIAccess() 与电子乐器（MIDI 键盘、合成器）通信。'
        '发送系统专用消息（SysEx）风险更高，Chromium 会单独再确认一次。',
    webApi: 'Web MIDI API',
    group: PermissionGroup.input,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>[],
  ),

  bluetooth(
    id: 'bluetooth',
    label: '蓝牙',
    description:
        '小程序通过 Web Bluetooth 语义（lemonlite.bluetooth）扫描附近的蓝牙设备，'
        '并连接 BLE 设备读写特征值。同意后系统还会再确认一次蓝牙权限。',
    webApi: 'Web Bluetooth（经 JSBridge 转接）',
    group: PermissionGroup.connectivity,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>[
      'android.permission.BLUETOOTH_SCAN',
      'android.permission.BLUETOOTH_CONNECT',
    ],
  ),
  usb(
    id: 'usb',
    label: 'USB 设备',
    description:
        '网页通过 navigator.usb.requestDevice() 与 Arduino 开发板、USB 外设通信。'
        '每次连接都要用户从系统列表里挑设备，宿主不会拿到整块 USB 总线的通行证。',
    webApi: 'WebUSB API',
    group: PermissionGroup.connectivity,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>[],
  ),
  serial(
    id: 'serial',
    label: '串口设备',
    description:
        '网页通过 navigator.serial.requestPort() 打开串口（例如开发板、传感器模块）。'
        '同样需要用户逐次选择设备。',
    webApi: 'Web Serial API',
    group: PermissionGroup.connectivity,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>[],
  ),
  /// NFC（读取 / 写入标签）。
  ///
  /// Android 的 NFC 是一个**安装期权限**（normal），不需要运行时弹框；
  /// 但这不代表用户已经同意某个小程序去读他刚贴过来的门禁卡/公交卡。
  /// 所以这一项没有 runtimePermissions，却仍然走权限弹窗：
  /// 应用内授权是唯一的用户确认点。
  nfc(
    id: 'nfc',
    label: 'NFC',
    description:
        '小程序通过 Web NFC 语义（lemonlite.nfc）读取或写入 NFC 标签（NDEF）。'
        'NFC 不需要 Android 运行时权限，但宿主仍会先问你是否允许。',
    webApi: 'Web NFC（经 JSBridge 转接）',
    group: PermissionGroup.connectivity,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>[],
  ),
  networkInfo(
    id: 'networkInfo',
    label: '网络信息',
    description:
        '网页通过 navigator.connection 读取网络类型（Wi-Fi / 4G / 5G）与带宽估算，'
        '用来决定要不要加载高清资源。',
    webApi: 'Network Information API',
    group: PermissionGroup.connectivity,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),

  // ------------------------------------------------------------- 身份与安全
  webauthn(
    id: 'webauthn',
    label: '生物识别与安全密钥',
    description:
        '网页通过 navigator.credentials.create() / get()（WebAuthn）调用指纹、'
        '面容或外接安全密钥完成无密码登录。每次验证都由系统弹框确认。',
    webApi: 'Web Authentication API',
    group: PermissionGroup.identity,
    risk: PermissionRisk.sensitive,
    runtimePermissions: <String>[],
  ),

  // ----------------------------------------------------------- 文件与剪贴板
  clipboard(
    id: 'clipboard',
    label: '剪贴板',
    description:
        '网页通过 navigator.clipboard 读写剪贴板。'
        '读剪贴板可能拿到你刚复制的密码、验证码，所以列为敏感项。',
    webApi: 'Async Clipboard API',
    group: PermissionGroup.storage,
    risk: PermissionRisk.sensitive,
    // 现代 Chromium 的异步剪贴板不需要 Android 运行时权限（写入除外，
    // 但 WebView 里写入本来就不弹系统框）。读操作由 WebView 侧
    // 的 onPermissionRequest 拦。
    runtimePermissions: <String>[],
  ),
  /// 手机存储（sdcard）读写。
  ///
  /// 这一项刻意**不是**「管理所有文件」：
  ///   * 小程序自己的两个目录（Android/data/<包名>/files/appfiles/<id> 与
  ///     data/data/<包名>/files/appfiles/<id>，见 FileScope）是它的沙箱，
  ///     **读写它们不需要任何授权** —— 那些文件本来就是它自己的数据；
  ///   * 只有要碰沙箱之外的手机存储（Download、Pictures、DCIM …）才需要这里，
  ///     因为那是"别的应用/用户自己的东西"。
  ///
  /// 授权后的实际动作也和 Android 一致：Chromium 弹出系统文件选择器（SAF），
  /// 用户选中的那个文件/目录才真正对页面可见。宿主不申请
  /// MANAGE_EXTERNAL_STORAGE（那会拿到整块存储的空白通行证），所以：
  ///   * 没有"一次性看到全部文件"的授权形态；
  ///   * 也不存在「已放行就能随便遍历 sdcard」。
  sdcard(
    id: 'sdcard',
    label: '读取手机存储',
    description:
        '网页请求读写手机存储（sdcard）里的文件或目录，例如 Download、Pictures。'
        '同意后由系统文件选择器逐个确认，页面只能拿到你选中的那些。'
        '（读写小程序自己的两个沙箱目录不需要这个权限。）',
    webApi: 'File System Access API',
    group: PermissionGroup.storage,
    risk: PermissionRisk.dangerous,
    // File System Access API 由 Chromium 自己弹系统文件选择器，
    // 真正的逐次授权发生在系统侧，这里不需要额外的运行时权限。
    runtimePermissions: <String>[],
  ),

  // ------------------------------------------------------------- 系统与设备
  notifications(
    id: 'notifications',
    label: '通知',
    description:
        '网页通过 Notification.requestPermission() 请求发送通知。'
        'Android 13+ 还需要 POST_NOTIFICATIONS 运行时权限。',
    webApi: 'Notifications API',
    group: PermissionGroup.system,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>['android.permission.POST_NOTIFICATIONS'],
  ),
  battery(
    id: 'battery',
    label: '电池状态',
    description:
        '网页通过 navigator.getBattery() 读取电量与充电状态，用来决定要不要省电。',
    webApi: 'Battery Status API',
    group: PermissionGroup.system,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  deviceMemory(
    id: 'deviceMemory',
    label: '设备内存',
    description:
        '网页通过 navigator.deviceMemory 读取近似内存大小（GB），用来决定资源加载策略。',
    webApi: 'Device Memory API',
    group: PermissionGroup.system,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  ),
  print(
    id: 'print',
    label: '打印',
    description: '网页通过 window.print() 调起系统打印面板。',
    webApi: 'window.print()',
    group: PermissionGroup.system,
    risk: PermissionRisk.normal,
    runtimePermissions: <String>[],
  );

  const MiniappPermission({
    required this.id,
    required this.label,
    required this.description,
    required this.group,
    required this.risk,
    required this.runtimePermissions,
    required this.webApi,
  });

  /// 持久化用的稳定标识（**不要改**：改了等于把用户已有的授权全部丢掉）
  final String id;

  final String label;
  final String description;
  final PermissionGroup group;
  final PermissionRisk risk;

  final String webApi;

  final List<String> runtimePermissions;

  /// 是否需要 Android 运行时权限
  bool get needsRuntimePermission => runtimePermissions.isNotEmpty;

  /// 是否走「两项独立维度」的定位模型
  bool get isLocation => this == MiniappPermission.location;

  /// 用户还没做过决定时的状态 —— 一律是「询问」。
  ///
  /// 刻意没有"这个能力比较无害所以默认放行"的分支：哪些权限算无害，
  /// 是宿主单方面的判断，用户没理由信任它。
  PermissionDecision get defaultDecision => PermissionDecision.ask;

  /// 是否算敏感权限（风险等级高于「常规」）
  bool get isSensitive => risk != PermissionRisk.normal;

  bool get needsSystemSettings => needsRuntimePermission;

  IconData get icon => switch (this) {
    MiniappPermission.camera => Icons.photo_camera_outlined,
    MiniappPermission.microphone => Icons.mic_none_outlined,
    MiniappPermission.displayCapture => Icons.screen_share_outlined,
    MiniappPermission.speakerSelection => Icons.speaker_outlined,
    MiniappPermission.pictureInPicture => Icons.picture_in_picture_alt_outlined,
    MiniappPermission.location => Icons.my_location,
    MiniappPermission.accelerometer => Icons.speed_outlined,
    MiniappPermission.gyroscope => Icons.screen_rotation_outlined,
    MiniappPermission.magnetometer => Icons.explore_outlined,
    MiniappPermission.ambientLight => Icons.light_mode_outlined,
    MiniappPermission.proximity => Icons.sensors_outlined,
    MiniappPermission.gamepad => Icons.sports_esports_outlined,
    MiniappPermission.vibrate => Icons.vibration,
    MiniappPermission.midi => Icons.piano_outlined,
    MiniappPermission.bluetooth => Icons.bluetooth_searching,
    MiniappPermission.usb => Icons.usb,
    MiniappPermission.serial => Icons.cable_outlined,
    MiniappPermission.nfc => Icons.nfc,
    MiniappPermission.networkInfo => Icons.network_cell_outlined,
    MiniappPermission.webauthn => Icons.fingerprint,
    MiniappPermission.clipboard => Icons.content_paste,
    MiniappPermission.sdcard => Icons.folder_shared_outlined,
    MiniappPermission.notifications => Icons.notifications_outlined,
    MiniappPermission.battery => Icons.battery_5_bar_outlined,
    MiniappPermission.deviceMemory => Icons.memory_outlined,
    MiniappPermission.print => Icons.print_outlined,
  };

  static const Map<String, MiniappPermission> aliases =
      <String, MiniappPermission>{
        'allFiles': MiniappPermission.sdcard,
        // 0.3 起定位合并为一项；旧的精确/大致两项按 location 读回，
        // 原来的选择会迁移成精度档（见 PermissionService.locationOf）。
        'geolocationFine': MiniappPermission.location,
        'geolocationCoarse': MiniappPermission.location,
        'geolocation': MiniappPermission.location,
      };

  /// 这一项曾经用过的 id（读旧记录时按顺序回退）。
  List<String> get legacyIds => switch (this) {
    MiniappPermission.sdcard => const <String>['allFiles'],
    MiniappPermission.location => const <String>[
      'geolocationFine',
      'geolocationCoarse',
      'geolocation',
    ],
    _ => const <String>[],
  };

  /// 从持久化的 id 反查；未知 id 返回 null（旧版本写入的权限被删掉时不至于崩）
  static MiniappPermission? byId(String id) {
    for (final MiniappPermission p in values) {
      if (p.id == id) return p;
    }
    return aliases[id];
  }

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
  static List<MiniappPermission> get sensitiveList => values
      .where((MiniappPermission p) => p.isSensitive)
      .toList(growable: false);

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
    'plugin',
  };

  /// 判断一个声明里的 id 是不是「已退役」的旧权限
  static bool isRetired(String id) => retiredIds.contains(id);
}

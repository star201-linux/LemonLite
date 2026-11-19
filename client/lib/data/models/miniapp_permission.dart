// lib/data/models/miniapp_permission.dart
//
// 框架级「权限」定义。
//
// 权限分两类：
//
//   1) **浏览器的受控资源**：摄像头、麦克风、屏幕捕获、定位、传感器、剪贴板、
//      文件、通知、MIDI、蓝牙、USB、串口、NFC、WebAuthn……
//      小程序就是 WebView 里的网页，网页请求它们的途径是**标准 Web API**
//      （`getUserMedia()`、`getDisplayMedia()`、`navigator.geolocation`、
//      `new Accelerometer()`、`navigator.bluetooth`、File System Access API…）。
//      宿主在 Chromium 弹出默认授权框之前把它拦下来，换成自己的权限模型 ——
//      拦截点见 bridge/web_permission.dart 与 bridge/geo_policy_js.dart。
//
//   2) **宿主原生能力**：Android WebView 没有实现的那几个标准 API
//      （Web Bluetooth / Web USB / Web Serial / Web NFC），小程序只能通过
//      JSBridge 的 `lemonlite.bluetooth.*` / `lemonlite.nfc.*` 调用。
//      桥接层在真正调用原生通道之前同样会过这一道权限确认。
//
// 命名原则：**枚举的 id 尽量就是浏览器的权限名**（camera / microphone /
//   clipboard / notifications / midi / nfc …），这样 metadata.json 里写的
//   名字与 `navigator.permissions.query({name})` 是同一套词汇，作者不用记两套。
//
// 定位刻意**不拆成两项权限**，而是「一项权限 + 两个正交维度」：
//   * 时间维度：仅前台（应用在用的时候）/ 允许后台；
//   * 精度维度：精确 / 近似（Android 的近似位置精度范围约 3 平方公里）。
//   这与 Android 12+ 的模型一致（FINE / COARSE + ACCESS_BACKGROUND_LOCATION），
//   并且有一条硬规则：**后台精度永远受限于前台授权** —— 只给了近似，后台也
//   只能是近似。见 [LocationGrant]。
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

/// 一个应用的定位授权：决定 + 精度 + 是否允许后台。
///
/// 关键规则（与 Android 一致）：**后台精度永远受限于前台授权**。
/// 所以这里只有一个 `precision` 字段 —— 后台不存在「比前台更精确」的状态，
/// 这条规则是被数据结构保证的，而不是靠某处 if 记得写。
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

  /// 给页面注入/下发的策略（见 bridge/geo_policy_js.dart）。
  ///
  /// `state` 是三态，`allowed` 只是它的布尔投影：
  ///   * `ask`     —— 还没问过用户。**页面侧不能直接拒**，要放行到 WebView，
  ///                  由 onGeolocationPermissionsShowPrompt 弹我们的授权框；
  ///   * `granted` —— 已允许；
  ///   * `denied`  —— 已拒绝，页面侧直接回 PERMISSION_DENIED，不打扰原生。
  ///
  /// 为什么要有 `ask`：0.6 之前页面侧把「未决定」当成「拒绝」，于是
  /// navigator.geolocation 被静默挡掉 —— 用户从没被问过，却在权限管理里
  /// 找不到任何记录。那既不是「拒绝」也不是「允许」，只是没问。
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

/// 一次授权询问的答案。
///
/// [remember] 就是弹窗里那个**默认勾选**的「仅本次生效」的反面：
///   * remember == true  → 用户把复选框取消了，决定落盘，之后不再问；
///   * remember == false → 默认状态，只对这一次调用有效，下次照问。
///
/// 之所以把「仅本次」做成默认：权限弹窗最容易被用户当成一个必须点掉的拦路虎，
/// 手一快就点了「允许」，而这个决定会一直生效。默认不记住，
/// 就把「长期授权」变成一次需要用户主动取消勾选的、有意识的选择。
///
/// [precision] / [background] 只在定位权限上有值：它们回答的是
/// 「这次给多大范围的位置、后台还要不要给」，与「允不允许」是两件事。
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

  // -------------------------------------------------------------------- 位置
  /// 位置信息：**一项权限，两个维度**。
  ///
  /// 为什么不是「精确位置 / 大致位置」两个开关：
  ///   两者不是并列的能力，而是同一份数据的不同精度档。拆成两个枚举会逼出
  ///   一个假状态 —— 两项都允许、精度算哪个？Android 12+ 的做法是
  ///   一个授权里带一个精度选择，后台是另一个独立开关，这里照搬。
  ///
  /// 实际生效的精度与后台开关存放在 [LocationGrant] 里（见 PermissionService）。
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

  // ------------------------------------------------------------- 连接与近场
  /// 蓝牙（BLE 扫描 / 连接 / 读写特征值）。
  ///
  /// Android WebView 没有实现 Web Bluetooth，所以走 `lemonlite.bluetooth.*`；
  /// 能力本身仍对应标准的 Web Bluetooth 语义（设备发现 → 连接 → GATT 读写）。
  ///
  /// 为什么仍然要应用内授权：蓝牙能拿到附近设备的名称、地址与广播数据，
  /// 连接后还能读写设备特征值 —— 这是一条真实的旁路通道（附近的信标、
  /// 可穿戴设备、共享单车锁……）。Android 12+ 把扫描/连接拆成了运行时权限，
  /// 但「应用内先问一次」仍然是必要的：系统权限只说「App 能不能用蓝牙」，
  /// 没说「这个小程序现在为什么要用」。
  ///
  /// Android 11 及以下的扫描还需要定位权限，由 MainActivity 在申请时
  /// 按系统版本自动映射（Dart 侧只写 Android 12+ 的权限名）。
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

  /// 这一项对应的**标准 Web API**。UI 与文档都用它来说明
  /// 「小程序该写哪一行代码」，而不是「调哪个桥接方法」。
  final String webApi;

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
  /// 自己弹文件选择器）。定位的运行时权限按精度动态计算，所以这里是空的。
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

  /// 用户拒绝过系统运行时权限后，是否只能去系统设置里改回来。
  ///
  /// Android 的运行时权限一旦被「拒绝且不再询问」，应用就再也弹不出系统框了，
  /// 唯一出路是跳系统设置。所以这一项用来决定要不要给用户一个跳转入口。
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

  /// 旧 id → 当前枚举的别名。
  ///
  /// 为什么需要别名而不是直接把 id 改掉：用户在过去版本里对 `allFiles`
  /// 做过的「允许/拒绝」还躺在 SharedPreferences 里，市场数据里也有
  /// 应用在声明 `allFiles`。改 id 等于让这些记录全部失效、并且让那些
  /// 应用在详情页被标成「未知权限」。别名把两件事都接住了：
  /// 声明照旧能识别，旧决定也会被当作新权限的决定读出来。
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
    'plugin',
  };

  /// 判断一个声明里的 id 是不是「已退役」的旧权限
  static bool isRetired(String id) => retiredIds.contains(id);
}

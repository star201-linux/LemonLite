// lib/bridge/bridge_api.dart
//
// 各基础 API 的 Dart 实现。
//
// 分层说明：
//   js_bridge.dart   只负责「注册 handler + 统一包错误」
//   bridge_api.dart  负责「每个 API 到底做什么」（本文件）
//   injected_js.dart 负责「JS 侧 Promise 封装」
//
// 约定：每个方法成功时返回可直接 JSON 序列化的 Map；
// 失败时抛 LemonBridgeException，由 js_bridge 转成 `{ code, message }` 回给 JS。
//
// Dart 侧调用示例（在 MiniappPage 里）：
//   final api = BridgeApi(
//     appId: 'demo',
//     themeController: themeController,
//     onSetTitle: (t) => _title.value = t,
//     onNavigateBack: (delta) async { Navigator.pop(context); return true; },
//   );
//   controller.addJavaScriptHandler(handlerName: 'lemonlite', callback: ...); // 见 js_bridge.dart

import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/bluetooth_bridge.dart';
import '../core/globals.dart';
import '../core/native_bridge.dart';
import '../core/nfc_bridge.dart';
import '../data/models/bundle_manifest.dart';
import '../data/models/miniapp_permission.dart';
import '../data/models/miniapp_session.dart';
import '../data/services/download_service.dart';
import '../data/services/permission_service.dart';
import '../data/services/plugin_service.dart';
import '../data/services/miniapp_storage_service.dart';
import '../data/services/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../theme/theme_injector.dart';

/// 桥接层的统一错误码。
/// JS 侧同结构：`{ code, message }`，其中 code === 0 表示成功。
class BridgeErrorCode {
  const BridgeErrorCode._();

  static const int ok = 0;

  /// 参数错误（缺 url / key 为空 等）
  static const int invalidArgument = 10001;

  /// 桥未就绪 / 不支持的能力
  static const int notReady = 10002;
  static const int notSupported = 10003;

  /// 网络相关
  static const int network = 20001;
  static const int timeout = 20002;
  static const int httpStatus = 20003;

  /// 存储相关
  static const int storage = 30001;

  /// 权限被拒绝。
  ///
  /// 浏览器受控资源（摄像头 / 麦克风 / 存储）被拒时，网页拿到的是 Chromium
  /// 自己的 DOMException，不会走到 JSBridge；但**原生能力**（蓝牙 / NFC）
  /// 走的是 `lemonlite.bluetooth.*` / `lemonlite.nfc.*`，它们被拒时
  /// 就是这里返回 40001 —— 小程序据此提示「去权限管理里打开」。
  static const int permissionDenied = 40001;

  /// 设备能力不可用（蓝牙 / NFC 关闭、硬件不存在）
  static const int deviceUnavailable = 50001;

  /// 兜底
  static const int internal = 90001;
}

class LemonBridgeException implements Exception {
  const LemonBridgeException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'LemonBridgeException($code): $message';
}

class BridgeApi {
  BridgeApi({
    required this.appId,
    required this.themeController,
    required this.onSetTitle,
    required this.onNavigateBack,
    this.appName = '',
    this.session,
    this.storageService,
    this.onRunInBackground,
    this.onCloseMiniapp,
    this.permissionPrompter,
    this.onEvent,
    this.moduleMethods = const <String, BundleBridgeMethod>{},
  }) {
    // 蓝牙原生事件（通知 / 连接状态 / 扫描结果 / 配对状态）只转发给
    // 当前这个小程序：按它连接过 / 正在扫描 / 配对过的地址过滤。
    _bluetoothEvents = BluetoothBridge.events.listen(_onBluetoothEvent);
  }

  /// 当前小程序的 id（storage 命名空间、权限授权、文件沙箱都用它隔离）
  final String appId;

  /// 弹窗里显示的小程序名字（空则用 appId）
  final String appName;

  /// 权限确认弹窗的注入点。
  ///
  /// 为什么由调用方注入而不是直接 import PermissionPromptService：
  /// 桥接层不应该依赖 pages/（层级方向是 pages → bridge）。注入之后，
  /// 测试里可以直接塞一个「永远允许 / 永远拒绝」的假实现。
  ///
  /// 为 null 时按 [PermissionService] 里**已经保存的决定**判断：
  /// 只有「已允许」才放行，其余一律拒绝（fail closed）。
  final PermissionPrompter? permissionPrompter;

  final ThemeController themeController;

  /// setTitle 的回调（改宿主 AppBar 标题）
  final ValueChanged<String> onSetTitle;

  /// navigateBack 的回调：返回 true 表示已处理
  final Future<bool> Function(int delta) onNavigateBack;

  /// 当前会话。可以为 null（例如没有会话上下文的测试）：
  /// 此时方向 / 常亮只作用于窗口，不留下会话级状态。
  final MiniappSession? session;

  /// 小程序数据面（storage / appfiles）。同上。
  final MiniappStorageService? storageService;

  /// runInBackground 的回调（由会话视图接到 MiniappHost 上）
  final Future<void> Function()? onRunInBackground;

  /// close 的回调
  final Future<void> Function()? onCloseMiniapp;

  /// 宿主 → 小程序的事件回调（由 MiniappPage 接到 WebView 的
  /// `window.lemonlite.__dispatchEvent`）。type 形如 `bluetooth:notification`。
  final void Function(String appId, String type, Map<String, dynamic> data)?
  onEvent;

  StreamSubscription<Map<String, dynamic>>? _bluetoothEvents;
  final Set<String> _bluetoothAddresses = <String>{};
  bool _bluetoothScanning = false;

  /// 模块通过 manifest.bridge 声明的新方法（方法名 → 定义）。
  /// 由 MiniappPage 在打开小程序时从 BundleRepository 取好塞进来；
  /// 为空时 dispatch 仍然按「不支持的 API」处理，行为与没有模块时完全一致。
  final Map<String, BundleBridgeMethod> moduleMethods;

  MiniappStorageService get _files =>
      storageService ?? MiniappStorageService.instance;

  /// JSON 请求专用实例：与市场请求分离，便于单独调超时与并发。
  static final Dio _http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      headers: <String, String>{'Accept': 'application/json, text/plain, */*'},
    ),
  );

  static Future<AndroidDeviceInfo?>? _androidInfoFuture;

  static Future<AndroidDeviceInfo?> _androidInfo() {
    // 设备信息只读一次，避免每次 getSystemInfo 都走平台通道
    return _androidInfoFuture ??= _readAndroidInfo();
  }

  static Future<AndroidDeviceInfo?> _readAndroidInfo() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await DeviceInfoPlugin().androidInfo;
    } catch (e) {
      lemonLog('BridgeApi', '读取设备信息失败，getSystemInfo 会返回空值：$e');
      return null;
    }
  }

  // ------------------------------------------------------------ 分发

  /// method 名与 injected_js.dart 里 lemonlite.* 一一对应
  ///
  /// 大部分方法**没有权限闸门**，这是有意的：浏览器的受控资源
  /// （摄像头 / 麦克风 / 定位 / 存储）由网页自己通过 Web API 发起，
  /// 拦截点在 WebView 的 `onPermissionRequest` / `onGeolocationPermissions`
  /// 上（见 bridge/web_permission.dart）。
  ///
  /// 只有**宿主原生能力**需要在桥接层加闸门：蓝牙与 NFC
  /// （`lemonlite.bluetooth.*` / `lemonlite.nfc.*`）。它们不是浏览器 API，
  /// 原生层一旦执行就已经拿到设备/标签了，所以必须在执行前先问用户
  /// —— 见 `_ensureCapability()`。
  ///
  /// 其余方法不碰受控资源：
  ///   * 网络 / 存储 / 文件沙箱 —— 只作用于小程序自己的命名空间与沙箱目录；
  ///   * 音量 / 亮度 / 屏幕方向 / 常亮 —— Android 本来就不禁止应用自行调整。
  Future<Object?> dispatch(String method, Map<String, dynamic> params) async {
    try {
      switch (method) {
        case 'getSystemInfo':
          return await getSystemInfo();
        case 'getTheme':
          return await getTheme();
        case 'setTitle':
          return await setTitle(params);
        case 'showToast':
          return await showToast(params);
        case 'navigateBack':
          return await navigateBack(params);
        case 'openUrl':
          return await openUrl(params);
        case 'request':
          return await request(params);
        case 'setStorage':
          return await setStorage(params);
        case 'getStorage':
          return await getStorage(params);
        case 'removeStorage':
          return await removeStorage(params);
        case 'clearStorage':
          return await clearStorage();
        case 'getStorageKeys':
          return await getStorageKeys();

        // ---- 蓝牙 / NFC（原生能力，调用前先过权限弹窗） ----
        case 'bluetoothStatus':
          return await bluetoothStatus();
        case 'bluetoothListPaired':
          return await bluetoothListPaired();
        case 'bluetoothScan':
          return await bluetoothScan(params);
        case 'bluetoothConnect':
          return await bluetoothConnect(params);
        case 'bluetoothDisconnect':
          return await bluetoothDisconnect(params);
        case 'bluetoothRead':
          return await bluetoothRead(params);
        case 'bluetoothWrite':
          return await bluetoothWrite(params);
        case 'bluetoothConnections':
          return await bluetoothConnections();
        case 'bluetoothRequestEnable':
          return await bluetoothRequestEnable();
        case 'bluetoothSubscribe':
          return await bluetoothSubscribe(params);
        case 'bluetoothUnsubscribe':
          return await bluetoothSubscribe(params, enable: false);
        case 'bluetoothRssi':
          return await bluetoothRssi(params);
        case 'bluetoothMtu':
          return await bluetoothMtu(params);
        case 'bluetoothPair':
          return await bluetoothPair(params);
        case 'bluetoothDisconnectAll':
          return await bluetoothDisconnectAll();

        case 'nfcStatus':
          return await nfcStatus();
        case 'nfcRead':
          return await nfcRead(params);
        case 'nfcCancel':
          return await nfcCancel();
        case 'nfcWriteText':
          return await nfcWriteText(params);

        // ---- 音量 / 亮度 ----
        case 'getVolume':
          return await getVolume();
        case 'setVolume':
          return await setVolume(params);
        case 'getBrightness':
          return await getBrightness();
        case 'setBrightness':
          return await setBrightness(params);

        // ---- 页面标记：方向 / 熄屏 ----
        case 'getPageOrientation':
          return await getPageOrientation();
        case 'setPageOrientation':
          return await setPageOrientation(params);
        case 'getKeepScreenOn':
          return await getKeepScreenOn();
        case 'setKeepScreenOn':
          return await setKeepScreenOn(params);

        // ---- 小程序专属文件目录（共享 / 私有两个作用域） ----
        case 'getAppFileDir':
          return await getAppFileDir(params);
        case 'readFile':
          return await readFile(params);
        case 'writeFile':
          return await writeFile(params);
        case 'appendFile':
          return await writeFile(params, append: true);
        case 'listFiles':
          return await listFiles(params);
        case 'deleteFile':
          return await deleteFile(params);
        case 'mkdir':
          return await mkdir(params);
        case 'exists':
          return await exists(params);
        case 'fileInfo':
          return await fileInfo(params);

        // ---- 下载（交给系统下载器） ----
        case 'downloadSave':
          return await downloadSave(params);
        case 'downloadList':
          return await downloadList();

        // ---- 会话 ----
        case 'runInBackground':
          return await runInBackground();
        case 'close':
          return await closeMiniapp();

        // ---- WASM（由插件提供，宿主只负责转发字节） ----
        case 'wasmList':
          return await wasmList();
        case 'wasmRead':
          return await wasmRead(params);

        // ---- 插件 ----
        case 'pluginsList':
          return await pluginsList();

        default:
          // 宿主内置 API 都没命中，才看是不是模块自己声明的方法
          final BundleBridgeMethod? moduleMethod = moduleMethods[method];
          if (moduleMethod != null) {
            return await _runModuleMethod(moduleMethod, params);
          }
          throw LemonBridgeException(
            BridgeErrorCode.notSupported,
            '不支持的 API：$method',
          );
      }
    } on AppFileException catch (e) {
      // 文件类失败都是可预期的（路径越界、文件过大、base64 不合法…），
      // 统一转成 10001 参数错误，而不是掉进「内部错误 90001」的兜底里 ——
      // 小程序需要能区分「我参数写错了」和「框架炸了」。
      throw LemonBridgeException(BridgeErrorCode.invalidArgument, e.message);
    }
  }

  // ------------------------------------------------------ getSystemInfo

  Future<Map<String, dynamic>> getSystemInfo() async {
    final MediaQueryData? mq = currentMediaQuery;
    final AndroidDeviceInfo? device = await _androidInfo();
    final ColorScheme scheme = themeController.effectiveScheme();

    final double width = mq?.size.width ?? 0;
    final double height = mq?.size.height ?? 0;
    final double pixelRatio = mq?.devicePixelRatio ?? 1;
    final EdgeInsets insets = mq?.padding ?? EdgeInsets.zero;
    final EdgeInsets viewPadding = mq?.viewPadding ?? EdgeInsets.zero;

    return <String, dynamic>{
      'platform': 'android',
      'platformName': 'Android',
      // 系统版本（device_info_plus 拿不到时返回空串，小程序自行兜底）
      'platformVersion': device?.version.release ?? '',
      'sdkInt': device?.version.sdkInt ?? 0,
      'brand': device?.brand ?? '',
      'model': device?.model ?? '',
      'isPhysicalDevice': device?.isPhysicalDevice ?? true,

      // 逻辑像素（dp）
      'screenWidth': _round2(width),
      'screenHeight': _round2(height),
      // 物理像素
      'screenWidthPx': (width * pixelRatio).round(),
      'screenHeightPx': (height * pixelRatio).round(),
      'pixelRatio': _round2(pixelRatio),
      // 安全区（刘海/手势条），小程序做全屏布局时很有用
      'safeAreaTop': _round2(insets.top),
      'safeAreaBottom': _round2(insets.bottom),
      'statusBarHeight': _round2(viewPadding.top),

      // 主题
      'brightness': scheme.brightness == Brightness.dark ? 'dark' : 'light',
      'themeMode': themeController.themeModeLabel,
      'primaryColor': ThemeInjector.toHex(scheme.primary),
      'themeSource': themeController.sourceLabel,

      // 宿主与框架
      'appVersion': AppInfo.version,
      'appBuildNumber': AppInfo.buildNumber,
      'framework': kFrameworkName,
      'frameworkVersion': kFrameworkVersion,
      'sdkVersion': kFrameworkVersion,

      'locale': WidgetsBinding.instance.platformDispatcher.locale.toString(),
    };
  }

  // ---------------------------------------------------------- getTheme

  /// 返回当前 MD3 主题（结构见 ThemeInjector.toThemePayload 的注释）
  Future<Map<String, dynamic>> getTheme() async =>
      themeController.themeSnapshot();

  // ---------------------------------------------------------- setTitle

  Future<Map<String, dynamic>> setTitle(Map<String, dynamic> params) async {
    final String title = _string(params['title']);
    onSetTitle(title);
    return <String, dynamic>{'title': title};
  }

  // --------------------------------------------------------- showToast

  Future<Map<String, dynamic>> showToast(Map<String, dynamic> params) async {
    final String message = _string(params['message']);
    if (message.isEmpty) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'showToast：message 不能为空',
      );
    }
    final String type = _string(params['type'], 'info');
    final int durationMs = _int(
      params['duration'],
      2000,
    ).clamp(500, 10000).toInt();

    AppTheme.showToast(
      message,
      isError: type == 'error',
      duration: Duration(milliseconds: durationMs),
    );
    return <String, dynamic>{'shown': true};
  }

  // ------------------------------------------------------ navigateBack

  Future<Map<String, dynamic>> navigateBack(Map<String, dynamic> params) async {
    final int delta = _int(params['delta'], 1).clamp(1, 10).toInt();
    final bool handled = await onNavigateBack(delta);
    return <String, dynamic>{'handled': handled, 'delta': delta};
  }

  // ---------------------------------------------------------- openUrl

  Future<Map<String, dynamic>> openUrl(Map<String, dynamic> params) async {
    final String raw = _string(params['url']);
    if (raw.isEmpty) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'openUrl：url 必填',
      );
    }
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'openUrl：url 不是合法地址',
      );
    }
    const Set<String> allowed = <String>{'http', 'https', 'mailto', 'tel'};
    final String scheme = uri.scheme.toLowerCase();
    if (!allowed.contains(scheme)) {
      throw LemonBridgeException(
        BridgeErrorCode.notSupported,
        'openUrl：出于安全考虑不支持 $scheme: 协议',
      );
    }

    try {
      final bool opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const LemonBridgeException(
          BridgeErrorCode.internal,
          'openUrl：没有可打开该链接的应用',
        );
      }
      return <String, dynamic>{'opened': true, 'url': raw};
    } on LemonBridgeException {
      rethrow;
    } catch (e) {
      throw LemonBridgeException(BridgeErrorCode.internal, 'openUrl 失败：$e');
    }
  }

  // ---------------------------------------------------------- request

  /// 由宿主发起 HTTP，因此小程序不受浏览器跨域限制。
  /// 4xx 也会正常返回给小程序（由它决定怎么处理），只有网络层错误才 reject。
  Future<Map<String, dynamic>> request(Map<String, dynamic> params) async {
    final String url = _string(params['url']);
    final Uri? uri = Uri.tryParse(url);
    if (url.isEmpty || uri == null || !uri.hasScheme) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'request：url 必须是绝对地址',
      );
    }
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw LemonBridgeException(
        BridgeErrorCode.notSupported,
        'request：仅支持 http/https，收到 $scheme',
      );
    }

    final String method = _string(params['method'], 'GET').toUpperCase();
    final Map<String, dynamic>? headers = _map(params['headers']);
    final Map<String, dynamic>? query = _map(params['params']);
    final Object? data = params['data'];
    final int timeoutMs = _int(
      params['timeout'],
      15000,
    ).clamp(1000, 60000).toInt();

    final Stopwatch watch = Stopwatch()..start();
    try {
      final Response<String> response = await _http.request<String>(
        url,
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain, // 自己决定怎么解析，错误更可控
          sendTimeout: Duration(milliseconds: timeoutMs),
          receiveTimeout: Duration(milliseconds: timeoutMs),
          // 4xx 也交给小程序判断，只有 5xx 视为异常
          validateStatus: (int? status) => status != null && status < 500,
        ),
      );
      watch.stop();

      final String body = response.data ?? '';
      return <String, dynamic>{
        'status': response.statusCode ?? 0,
        'statusText': response.statusMessage ?? '',
        'headers': response.headers.map.map(
          (String key, List<String> value) =>
              MapEntry<String, String>(key, value.join(', ')),
        ),
        'data': _decodeBody(body),
        'durationMs': watch.elapsedMilliseconds,
        'url': response.realUri.toString(),
      };
    } on DioException catch (e) {
      throw _mapRequestError(e, url);
    } catch (e) {
      throw LemonBridgeException(BridgeErrorCode.network, 'request 失败：$e');
    }
  }

  /// 尽量把 JSON 响应解成对象；不是 JSON 就原样返回字符串
  Object? _decodeBody(String body) {
    final String trimmed = body.trim();
    if (trimmed.isEmpty) return '';
    final bool looksLikeJson =
        trimmed.startsWith('{') || trimmed.startsWith('[');
    if (!looksLikeJson) return body;
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return body;
    }
  }

  LemonBridgeException _mapRequestError(DioException e, String url) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      // dio 5.9 起新增：响应体转换阶段超时
      case DioExceptionType.transformTimeout:
        return LemonBridgeException(BridgeErrorCode.timeout, '请求超时：$url');
      case DioExceptionType.badCertificate:
        return const LemonBridgeException(BridgeErrorCode.network, '服务器证书校验失败');
      case DioExceptionType.cancel:
        return const LemonBridgeException(BridgeErrorCode.network, '请求已取消');
      case DioExceptionType.connectionError:
        return LemonBridgeException(BridgeErrorCode.network, '网络连接失败：$url');
      case DioExceptionType.badResponse:
        return LemonBridgeException(
          BridgeErrorCode.httpStatus,
          '服务器错误 HTTP ${e.response?.statusCode ?? 0}：$url',
        );
      case DioExceptionType.unknown:
        return LemonBridgeException(
          BridgeErrorCode.network,
          '请求失败：${e.message ?? '未知原因'}',
        );
    }
  }

  // ---------------------------------------------------------- storage

  /// 值会先 JSON 编码再落盘，所以数字 / 布尔 / 对象 / 数组都能原样取回。
  static const int _maxStorageBytes = 512 * 1024;

  Future<Map<String, dynamic>> setStorage(Map<String, dynamic> params) async {
    final String key = _requireKey(params, 'setStorage(key, value)');
    final Object? value = params['value'];

    final String encoded;
    try {
      encoded = jsonEncode(value);
    } catch (e) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'setStorage：value 无法序列化（$e）',
      );
    }
    if (encoded.length > _maxStorageBytes) {
      throw const LemonBridgeException(
        BridgeErrorCode.storage,
        'setStorage：单个键值不能超过 512KB',
      );
    }

    final bool ok = await SettingsService.instance.writeRaw(
      SettingsService.miniappStorageKey(appId, key),
      encoded,
    );
    if (!ok) {
      throw const LemonBridgeException(
        BridgeErrorCode.storage,
        'setStorage：写入失败',
      );
    }
    return <String, dynamic>{'key': key, 'bytes': encoded.length};
  }

  Future<Map<String, dynamic>> getStorage(Map<String, dynamic> params) async {
    final String key = _requireKey(params, 'getStorage(key)');
    final String? raw = SettingsService.instance.readRaw(
      SettingsService.miniappStorageKey(appId, key),
    );

    if (raw == null) {
      return <String, dynamic>{
        'key': key,
        'value': params['defaultValue'],
        'found': false,
      };
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      decoded = raw; // 兼容手工写入的裸字符串
    }
    return <String, dynamic>{'key': key, 'value': decoded, 'found': true};
  }

  Future<Map<String, dynamic>> removeStorage(
    Map<String, dynamic> params,
  ) async {
    final String key = _requireKey(params, 'removeStorage(key)');
    final bool ok = await SettingsService.instance.removeRaw(
      SettingsService.miniappStorageKey(appId, key),
    );
    return <String, dynamic>{'key': key, 'removed': ok};
  }

  Future<Map<String, dynamic>> clearStorage() async {
    final List<String> keys = SettingsService.instance.miniappStorageKeys(
      appId,
    );
    for (final String key in keys) {
      await SettingsService.instance.removeRaw(
        SettingsService.miniappStorageKey(appId, key),
      );
    }
    return <String, dynamic>{'cleared': keys.length};
  }

  Future<Map<String, dynamic>> getStorageKeys() async => <String, dynamic>{
    'keys': SettingsService.instance.miniappStorageKeys(appId),
  };

  // ------------------------------------------------------ 蓝牙事件路由

  /// 原生事件的过滤与转发。
  ///
  /// 只转发给「和这个地址有关」的会话：连接过 / 订阅过 / 配对过。
  /// 扫描结果只在本次 scan 调用进行中转发（原生同一时刻只允许一个扫描）。
  void _onBluetoothEvent(Map<String, dynamic> event) {
    final String type = _string(event['type']);
    if (type.isEmpty) return;
    final String address = _string(event['address']);
    final bool allowed =
        (_bluetoothScanning && type == 'scanResult') ||
        (address.isNotEmpty && _bluetoothAddresses.contains(address));
    if (!allowed) return;
    onEvent?.call(appId, 'bluetooth:$type', Map<String, dynamic>.of(event));
  }

  /// 会话销毁时取消事件订阅（不主动断开连接：同地址可能被同一个小程序的
  /// 其它会话使用；清理由小程序的 disconnect / 页面切后台策略决定）。
  Future<void> dispose() async {
    await _bluetoothEvents?.cancel();
    _bluetoothEvents = null;
    _bluetoothAddresses.clear();
  }

  // ---------------------------------------------------------- 蓝牙

  /// 适配器状态。查询本身不涉及用户数据，不需要弹窗；
  /// 真正拿到设备清单 / 连接设备时才过权限。
  Future<Map<String, dynamic>> bluetoothStatus() async {
    if (!BluetoothBridge.isSupported) {
      return <String, dynamic>{
        'supported': false,
        'enabled': false,
        'bleSupported': false,
        'permissionGranted': false,
      };
    }
    try {
      return await BluetoothBridge.status();
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  Future<Map<String, dynamic>> bluetoothListPaired() async {
    await _ensureCapability(MiniappPermission.bluetooth);
    try {
      final List<Map<String, dynamic>> devices =
          await BluetoothBridge.listPaired();
      return <String, dynamic>{'count': devices.length, 'devices': devices};
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  /// 当前 App 建立的连接（不是系统里所有已连接设备）。
  Future<Map<String, dynamic>> bluetoothConnections() async {
    await _ensureCapability(MiniappPermission.bluetooth);
    try {
      final List<Map<String, dynamic>> devices =
          await BluetoothBridge.connections();
      return <String, dynamic>{'count': devices.length, 'devices': devices};
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  /// 请求系统打开蓝牙。系统框没有同步结果，调用方用 status() 轮询。
  Future<Map<String, dynamic>> bluetoothRequestEnable() async {
    await _ensureCapability(MiniappPermission.bluetooth);
    try {
      return await BluetoothBridge.requestEnable();
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  /// BLE / 经典蓝牙扫描。持续时间由调用方给，原生侧封顶 20 秒。
  ///
  /// 扫描期间原生会持续发 `scanResult` 事件；JS 侧用
  /// `lemonlite.bluetooth.onScanResult(cb)` 接收。返回值仍是最终完整列表，
  /// 这样「只想拿一次结果」的小程序不用关心事件。
  Future<Map<String, dynamic>> bluetoothScan(
    Map<String, dynamic> params,
  ) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final int durationMs = _int(params['durationMs'], 5000);
    final String mode = _string(params['mode'], 'ble').toLowerCase();
    final List<String> serviceUuids = (params['serviceUuids'] is List)
        ? (params['serviceUuids'] as List)
              .map((Object? e) => _string(e).trim())
              .where((String e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final String namePrefix = _string(params['namePrefix']).trim();
    _bluetoothScanning = true;
    try {
      final List<Map<String, dynamic>> devices = await BluetoothBridge.scan(
        durationMs: durationMs,
        mode: mode,
        serviceUuids: serviceUuids,
        namePrefix: namePrefix,
      );
      return <String, dynamic>{
        'count': devices.length,
        'devices': devices,
        'mode': mode,
      };
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    } finally {
      _bluetoothScanning = false;
    }
  }

  /// 断开全部连接（清理动作，不设权限闸门）。
  Future<Map<String, dynamic>> bluetoothDisconnectAll() async {
    try {
      await BluetoothBridge.disconnectAll();
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
    _bluetoothAddresses.clear();
    return <String, dynamic>{'disconnected': true};
  }

  /// 订阅 / 取消订阅特征值通知（notify / indicate）。
  Future<Map<String, dynamic>> bluetoothSubscribe(
    Map<String, dynamic> params, {
    bool enable = true,
  }) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final String address = _requireAddress(
      params,
      enable
          ? 'bluetooth.subscribe(options)'
          : 'bluetooth.unsubscribe(options)',
    );
    final String service = _requireUuid(
      params,
      'service',
      'bluetooth.subscribe',
    );
    final String characteristic = _requireUuid(
      params,
      'characteristic',
      'bluetooth.subscribe',
    );
    try {
      await BluetoothBridge.subscribe(
        address: address,
        service: service,
        characteristic: characteristic,
        enable: enable,
      );
      if (enable) _bluetoothAddresses.add(address);
      return <String, dynamic>{
        'address': address,
        'service': service,
        'characteristic': characteristic,
        'subscribed': enable,
      };
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  /// 读取当前连接信号强度。
  Future<Map<String, dynamic>> bluetoothRssi(
    Map<String, dynamic> params,
  ) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final String address = _requireAddress(params, 'bluetooth.rssi(address)');
    try {
      final int rssi = await BluetoothBridge.getRssi(address);
      _bluetoothAddresses.add(address);
      return <String, dynamic>{'address': address, 'rssi': rssi};
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  /// 请求更大的 MTU（返回实际协商值）。
  Future<Map<String, dynamic>> bluetoothMtu(Map<String, dynamic> params) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final String address = _requireAddress(params, 'bluetooth.mtu(options)');
    final int mtu = _int(params['mtu'], 512);
    try {
      final int negotiated = await BluetoothBridge.requestMtu(address, mtu);
      _bluetoothAddresses.add(address);
      return <String, dynamic>{'address': address, 'mtu': negotiated};
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  /// 发起配对（经典蓝牙 / 双模设备），结果通过 `bondState` 事件通知。
  Future<Map<String, dynamic>> bluetoothPair(
    Map<String, dynamic> params,
  ) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final String address = _requireAddress(params, 'bluetooth.pair(address)');
    try {
      final Map<String, dynamic> data = await BluetoothBridge.pair(address);
      _bluetoothAddresses.add(address);
      return data;
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  Future<Map<String, dynamic>> bluetoothConnect(
    Map<String, dynamic> params,
  ) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final String address = _requireAddress(
      params,
      'bluetooth.connect(address)',
    );
    // 先登记地址再连接：原生在服务发现完成时会立刻推 connectionState 事件，
    // 那时 connect() 的 Future 还没返回；后登记会把这条事件丢掉。
    _bluetoothAddresses.add(address);
    try {
      return await BluetoothBridge.connect(address);
    } on BluetoothException catch (e) {
      _bluetoothAddresses.remove(address);
      throw _mapBluetoothError(e);
    }
  }

  Future<Map<String, dynamic>> bluetoothDisconnect(
    Map<String, dynamic> params,
  ) async {
    // 断开连接是**清理动作**，不设权限闸门：用户中途撤权、或权限弹窗被拒时，
    // 也仍然应该允许它把已经建立的连接关掉，而不是留一个泄漏的 GATT。
    final String address = _requireAddress(
      params,
      'bluetooth.disconnect(address)',
    );
    try {
      await BluetoothBridge.disconnect(address);
      _bluetoothAddresses.remove(address);
      return <String, dynamic>{'address': address, 'disconnected': true};
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  Future<Map<String, dynamic>> bluetoothRead(
    Map<String, dynamic> params,
  ) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final String address = _requireAddress(params, 'bluetooth.read(options)');
    final String service = _requireUuid(params, 'service', 'bluetooth.read');
    final String characteristic = _requireUuid(
      params,
      'characteristic',
      'bluetooth.read',
    );
    try {
      final String value = await BluetoothBridge.read(
        address: address,
        service: service,
        characteristic: characteristic,
      );
      return <String, dynamic>{
        'address': address,
        'service': service,
        'characteristic': characteristic,
        'value': value,
        'base64': true,
      };
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  Future<Map<String, dynamic>> bluetoothWrite(
    Map<String, dynamic> params,
  ) async {
    await _ensureCapability(MiniappPermission.bluetooth);
    final String address = _requireAddress(params, 'bluetooth.write(options)');
    final String service = _requireUuid(params, 'service', 'bluetooth.write');
    final String characteristic = _requireUuid(
      params,
      'characteristic',
      'bluetooth.write',
    );
    final String data = _requireBase64Data(params);
    final bool withResponse = _bool(params['withResponse'], fallback: true);
    try {
      await BluetoothBridge.write(
        address: address,
        service: service,
        characteristic: characteristic,
        data: data,
        withResponse: withResponse,
      );
      return <String, dynamic>{
        'address': address,
        'service': service,
        'characteristic': characteristic,
        'written': true,
        'bytes': base64Decode(data).length,
      };
    } on BluetoothException catch (e) {
      throw _mapBluetoothError(e);
    }
  }

  // ------------------------------------------------------------ NFC

  Future<Map<String, dynamic>> nfcStatus() async {
    if (!NfcBridge.isSupported) {
      return <String, dynamic>{'supported': false, 'enabled': false};
    }
    try {
      return await NfcBridge.status();
    } on NfcException catch (e) {
      throw _mapNfcError(e);
    }
  }

  Future<Map<String, dynamic>> nfcRead(Map<String, dynamic> params) async {
    await _ensureCapability(MiniappPermission.nfc);
    final int timeoutMs = _int(params['timeoutMs'], 15000);
    try {
      return await NfcBridge.read(timeoutMs: timeoutMs);
    } on NfcException catch (e) {
      throw _mapNfcError(e);
    }
  }

  Future<Map<String, dynamic>> nfcCancel() async {
    await NfcBridge.cancel();
    return <String, dynamic>{'cancelled': true};
  }

  Future<Map<String, dynamic>> nfcWriteText(Map<String, dynamic> params) async {
    await _ensureCapability(MiniappPermission.nfc);
    final String text = _string(params['text']).trim();
    if (text.isEmpty) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'nfc.writeText(text)：text 不能为空',
      );
    }
    if (text.length > 4096) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'nfc.writeText(text)：内容过长（上限 4096 字符）',
      );
    }
    final int timeoutMs = _int(params['timeoutMs'], 15000);
    final bool formatIfNeeded = _bool(params['formatIfNeeded'], fallback: true);
    try {
      return await NfcBridge.writeText(
        text: text,
        timeoutMs: timeoutMs,
        formatIfNeeded: formatIfNeeded,
      );
    } on NfcException catch (e) {
      throw _mapNfcError(e);
    }
  }

  /// 原生能力调用前的统一闸门：应用内弹窗 → Android 运行时权限。
  ///
  /// 顺序与摄像头一致：**先问用户，再申请系统权限**。反过来的话，
  /// 用户会先看到一个系统授权框，还不知道是哪个小程序在要权限。
  Future<void> _ensureCapability(MiniappPermission permission) async {
    final PermissionPrompter? prompter = permissionPrompter;
    if (prompter != null) {
      final PermissionAnswer answer = await prompter(
        appId,
        permission,
        appName: appName.isEmpty ? null : appName,
      );
      if (!answer.allowed) {
        throw LemonBridgeException(
          BridgeErrorCode.permissionDenied,
          '用户拒绝了${permission.label}权限（可在「应用管理 → 权限」里修改）',
        );
      }
    } else {
      // 没有弹窗实现（测试 / 非页面上下文）：只认已经保存的「允许」，
      // 未决定与拒绝都 fail closed。
      final PermissionDecision decision = PermissionService.instance.decisionOf(
        appId,
        permission,
      );
      if (decision != PermissionDecision.granted) {
        throw LemonBridgeException(
          BridgeErrorCode.permissionDenied,
          '${permission.label}权限未授予（当前上下文无法弹出确认框）',
        );
      }
    }

    if (permission.needsRuntimePermission) {
      final bool ok = await NativeBridge.requestRuntimePermissions(
        permission.runtimePermissions,
      );
      if (!ok) {
        throw LemonBridgeException(
          BridgeErrorCode.permissionDenied,
          'Android 系统未授予${permission.label}权限，请到系统设置里允许',
        );
      }
    }
  }

  String _requireAddress(Map<String, dynamic> params, String api) {
    final String address = _string(params['address']).trim();
    if (address.isEmpty) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        '$api：缺少 address（设备 MAC / 蓝牙地址）',
      );
    }
    return address;
  }

  String _requireUuid(Map<String, dynamic> params, String key, String api) {
    final String value = _string(params[key]).trim();
    if (value.isEmpty) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        '$api：缺少 $key（服务 / 特征值 UUID）',
      );
    }
    return value;
  }

  /// 写特征值的数据：接受 base64 字符串，也接受 0~255 的字节数组。
  String _requireBase64Data(Map<String, dynamic> params) {
    final Object? raw = params['data'] ?? params['value'] ?? params['base64'];
    if (raw is List) {
      final List<int> bytes = <int>[];
      for (final Object? item in raw) {
        final int? b = _doubleOrNull(item)?.toInt();
        if (b == null || b < 0 || b > 255) {
          throw const LemonBridgeException(
            BridgeErrorCode.invalidArgument,
            'bluetooth.write：data 数组只能包含 0~255 的整数',
          );
        }
        bytes.add(b);
      }
      if (bytes.isEmpty) {
        throw const LemonBridgeException(
          BridgeErrorCode.invalidArgument,
          'bluetooth.write：data 不能为空',
        );
      }
      if (bytes.length > 4096) {
        throw const LemonBridgeException(
          BridgeErrorCode.invalidArgument,
          'bluetooth.write：单次写入不能超过 4096 字节',
        );
      }
      return base64Encode(bytes);
    }
    final String text = _string(raw).trim();
    if (text.isEmpty) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'bluetooth.write：缺少 data（base64 或 0~255 字节数组）',
      );
    }
    final List<int> decoded;
    try {
      decoded = base64Decode(text);
    } on FormatException {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'bluetooth.write：data 不是合法的 base64',
      );
    }
    if (decoded.length > 4096) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'bluetooth.write：单次写入不能超过 4096 字节',
      );
    }
    return text;
  }

  LemonBridgeException _mapBluetoothError(BluetoothException e) {
    if (e.code == 'permission_denied') {
      return LemonBridgeException(BridgeErrorCode.permissionDenied, e.message);
    }
    if (e.code == 'unsupported') {
      return LemonBridgeException(BridgeErrorCode.notSupported, e.message);
    }
    if (e.code == 'disabled') {
      return LemonBridgeException(BridgeErrorCode.deviceUnavailable, e.message);
    }
    if (e.code == 'timeout') {
      return LemonBridgeException(BridgeErrorCode.timeout, e.message);
    }
    return LemonBridgeException(BridgeErrorCode.internal, e.message);
  }

  LemonBridgeException _mapNfcError(NfcException e) {
    if (e.code == 'permission_denied') {
      return LemonBridgeException(BridgeErrorCode.permissionDenied, e.message);
    }
    if (e.code == 'unsupported') {
      return LemonBridgeException(BridgeErrorCode.notSupported, e.message);
    }
    if (e.code == 'disabled') {
      return LemonBridgeException(BridgeErrorCode.deviceUnavailable, e.message);
    }
    if (e.code == 'timeout') {
      return LemonBridgeException(BridgeErrorCode.timeout, e.message);
    }
    return LemonBridgeException(BridgeErrorCode.internal, e.message);
  }

  // ------------------------------------------------------ 音量 / 亮度

  /// 取媒体音量。宿主通过平台通道问 Android 的 AudioManager，
  /// 拿不到（非 Android / 系统拒绝）就按「不支持的能力」明确报错，
  /// 而不是返回一堆 0 让小程序以为音量为零。
  Future<Map<String, dynamic>> getVolume() async {
    final VolumeInfo? info = await NativeBridge.getVolume();
    if (info == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.notSupported,
        'getVolume：当前平台不支持音量控制（仅 Android 可用）',
      );
    }
    return <String, dynamic>{
      'level': info.level,
      'max': info.max,
      'percent': _round2(info.percent),
      'supported': true,
    };
  }

  /// 设置媒体音量。[percent] 是 0~1 的比例，宿主侧再换算成档位。
  Future<Map<String, dynamic>> setVolume(Map<String, dynamic> params) async {
    final Object? raw =
        params['percent'] ?? params['value'] ?? params['volume'];
    final double? percent = _doubleOrNull(raw);
    if (percent == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'setVolume(percent)：percent 必须是 0~1 的数字',
      );
    }
    final VolumeInfo? info = await NativeBridge.setVolume(
      percent.clamp(0.0, 1.0),
    );
    if (info == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.notSupported,
        'setVolume：当前平台不支持音量控制（仅 Android 可用）',
      );
    }
    return <String, dynamic>{
      'level': info.level,
      'max': info.max,
      'percent': _round2(info.percent),
      'supported': true,
    };
  }

  /// 取亮度。window 是本 App 的窗口亮度（-1 表示跟随系统），system 是系统亮度参考值。
  ///
  /// 为什么只给「窗口亮度」：改系统亮度需要 WRITE_SETTINGS 这个特殊权限
  /// （要去系统设置页里手动授予），而窗口亮度不需要任何权限、只影响本 App，
  /// 对小程序来说已经够用，也不会有「一个小程序把整机亮度改了」的越权感。
  Future<Map<String, dynamic>> getBrightness() async {
    final BrightnessInfo? info = await NativeBridge.getBrightness();
    if (info == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.notSupported,
        'getBrightness：当前平台不支持亮度控制（仅 Android 可用）',
      );
    }
    return <String, dynamic>{
      'window': _round2(info.window),
      'system': _round2(info.system),
      'followSystem': info.window < 0,
      'supported': true,
    };
  }

  /// 设置窗口亮度：0~1；传 -1 恢复「跟随系统」。
  Future<Map<String, dynamic>> setBrightness(
    Map<String, dynamic> params,
  ) async {
    final Object? raw =
        params['value'] ?? params['brightness'] ?? params['percent'];
    final double? value = _doubleOrNull(raw);
    if (value == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'setBrightness(value)：value 必须是 -1（跟随系统）或 0~1 的数字',
      );
    }
    final double clamped = value < 0 ? -1 : value.clamp(0.0, 1.0);
    final bool ok = await NativeBridge.setBrightness(clamped);
    if (!ok) {
      throw const LemonBridgeException(
        BridgeErrorCode.notSupported,
        'setBrightness：当前平台不支持亮度控制（仅 Android 可用）',
      );
    }
    return <String, dynamic>{
      'window': _round2(clamped),
      'followSystem': clamped < 0,
      'supported': true,
    };
  }

  // -------------------------------------------------- 页面标记：方向 / 熄屏

  Future<Map<String, dynamic>> getPageOrientation() async {
    final MiniappOrientation orientation =
        session?.orientation ?? MiniappOrientation.auto;
    return <String, dynamic>{
      'orientation': MiniappOrientationX.idOf(orientation),
      'label': MiniappOrientationX.labelOf(orientation),
      'supported': NativeBridge.isSupported,
    };
  }

  /// 把小程序的「本页面应该是横屏 / 竖屏 / …」标记落到宿主 Activity 上。
  ///
  /// 这是**页面标记**而不是用户设置：小程序在自己的代码里调（类似安卓调 SDK）。
  /// 它仍然要过权限闸门（第一次调用会弹窗确认），只是风险等级是「常规」——
  /// 权限的默认状态没有例外，否则"没问过就问"这条规则就开始有漏洞了。
  /// 标记跟着会话走：会话切到后台时会自动恢复成 auto，
  /// 不会出现「小程序退到后台了，整个 App 还锁着横屏」。
  Future<Map<String, dynamic>> setPageOrientation(
    Map<String, dynamic> params,
  ) async {
    final MiniappOrientation? orientation = MiniappOrientationX.parse(
      params['orientation'] ?? params['value'] ?? params['mode'],
    );
    if (orientation == null) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'setPageOrientation(orientation)：取值必须是 '
        '${MiniappOrientationX.allIds.join(" / ")} 之一',
      );
    }
    final MiniappSession? current = session;
    if (current != null) {
      await current.setOrientation(orientation);
    } else {
      await NativeBridge.setOrientation(orientation);
    }
    return <String, dynamic>{
      'orientation': MiniappOrientationX.idOf(orientation),
      'label': MiniappOrientationX.labelOf(orientation),
      'applied': NativeBridge.isSupported,
    };
  }

  Future<Map<String, dynamic>> getKeepScreenOn() async {
    final bool keepOn = session?.keepScreenOn ?? false;
    return <String, dynamic>{
      'keepScreenOn': keepOn,
      // 与 keepScreenOn 互为反义，给小程序一个更贴近需求的读法
      'allowScreenOff': !keepOn,
      'supported': NativeBridge.isSupported,
    };
  }

  /// 标记本页面是否允许熄屏。
  ///
  /// 支持两种写法（语义相反，别混）：
  ///   setKeepScreenOn({ enabled: true })        → 屏幕常亮 = 不允许熄屏
  ///   setKeepScreenOn({ allowScreenOff: false }) → 不允许熄屏
  Future<Map<String, dynamic>> setKeepScreenOn(
    Map<String, dynamic> params,
  ) async {
    final bool hasKeepOn =
        params.containsKey('enabled') || params.containsKey('keepScreenOn');
    final bool hasAllowOff = params.containsKey('allowScreenOff');
    if (!hasKeepOn && !hasAllowOff) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'setKeepScreenOn：需要 enabled（是否常亮）或 allowScreenOff（是否允许熄屏）参数',
      );
    }

    final bool keepOn = hasKeepOn
        ? _bool(params['enabled'] ?? params['keepScreenOn'], fallback: true)
        : !_bool(params['allowScreenOff'], fallback: true);

    final MiniappSession? current = session;
    if (current != null) {
      await current.setKeepScreenOn(keepOn);
    } else {
      await NativeBridge.setKeepScreenOn(keepOn);
    }
    return <String, dynamic>{
      'keepScreenOn': keepOn,
      'allowScreenOff': !keepOn,
      'applied': NativeBridge.isSupported,
    };
  }

  // ------------------------------------------------------------ 文件操作

  /// 小程序专属目录的绝对路径。
  ///
  /// 有两个作用域，小程序用 `scope` 参数选（默认 files）：
  ///   files   → `/storage/emulated/0/Android/data/<包名>/files/appfiles/<appId>`
  ///   private → `/data/user/0/<包名>/files/appfiles/<appId>`（即 `data/data/<包名>/...`）
  ///
  /// 对外只暴露这两个目录，其它路径一律拒绝（见 MiniappStorageService 的路径校验）。
  /// 不传 scope 时返回共享目录，并在返回体里带上两个作用域的可读路径，
  /// 方便小程序一次性了解自己有哪些可写的地方。
  Future<Map<String, dynamic>> getAppFileDir(
    Map<String, dynamic> params,
  ) async {
    final FileScope scope = FileScope.parse(params['scope']);
    final String path = await _files.appFilesPath(appId, scope: scope);
    return <String, dynamic>{
      'appId': appId,
      'scope': scope.id,
      'path': path,
      'packageName': AppInfo.packageName,
      // 需求里约定的可读形态，方便小程序/文档直接展示
      'displayPath': _files.displayPath(appId, scope),
      'scopes': <Map<String, dynamic>>[
        for (final FileScope s in FileScope.values)
          <String, dynamic>{
            'id': s.id,
            'label': s.label,
            'displayPath': _files.displayPath(appId, s),
          },
      ],
    };
  }

  Future<Map<String, dynamic>> readFile(Map<String, dynamic> params) async {
    final String path = _requirePath(params, 'readFile(path)');
    return _files.readFile(
      appId,
      path,
      asBase64: _isBase64(params),
      scope: FileScope.parse(params['scope']),
    );
  }

  Future<Map<String, dynamic>> writeFile(
    Map<String, dynamic> params, {
    bool append = false,
  }) async {
    final String path = _requirePath(
      params,
      append ? 'appendFile(path, data)' : 'writeFile(path, data)',
    );
    if (!params.containsKey('data')) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'writeFile(path, data)：缺少 data',
      );
    }
    final String data = params['data']?.toString() ?? '';
    return _files.writeFile(
      appId,
      path,
      data,
      asBase64: _isBase64(params),
      append: append,
      scope: FileScope.parse(params['scope']),
    );
  }

  Future<Map<String, dynamic>> listFiles(Map<String, dynamic> params) async {
    final String path = _string(params['path'], '.');
    final FileScope scope = FileScope.parse(params['scope']);
    final List<MiniappFileEntry> entries = await _files.listFiles(
      appId,
      path,
      scope: scope,
    );
    return <String, dynamic>{
      'path': _files.normalizeRelativePath(path),
      'scope': scope.id,
      'count': entries.length,
      'entries': entries
          .map((MiniappFileEntry e) => e.toJson())
          .toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> deleteFile(Map<String, dynamic> params) async {
    final String path = _requirePath(params, 'deleteFile(path)');
    final FileScope scope = FileScope.parse(params['scope']);
    final bool deleted = await _files.deleteFile(appId, path, scope: scope);
    return <String, dynamic>{
      'path': _files.normalizeRelativePath(path),
      'scope': scope.id,
      'deleted': deleted,
    };
  }

  Future<Map<String, dynamic>> mkdir(Map<String, dynamic> params) async {
    final String path = _requirePath(params, 'mkdir(path)');
    final FileScope scope = FileScope.parse(params['scope']);
    final String created = await _files.mkdir(appId, path, scope: scope);
    return <String, dynamic>{
      'path': created,
      'scope': scope.id,
      'created': true,
    };
  }

  Future<Map<String, dynamic>> exists(Map<String, dynamic> params) async {
    final String path = _string(params['path'], '.');
    final MiniappFileInfo info = await _files.fileInfo(
      appId,
      path,
      scope: FileScope.parse(params['scope']),
    );
    return <String, dynamic>{
      'path': info.path,
      'exists': info.exists,
      'isDirectory': info.isDirectory,
    };
  }

  Future<Map<String, dynamic>> fileInfo(Map<String, dynamic> params) async {
    final String path = _string(params['path'], '.');
    final MiniappFileInfo info = await _files.fileInfo(
      appId,
      path,
      scope: FileScope.parse(params['scope']),
    );
    return info.toJson();
  }

  // --------------------------------------------------------------- 下载

  /// 把 http(s) 文件保存到系统下载目录。
  ///
  /// 为什么不由宿主自己下载：Android 10 起写公共「下载」目录需要
  /// MANAGE_EXTERNAL_STORAGE 或 MediaStore，而这两条路都和本项目
  /// 「不申请管理所有文件」的原则冲突。系统 DownloadManager 代为落盘
  /// 不需要任何权限，还能在下完时给系统通知。
  ///
  /// 支持 fileName / filename（前者优先）；都不传就按 URL 推断。
  /// 不支持 blob: / data: —— 那类内容没有可供下载器拉取的地址，
  /// 页面应该自己把它转成 http(s) 链接再调这里。
  Future<Map<String, dynamic>> downloadSave(Map<String, dynamic> params) async {
    final String url = _string(params['url']).trim();
    if (url.isEmpty) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'download.save(url)：缺少 url',
      );
    }
    final String fileName = _string(
      params['fileName'],
      _string(params['filename']),
    ).trim();
    try {
      final DownloadTask task = await DownloadService.instance.enqueue(
        url: url,
        fileName: fileName.isEmpty ? null : fileName,
        mimeType: _string(params['mimeType']).trim().isEmpty
            ? null
            : _string(params['mimeType']).trim(),
      );
      return <String, dynamic>{
        'id': task.id,
        'fileName': task.fileName,
        'path': 'Download/${task.relativePath}',
        'status': task.status.id,
      };
    } on DownloadException catch (e) {
      throw LemonBridgeException(BridgeErrorCode.notSupported, e.message);
    }
  }

  /// 当前下载记录（按新→旧）。只读，管理动作留给宿主界面。
  Future<Map<String, dynamic>> downloadList() async {
    final List<DownloadTask> tasks = DownloadService.instance.tasks;
    return <String, dynamic>{
      'count': tasks.length,
      'directory': DownloadService.instance.directoryLabel,
      'tasks': tasks
          .map(
            (DownloadTask t) => <String, dynamic>{
              'id': t.id,
              'fileName': t.fileName,
              'path': t.relativePath,
              'url': t.url,
              'status': t.status.id,
              'bytesReceived': t.bytesReceived,
              'bytesTotal': t.bytesTotal,
              'reason': t.reason,
              'createdAt': t.createdAt.millisecondsSinceEpoch,
            },
          )
          .toList(growable: false),
    };
  }

  // --------------------------------------------------------------- 会话

  /// 主动转入后台运行（与悬浮菜单里的「后台运行」等价）。
  Future<Map<String, dynamic>> runInBackground() async {
    final Future<void> Function()? callback = onRunInBackground;
    if (callback == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.notSupported,
        'runInBackground：当前上下文没有可用的会话',
      );
    }
    await callback();
    return <String, dynamic>{'background': true};
  }

  /// 关闭当前小程序（销毁 WebView，不留后台会话）。
  Future<Map<String, dynamic>> closeMiniapp() async {
    final Future<void> Function()? callback = onCloseMiniapp;
    if (callback == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.notSupported,
        'close：当前上下文没有可用的会话',
      );
    }
    await callback();
    return <String, dynamic>{'closed': true};
  }

  // ---------------------------------------------------------------- WASM

  /// 列出**插件**提供的 WebAssembly 模块。
  ///
  /// 从 0.1.5 起 wasm 不再是宿主内置能力：宿主核心代码里没有模块清单、
  /// 没有 asset 路径，只有一个"按能力去问插件"的转发层。
  /// 没装插件时返回空 modules（`supported` 仍为 true —— WebView 本身支持 wasm，
  /// 只是暂时没有模块可用），小程序据此提示去装插件。
  Future<Map<String, dynamic>> wasmList() =>
      PluginService.instance.wasmListPayload();

  /// 读取模块字节（base64）。
  ///
  /// 为什么不返回数组：JSBridge 的返回值必须能 JSON 序列化，二进制过不去；
  /// base64 是唯一在所有 WebView 版本上都稳的编码。JS SDK 侧会解码成 Uint8Array
  /// 再交给 `WebAssembly.instantiate`，小程序不用自己处理编码。
  Future<Map<String, dynamic>> wasmRead(Map<String, dynamic> params) async {
    final List<PluginWasmEntry> entries = await PluginService.instance
        .wasmEntries();
    if (entries.isEmpty) {
      throw const LemonBridgeException(
        BridgeErrorCode.notSupported,
        'wasmRead：没有启用中的 WebAssembly 插件。请到「设置 → 插件」安装或启用它。',
      );
    }
    final String requested = _string(params['name']).trim();
    // 不传名字 = 第一个模块（与旧版本行为一致，方便 "就看一眼" 的调用）
    final String name = requested.isEmpty
        ? entries.first.module.name
        : requested;
    final bool known = entries.any(
      (PluginWasmEntry e) => e.module.name == name,
    );
    if (!known) {
      final String available = entries
          .map((PluginWasmEntry e) => e.module.name)
          .join(', ');
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'wasmRead(name)：没有名为「$name」的 wasm 模块（可用：$available）',
      );
    }
    try {
      return await PluginService.instance.wasmReadPayload(name);
    } on PluginUnavailableException catch (e) {
      throw LemonBridgeException(
        BridgeErrorCode.internal,
        'wasmRead：${e.message}',
      );
    }
  }

  // ---------------------------------------------------------------- 插件

  /// 当前设备上已安装/启用/平台匹配的插件总览。
  /// 小程序侧用来做能力探测：「这台设备上有没有 wasm」。
  Future<Map<String, dynamic>> pluginsList() =>
      PluginService.instance.summary();

  // --------------------------------------------------------- 模块方法

  /// 执行模块声明的方法。
  ///
  /// **为什么不执行模块自带的代码**：宿主是 Flutter，模块只能带 JS/CSS，
  /// 没有办法在 Dart 侧跑任意代码。于是把「新增能力」收敛成一组**声明式 action**，
  /// 由宿主用自己已有的实现去组合 —— 模块最多是换个 url、加个提示，
  /// 不可能借此拿到宿主没有的能力。这既是安全边界，也让权限一目了然。
  Future<Object?> _runModuleMethod(
    BundleBridgeMethod method,
    Map<String, dynamic> params,
  ) async {
    // manifest 里写死的参数在前，小程序调用时传的同名参数覆盖它
    final Map<String, dynamic> merged = <String, dynamic>{
      ...method.params,
      ...params,
    };

    switch (method.action) {
      case 'const':
        // 最简单的模块：直接返回一个常量，等于「把配置写进包里」
        return merged['value'] ?? <String, dynamic>{};

      case 'http.get':
      case 'http.post':
        final String url = _string(merged['url']);
        if (url.isEmpty) {
          throw LemonBridgeException(
            BridgeErrorCode.invalidArgument,
            '模块方法 ${method.name}：manifest.params.url 必填',
          );
        }
        final String defaultMethod = method.action == 'http.post'
            ? 'POST'
            : 'GET';
        return request(<String, dynamic>{
          ...merged,
          'url': url,
          'method': _string(merged['method'], defaultMethod).toUpperCase(),
        });

      case 'storage.get':
        return getStorage(<String, dynamic>{
          'key': _string(merged['key']),
          'defaultValue': merged['defaultValue'],
        });
      case 'storage.set':
        return setStorage(<String, dynamic>{
          'key': _string(merged['key']),
          'value': merged['value'],
        });
      case 'storage.remove':
        return removeStorage(<String, dynamic>{'key': _string(merged['key'])});
      case 'storage.clear':
        return clearStorage();
      case 'storage.keys':
        return getStorageKeys();

      case 'ui.toast':
        return showToast(<String, dynamic>{
          'message': _string(merged['message'], _string(merged['text'])),
        });
      case 'ui.setTitle':
        return setTitle(<String, dynamic>{'title': _string(merged['title'])});
      case 'shell.openUrl':
        return openUrl(<String, dynamic>{'url': _string(merged['url'])});

      default:
        throw LemonBridgeException(
          BridgeErrorCode.notSupported,
          '模块方法 ${method.name} 用了宿主不支持的 action：${method.action}',
        );
    }
  }

  // ------------------------------------------------------------ 工具

  String _requireKey(Map<String, dynamic> params, String api) {
    final String key = _string(params['key']);
    if (key.isEmpty) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        '$api：key 必须是非空字符串',
      );
    }
    return key;
  }

  /// 文件类 API 的 path 参数。空串视为「小程序根目录」，交给 service 去规范化。
  String _requirePath(Map<String, dynamic> params, String api) {
    if (!params.containsKey('path')) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        '$api：缺少 path',
      );
    }
    final String path = _string(params['path']);
    if (path.length > 512) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        '$api：path 过长（上限 512 字符）',
      );
    }
    return path;
  }

  /// encoding 参数：只认 utf8 / base64 两种，其它一律当 utf8（宽松但可预期）
  bool _isBase64(Map<String, dynamic> params) =>
      _string(params['encoding']).toLowerCase() == 'base64';

  static String _string(Object? value, [String fallback = '']) {
    if (value == null) return fallback;
    if (value is String) return value;
    return value.toString();
  }

  /// 宽松布尔解析。小程序侧经常传 `'true'` / 1 / `'0'`，一律认。
  static bool _bool(Object? value, {bool fallback = false}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final String text = value.toString().trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes' || text == 'on') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
      return false;
    }
    return fallback;
  }

  static double? _doubleOrNull(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().trim());
  }

  static int _int(Object? value, int fallback) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static Map<String, dynamic>? _map(Object? value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    }
    return null;
  }

  static double _round2(double value) => double.parse(value.toStringAsFixed(2));
}

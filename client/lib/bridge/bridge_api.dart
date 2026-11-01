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

import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/builtin_wasm.dart';
import '../core/globals.dart';
import '../core/native_bridge.dart';
import '../data/models/bundle_manifest.dart';
import '../data/models/miniapp_session.dart';
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

  /// 40001 曾用于「权限被拒绝」。
  ///
  /// **这一版不再由桥接层返回它**：权限管的是浏览器受控资源，
  /// 网页被拒绝时拿到的是 Chromium 自己的 DOMException（NotAllowedError），
  /// 不会走到 JSBridge。保留这个常量是为了不改变已发布的错误码含义
  /// （小程序里可能有 `err.code === 40001` 的判断，贸然删除会让那些
  /// 判断变成 undefined 比较），但它现在是**只读的兼容值**，不再抛出。
  @Deprecated('权限拒绝不再经由 JSBridge 返回，网页会收到 DOMException')
  static const int permissionDenied = 40001;

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
    this.session,
    this.storageService,
    this.onRunInBackground,
    this.onCloseMiniapp,
    this.moduleMethods = const <String, BundleBridgeMethod>{},
  });

  /// 当前小程序的 id（storage 命名空间、权限授权、文件沙箱都用它隔离）
  final String appId;

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
  /// **这里没有权限闸门**，这是有意的：本框架的权限管的是**浏览器的**
  /// 受控资源（摄像头 / 麦克风 / 文件系统访问），它们由网页自己通过
  /// `getUserMedia()` 等 Web API 发起，拦截点在 WebView 的
  /// `onPermissionRequest` 上（见 bridge/web_permission.dart）。
  ///
  /// 桥接层的这些方法不碰受控资源：
  ///   * 网络 / 存储 / 文件沙箱 —— 只作用于小程序自己的命名空间与沙箱目录；
  ///   * 音量 / 亮度 / 屏幕方向 / 常亮 —— Android 本来就不禁止应用自行调整。
  /// 把它们也做成「权限」只会让真正的风险项淹没在一堆没有意义的开关里。
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

      // ---- 会话 ----
      case 'runInBackground':
        return await runInBackground();
      case 'close':
        return await closeMiniapp();

      // ---- 内置 WASM ----
      case 'wasmList':
        return await wasmList();
      case 'wasmRead':
        return await wasmRead(params);

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
  Future<Map<String, dynamic>> getTheme() async => themeController.themeSnapshot();

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
      throw const LemonBridgeException(BridgeErrorCode.invalidArgument, 'showToast：message 不能为空');
    }
    final String type = _string(params['type'], 'info');
    final int durationMs = _int(params['duration'], 2000).clamp(500, 10000).toInt();

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
      throw const LemonBridgeException(BridgeErrorCode.invalidArgument, 'openUrl：url 必填');
    }
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) {
      throw const LemonBridgeException(BridgeErrorCode.invalidArgument, 'openUrl：url 不是合法地址');
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
      final bool opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw const LemonBridgeException(BridgeErrorCode.internal, 'openUrl：没有可打开该链接的应用');
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
      throw const LemonBridgeException(BridgeErrorCode.invalidArgument, 'request：url 必须是绝对地址');
    }
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw LemonBridgeException(BridgeErrorCode.notSupported, 'request：仅支持 http/https，收到 $scheme');
    }

    final String method = _string(params['method'], 'GET').toUpperCase();
    final Map<String, dynamic>? headers = _map(params['headers']);
    final Map<String, dynamic>? query = _map(params['params']);
    final Object? data = params['data'];
    final int timeoutMs = _int(params['timeout'], 15000).clamp(1000, 60000).toInt();

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
          (String key, List<String> value) => MapEntry<String, String>(key, value.join(', ')),
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
    final bool looksLikeJson = trimmed.startsWith('{') || trimmed.startsWith('[');
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
      throw LemonBridgeException(BridgeErrorCode.invalidArgument, 'setStorage：value 无法序列化（$e）');
    }
    if (encoded.length > _maxStorageBytes) {
      throw const LemonBridgeException(BridgeErrorCode.storage, 'setStorage：单个键值不能超过 512KB');
    }

    final bool ok = await SettingsService.instance
        .writeRaw(SettingsService.miniappStorageKey(appId, key), encoded);
    if (!ok) {
      throw const LemonBridgeException(BridgeErrorCode.storage, 'setStorage：写入失败');
    }
    return <String, dynamic>{'key': key, 'bytes': encoded.length};
  }

  Future<Map<String, dynamic>> getStorage(Map<String, dynamic> params) async {
    final String key = _requireKey(params, 'getStorage(key)');
    final String? raw =
        SettingsService.instance.readRaw(SettingsService.miniappStorageKey(appId, key));

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

  Future<Map<String, dynamic>> removeStorage(Map<String, dynamic> params) async {
    final String key = _requireKey(params, 'removeStorage(key)');
    final bool ok = await SettingsService.instance
        .removeRaw(SettingsService.miniappStorageKey(appId, key));
    return <String, dynamic>{'key': key, 'removed': ok};
  }

  Future<Map<String, dynamic>> clearStorage() async {
    final List<String> keys = SettingsService.instance.miniappStorageKeys(appId);
    for (final String key in keys) {
      await SettingsService.instance.removeRaw(SettingsService.miniappStorageKey(appId, key));
    }
    return <String, dynamic>{'cleared': keys.length};
  }

  Future<Map<String, dynamic>> getStorageKeys() async => <String, dynamic>{
        'keys': SettingsService.instance.miniappStorageKeys(appId),
      };

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
    final Object? raw = params['percent'] ?? params['value'] ?? params['volume'];
    final double? percent = _doubleOrNull(raw);
    if (percent == null) {
      throw const LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'setVolume(percent)：percent 必须是 0~1 的数字',
      );
    }
    final VolumeInfo? info = await NativeBridge.setVolume(percent.clamp(0.0, 1.0));
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
  Future<Map<String, dynamic>> setBrightness(Map<String, dynamic> params) async {
    final Object? raw = params['value'] ?? params['brightness'] ?? params['percent'];
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
  Future<Map<String, dynamic>> getAppFileDir(Map<String, dynamic> params) async {
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
    final List<MiniappFileEntry> entries =
        await _files.listFiles(appId, path, scope: scope);
    return <String, dynamic>{
      'path': _files.normalizeRelativePath(path),
      'scope': scope.id,
      'count': entries.length,
      'entries': entries.map((MiniappFileEntry e) => e.toJson()).toList(growable: false),
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

  /// 列出随宿主内置的 WebAssembly 模块。
  Future<Map<String, dynamic>> wasmList() async {
    final List<Map<String, dynamic>> modules = <Map<String, dynamic>>[];
    for (final BuiltinWasmModule module in kBuiltinWasmModules) {
      final Object? bytes = await BuiltinWasm.bytes(module.name);
      modules.add(<String, dynamic>{
        'name': module.name,
        'description': module.description,
        'bytes': bytes is List<int> ? bytes.length : 0,
        'exports': module.exports,
        'hasMemory': module.hasMemory,
      });
    }
    return <String, dynamic>{
      'modules': modules,
      'count': modules.length,
      // WebAssembly 由 WebView 提供（Chromium 57+ 起内置），这里表示框架已经接好
      'supported': true,
    };
  }

  /// 读取内置模块的字节（base64）。
  ///
  /// 为什么不返回数组：JSBridge 的返回值必须能 JSON 序列化，二进制过不去；
  /// base64 是唯一在所有 WebView 版本上都稳的编码。JS SDK 侧会解码成 Uint8Array
  /// 再交给 `WebAssembly.instantiate`，小程序不用自己处理编码。
  Future<Map<String, dynamic>> wasmRead(Map<String, dynamic> params) async {
    final String name = _string(
      params['name'],
      kBuiltinWasmModules.isEmpty ? '' : kBuiltinWasmModules.first.name,
    );
    final BuiltinWasmModule? module = BuiltinWasm.byName(name);
    if (module == null) {
      throw LemonBridgeException(
        BridgeErrorCode.invalidArgument,
        'wasmRead(name)：没有名为「$name」的内置模块（可用：${BuiltinWasm.names.join(", ")}）',
      );
    }
    final Object? bytes = await BuiltinWasm.bytes(name);
    if (bytes is! List<int>) {
      throw LemonBridgeException(
        BridgeErrorCode.internal,
        'wasmRead：内置模块 ${module.name} 读取失败（asset 可能没打进包）',
      );
    }
    return <String, dynamic>{
      'name': module.name,
      'description': module.description,
      'bytes': bytes.length,
      'base64': base64Encode(bytes),
      'exports': module.exports,
      'hasMemory': module.hasMemory,
    };
  }

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
    final Map<String, dynamic> merged = <String, dynamic>{...method.params, ...params};

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
        final String defaultMethod = method.action == 'http.post' ? 'POST' : 'GET';
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
      throw LemonBridgeException(BridgeErrorCode.invalidArgument, '$api：key 必须是非空字符串');
    }
    return key;
  }

  /// 文件类 API 的 path 参数。空串视为「小程序根目录」，交给 service 去规范化。
  String _requirePath(Map<String, dynamic> params, String api) {
    if (!params.containsKey('path')) {
      throw LemonBridgeException(BridgeErrorCode.invalidArgument, '$api：缺少 path');
    }
    final String path = _string(params['path']);
    if (path.length > 512) {
      throw LemonBridgeException(BridgeErrorCode.invalidArgument, '$api：path 过长（上限 512 字符）');
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
    if (text == 'true' || text == '1' || text == 'yes' || text == 'on') return true;
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') return false;
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

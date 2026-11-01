// lib/data/services/account_service.dart
//
// 账号状态中心：验证码 / 登录 / 注册 / 资料 / 会话 / 头像。
//
// **未登录是合法状态**：市场浏览、小程序运行、权限管理、存储管理全都不需要登录。
// 所以这里没有「未登录就跳登录页」的逻辑，只有 `isLoggedIn` 这一个查询位，
// 需要账号的功能自己去判断。首页/设置页也不会因为未登录而变样。
//
// token 的持久化在 SettingsService 之外的独立 key（`account.token`）：
// 它不属于「用户偏好」，混淆在一起会让「重置设置」意外把人踢下线。

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/globals.dart';
import 'settings_service.dart';

/// 登录后的用户资料（与服务端 /api/auth/me 的返回一一对应）
@immutable
class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.username,
    required this.email,
    this.avatarUrl = '',
    this.avatarVersion = '',
    this.createdAt,
    this.createdIp = '',
    this.updatedAt,
  });

  final int id;
  final String username;
  final String email;

  /// 可下载的头像绝对地址；空串表示没有头像（用用户名首字占位）
  final String avatarUrl;

  /// 版本戳：变了说明头像换了，客户端应重新下载
  final String avatarVersion;

  final String? createdAt;
  final String createdIp;
  final String? updatedAt;

  bool get hasAvatar => avatarUrl.trim().isNotEmpty;

  /// 头像占位图用：取用户名第一个「字」。
  ///
  /// 用 `runes.first` 而不是 `substring(0,1)`：后者会把 emoji 或
  /// 代理对字符切成半个码元，渲染出豆腐块。
  String get initial {
    final String name = username.trim();
    if (name.isEmpty) return '?';
    return String.fromCharCode(name.runes.first);
  }

  factory AccountProfile.fromJson(Map<String, dynamic> json) => AccountProfile(
    id: (json['id'] as num?)?.toInt() ?? 0,
    username: (json['username'] ?? '').toString(),
    email: (json['email'] ?? '').toString(),
    avatarUrl: (json['avatarUrl'] ?? '').toString(),
    avatarVersion: (json['avatarVersion'] ?? '').toString(),
    createdAt: json['createdAt']?.toString(),
    createdIp: (json['createdIp'] ?? '').toString(),
    updatedAt: json['updatedAt']?.toString(),
  );

  AccountProfile copyWith({
    String? username,
    String? email,
    String? avatarUrl,
    String? avatarVersion,
  }) => AccountProfile(
    id: id,
    username: username ?? this.username,
    email: email ?? this.email,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    avatarVersion: avatarVersion ?? this.avatarVersion,
    createdAt: createdAt,
    createdIp: createdIp,
    updatedAt: updatedAt,
  );
}

/// 一次「发送验证码」的结果。
///
/// 冷却时间由**服务端**给，客户端不写死 60 秒：
/// 两边各写一份的话，只要有一边改动，用户就会遇到「倒计时走完了，
/// 点一下却提示 60 秒后再试」这种说不清的体验。
@immutable
class EmailCodeSent {
  const EmailCodeSent({
    required this.email,
    this.cooldown = 60,
    this.expiresIn = 600,
    this.driver = '',
    this.debugCode,
  });

  final String email;

  /// 多少秒之后才允许重发
  final int cooldown;

  /// 验证码有效期（秒）
  final int expiresIn;

  /// 服务端用的邮件通道（smtp / resend / ...），只用于排查问题
  final String driver;

  /// 仅当服务端开了 MAIL_DEV_ECHO_CODE 才有值：直接把码填进输入框，
  /// 省得开发时每次都要去翻日志
  final String? debugCode;

  factory EmailCodeSent.fromJson(Map<String, dynamic> json) => EmailCodeSent(
    email: (json['email'] ?? '').toString(),
    cooldown: (json['cooldown'] as num?)?.toInt() ?? 60,
    expiresIn: (json['expiresIn'] as num?)?.toInt() ?? 600,
    driver: (json['driver'] ?? '').toString(),
    debugCode: (json['debugCode'] ?? '').toString().isEmpty
        ? null
        : json['debugCode'].toString(),
  );
}

/// 一次登录会话（「我的登录设备」里的一行）
@immutable
class AccountSession {
  const AccountSession({
    required this.id,
    required this.current,
    this.createdAt = '',
    this.lastSeenAt = '',
    this.ip = '',
    this.device = '',
  });

  /// 服务端给的不透明句柄（token 前 16 位），用于撤销这一条
  final String id;
  final bool current;
  final String createdAt;
  final String lastSeenAt;
  final String ip;
  final String device;

  factory AccountSession.fromJson(Map<String, dynamic> json) => AccountSession(
    id: (json['id'] ?? '').toString(),
    current: json['current'] == true,
    createdAt: (json['createdAt'] ?? '').toString(),
    lastSeenAt: (json['lastSeenAt'] ?? '').toString(),
    ip: (json['ip'] ?? '').toString(),
    device: (json['device'] ?? '').toString(),
  );
}

/// 账号操作的统一错误（code 来自服务端，UI 据此定位到具体输入框）
class AccountException implements Exception {
  const AccountException(this.code, this.message);

  final String code;
  final String message;

  /// 这些错误应该提示在「用户名」输入框旁边
  bool get isUsernameError =>
      code == 'username_taken' || code == 'invalid_username';

  /// 提示在「邮箱」输入框旁边
  bool get isEmailError => code == 'email_taken' || code == 'invalid_email';

  /// 提示在「验证码」输入框旁边
  bool get isCodeError =>
      code == 'invalid_code' ||
      code == 'code_expired' ||
      code == 'code_missing' ||
      code == 'code_required' ||
      code == 'code_locked';

  /// 提示在「密码」输入框旁边
  bool get isPasswordError =>
      code == 'weak_password' ||
      code == 'invalid_password' ||
      code == 'wrong_password' ||
      code == 'same_password';

  @override
  String toString() => 'AccountException($code): $message';
}

/// 邮箱格式判定的单一来源：注册页、发验证码、登录页都用它。
///
/// 与服务端 validateEmail 保持一致（宽松但够用：有本地部分、有 @、域名有点）。
final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

class AccountService extends ChangeNotifier {
  AccountService._();

  static final AccountService instance = AccountService._();

  static const String _kToken = 'account.token';

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (int? status) => status != null && status < 500,
    ),
  );

  SettingsService? _settings;

  /// 当前 token（null = 未登录）
  String? _token;

  /// 当前用户资料（null = 未登录或还在加载）
  AccountProfile? _profile;

  /// 是否正在做账号相关请求（登录/注册/改资料）
  bool _busy = false;

  /// 上一次错误（UI 用，取完可以不清）
  AccountException? _lastError;

  String? get token => _token;
  AccountProfile? get profile => _profile;
  bool get isLoggedIn => _token != null && _token!.isNotEmpty;
  bool get busy => _busy;
  AccountException? get lastError => _lastError;

  /// 启动时调用：从本地拿 token，`withProfile: true` 时顺便校验它还有效。
  ///
  /// 为什么校验要单独一个开关：启动阶段网络可能还没好，
  /// 没网就不该让 App 卡在「正在校验登录态」上。所以先本地认定「已登录」，
  /// 后台再静默校验；校验失败（401）才清掉 token。
  Future<void> init(SettingsService settings, {bool withProfile = false}) async {
    _settings = settings;
    _token = settings.readRaw(_kToken);
    if (!isLoggedIn) {
      _token = null;
      return;
    }
    if (withProfile) {
      // 静默校验：失败只清 token，不抛给 UI
      unawaited(refreshProfile(silent: true));
    }
  }

  /// 服务端地址（跟随设置页里的市场服务器地址）
  String get _base => (_settings?.serverUrl ?? kDefaultServerUrl).trim();

  // ---------------------------------------------------------------- 请求封装

  /// 发一个账号相关请求，把服务端的 `{ok, data, error}` 转成结果或异常。
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    final String url = '$_base$path';
    try {
      final Response<dynamic> res = await _dio.request<dynamic>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: <String, String>{
            'Content-Type': 'application/json',
            if (auth && isLoggedIn) 'Authorization': 'Bearer $_token',
          },
          // 自己处理状态码，才能把服务端的 error 对象读出来
          validateStatus: (int? status) => status != null,
        ),
      );

      final Object? raw = res.data;
      final Map<String, dynamic>? json = raw is Map
          ? raw.map<String, dynamic>(
              (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
            )
          : null;

      if (json == null) {
        throw const AccountException('bad_response', '服务器返回了无法识别的内容');
      }

      if (json['ok'] == true) {
        final Object? data = json['data'];
        return data is Map
            ? data.map<String, dynamic>(
                (Object? k, Object? v) =>
                    MapEntry<String, dynamic>(k.toString(), v),
              )
            : <String, dynamic>{'value': data};
      }

      // 服务端明确报错
      final Object? err = json['error'];
      if (err is Map) {
        throw AccountException(
          (err['code'] ?? 'unknown').toString(),
          (err['message'] ?? '操作失败').toString(),
        );
      }
      throw AccountException('http_${res.statusCode}', '服务器返回 ${res.statusCode}');
    } on DioException catch (e) {
      throw AccountException('network', _describeDio(e));
    }
  }

  String _describeDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '连接超时，请检查网络或服务器地址';
      case DioExceptionType.badCertificate:
        return '服务器证书校验失败';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络设置';
      case DioExceptionType.badResponse:
        return '服务器返回异常（${e.response?.statusCode}）';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.unknown:
        return '网络请求失败：${e.message ?? '未知原因'}';
    }
  }

  // ---------------------------------------------------------------- 登录/注册

  /// 登录。account 可以是用户名或邮箱。
  ///
  /// [device] 会作为「设备」记进服务端的 login_sessions，
  /// 用户在「我的登录设备」里能据此认出是哪台机器。
  Future<void> login({
    required String account,
    required String password,
    String? device,
  }) async {
    final String accountText = account.trim();
    if (accountText.isEmpty) {
      throw const AccountException('bad_request', '请输入用户名或邮箱');
    }
    if (password.isEmpty) {
      throw const AccountException('bad_request', '请输入密码');
    }

    await _guard(() async {
      final Map<String, dynamic> data = await _request(
        'POST',
        '/api/auth/login',
        body: <String, dynamic>{
          'account': accountText,
          'password': password,
          if (device != null && device.isNotEmpty) 'device': device,
        },
        auth: false,
      );
      await _applyAuth(data);
    });
  }

  /// 注册。成功后直接是登录态（服务端会一并返回 token）。
  ///
  /// [code] 是邮箱收到的验证码，服务端会核销它 —— 没有它注册接口直接拒绝。
  Future<void> register({
    required String username,
    required String email,
    required String password,
    required String code,
    String? device,
  }) async {
    await _guard(() async {
      final Map<String, dynamic> data = await _request(
        'POST',
        '/api/auth/register',
        body: <String, dynamic>{
          'username': username.trim(),
          'email': email.trim(),
          'password': password,
          'code': code.trim(),
          if (device != null && device.isNotEmpty) 'device': device,
        },
        auth: false,
      );
      await _applyAuth(data);
    });
  }

  /// 让服务端给这个邮箱发一封验证码邮件。
  ///
  /// 发信是慢操作（SMTP 握手 + 投递可能几秒），所以不套 `_guard`：
  /// 它不该把整个账号页的 busy 状态点亮，注册页自己管理按钮状态即可。
  Future<EmailCodeSent> sendEmailCode({required String email}) async {
    final String target = email.trim();
    if (!_emailPattern.hasMatch(target)) {
      throw const AccountException('invalid_email', '邮箱格式不正确');
    }
    final Map<String, dynamic> data = await _request(
      'POST',
      '/api/auth/email-code',
      body: <String, dynamic>{'email': target, 'purpose': 'register'},
      auth: false,
    );
    return EmailCodeSent.fromJson(data);
  }

  /// 退出登录（只撤销当前会话）
  Future<void> logout() async {
    await _guard(() async {
      try {
        await _request('POST', '/api/auth/logout');
      } on AccountException catch (e) {
        // 网络不通时也要能退出本地登录态 —— 否则用户会卡在
        // 「退不出去」的状态里，而服务端那条会话到期后自然消失。
        lemonLog('Account', '退出登录请求失败，仍清本地状态：${e.message}');
      }
      await _clearAuth();
    });
  }

  /// 退出所有设备
  Future<void> logoutAll() async {
    await _guard(() async {
      try {
        await _request('POST', '/api/auth/logout-all');
      } on AccountException catch (e) {
        lemonLog('Account', '退出所有设备失败：${e.message}');
      }
      await _clearAuth();
    });
  }

  // ---------------------------------------------------------------- 资料

  /// 刷新资料。silent=true 时失败不抛（用于启动时的静默校验）。
  Future<void> refreshProfile({bool silent = false}) async {
    if (!isLoggedIn) return;
    try {
      final Map<String, dynamic> data = await _request('GET', '/api/auth/me');
      _profile = AccountProfile.fromJson(data);
      notifyListeners();
    } on AccountException catch (e) {
      // 401 = token 已失效（被撤销 / 过期 / 密码改了）：清掉本地状态。
      // 其它错误（网络）不该把用户踢下线 —— 那会让「飞机上打开 App」
      // 变成「突然未登录」。
      final bool expired = e.code == 'unauthorized';
      if (expired) {
        await _clearAuth();
      }
      if (!silent) rethrow;
    }
  }

  /// 改用户名 / 邮箱
  Future<void> updateProfile({String? username, String? email}) async {
    final Map<String, dynamic> body = <String, dynamic>{
      if (username != null) 'username': username.trim(),
      if (email != null) 'email': email.trim(),
    };
    if (body.isEmpty) return;

    await _guard(() async {
      final Map<String, dynamic> data = await _request(
        'PATCH',
        '/api/auth/me',
        body: body,
      );
      final Object? user = data['user'];
      if (user is Map) {
        _profile = AccountProfile.fromJson(
          user.map<String, dynamic>(
            (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
      }
    });
  }

  /// 改密码。成功后服务端会撤销其它会话（当前会话保留）。
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    await _guard(() async {
      await _request(
        'POST',
        '/api/auth/password',
        body: <String, dynamic>{
          'oldPassword': oldPassword,
          'newPassword': newPassword,
        },
      );
    });
  }

  /// 检查用户名 / 邮箱是否可用（注册页边输入边提示）
  Future<bool> checkUsername(String username) async {
    try {
      final Map<String, dynamic> data = await _request(
        'GET',
        '/api/auth/check?username=${Uri.encodeQueryComponent(username)}',
        auth: false,
      );
      final Object? entry = data['username'];
      if (entry is Map) return entry['available'] == true;
      return true;
    } catch (_) {
      // 检查失败不该阻止用户提交（服务端还会再校验一次）
      return true;
    }
  }

  // ---------------------------------------------------------------- 会话

  /// 我的登录设备
  Future<List<AccountSession>> fetchSessions() async {
    final Map<String, dynamic> data = await _request('GET', '/api/auth/sessions');
    // 服务端返回的是数组，_request 会包成 {value: [...]}
    final Object? list = data['value'];
    if (list is! List) return const <AccountSession>[];
    return list
        .whereType<Map>()
        .map(
          (Map m) => AccountSession.fromJson(
            m.map<String, dynamic>(
              (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
            ),
          ),
        )
        .toList(growable: false);
  }

  /// 撤销某个设备
  Future<void> revokeSession(String id) async {
    await _request('DELETE', '/api/auth/sessions/$id');
  }

  // ---------------------------------------------------------------- 头像

  /// 下载头像字节。
  ///
  /// 不走 Dio 的 JSON 通道：这里要的是**二进制**。
  /// 返回 null 表示没有头像（404）—— 调用方据此画占位图，
  /// 不要把「没有头像」当成错误。
  Future<Uint8List?> downloadAvatar({String? url}) async {
    final String target = url ?? _profile?.avatarUrl ?? '';
    if (target.isEmpty) return null;
    try {
      final Response<List<int>> res = await _dio.get<List<int>>(
        target,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (int? s) => s != null,
        ),
      );
      if (res.statusCode == 404 || res.data == null) return null;
      if (res.statusCode != 200) return null;
      return Uint8List.fromList(res.data!);
    } on DioException catch (e) {
      lemonLog('Account', '下载头像失败：${_describeDio(e)}');
      return null;
    }
  }

  /// 上传头像（PNG 字节）。
  ///
  /// 裁剪在客户端做（见 pages/account/avatar_cropper.dart），
  /// 服务端只校验格式与大小。
  Future<void> uploadAvatar(Uint8List pngBytes) async {
    if (!isLoggedIn) {
      throw const AccountException('unauthorized', '请先登录');
    }
    await _guard(() async {
      final FormData form = FormData.fromMap(<String, dynamic>{
        'file': MultipartFile.fromBytes(
          pngBytes,
          filename: 'avatar.png',
          contentType: DioMediaType('image', 'png'),
        ),
      });

      final Response<dynamic> res = await _dio.post<dynamic>(
        '$_base/api/upload/avatar',
        data: form,
        options: Options(
          headers: <String, String>{'Authorization': 'Bearer $_token'},
          validateStatus: (int? s) => s != null,
        ),
      );

      final Object? raw = res.data;
      final Map<String, dynamic>? json = raw is Map
          ? raw.map<String, dynamic>(
              (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
            )
          : null;
      if (json == null || json['ok'] != true) {
        final Object? err = json?['error'];
        throw AccountException(
          (err is Map ? err['code'] : null)?.toString() ?? 'upload_failed',
          (err is Map ? err['message'] : null)?.toString() ?? '头像上传失败',
        );
      }

      final Object? data = json['data'];
      if (data is Map) {
        _profile = _profile?.copyWith(
          avatarUrl: (data['avatarUrl'] ?? '').toString(),
          avatarVersion: (data['avatarVersion'] ?? '').toString(),
        );
      }
    });
  }

  /// 删除头像
  Future<void> deleteAvatar() async {
    await _guard(() async {
      await _request('DELETE', '/api/upload/avatar');
      _profile = _profile?.copyWith(avatarUrl: '', avatarVersion: '');
    });
  }

  // ---------------------------------------------------------------- 用户 JSON

  /// 读服务端保存的用户 JSON（`userdata/<id>/data.json`）
  Future<Map<String, dynamic>> fetchUserData() async {
    final Map<String, dynamic> data = await _request('GET', '/api/user/data');
    final Object? inner = data['data'];
    if (inner is Map) {
      return inner.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    }
    return <String, dynamic>{};
  }

  /// 覆盖写入用户 JSON
  Future<void> putUserData(Map<String, dynamic> data) async {
    await _request('PUT', '/api/user/data', body: data);
  }

  /// 浅合并用户 JSON
  Future<Map<String, dynamic>> patchUserData(Map<String, dynamic> patch) async {
    final Map<String, dynamic> data = await _request(
      'PATCH',
      '/api/user/data',
      body: patch,
    );
    final Object? inner = data['data'];
    if (inner is Map) {
      return inner.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    }
    return <String, dynamic>{};
  }

  // ---------------------------------------------------------------- 内部

  /// 统一包一层：设 busy、捕异常、转成 AccountException
  Future<void> _guard(Future<void> Function() action) async {
    _busy = true;
    _lastError = null;
    notifyListeners();
    try {
      await action();
    } on AccountException catch (e) {
      _lastError = e;
      rethrow;
    } catch (e) {
      final AccountException wrapped = AccountException('unknown', '操作失败：$e');
      _lastError = wrapped;
      throw wrapped;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 保存 token 与用户资料
  Future<void> _applyAuth(Map<String, dynamic> data) async {
    final String token = (data['token'] ?? '').toString();
    if (token.isEmpty) {
      throw const AccountException('bad_response', '服务器没有返回登录凭证');
    }
    _token = token;
    await _settings?.writeRaw(_kToken, token);

    final Object? user = data['user'];
    if (user is Map) {
      _profile = AccountProfile.fromJson(
        user.map<String, dynamic>(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        ),
      );
    }
    notifyListeners();
  }

  Future<void> _clearAuth() async {
    _token = null;
    _profile = null;
    await _settings?.removeMany(<String>[_kToken]);
    notifyListeners();
  }

  /// 设备标识：登录时上报给服务端，用于「我的登录设备」。
  ///
  /// 只取平台与是否真机这种粗粒度信息 —— 不做设备指纹
  ///（那是另一件事，且涉及隐私）。
  static String describeDevice() {
    if (kIsWeb) return 'Web';
    try {
      if (Platform.isAndroid) {
        // 具体型号要从 device_info_plus 拿，但那会引入异步依赖。
        // 登录是高频路径，不值得为了一行展示文案多等一次平台通道。
        return 'Android 设备';
      }
      if (Platform.isIOS) return 'iOS 设备';
      return Platform.operatingSystem;
    } catch (_) {
      return '未知设备';
    }
  }
}

// lib/data/repositories/market_repository.dart
//
// 远端应用市场数据源（**只走 LemonLite 服务端**）。
//
// 两个接口：
//   GET /api/market/feed     主页推荐（游标分段加载）
//   GET /api/market/search   搜索（关键词 + 标签）
//
// 0.4 之前还支持「静态部署」——拉 `{server}/index.json` 全量解析。
// **0.5 起移除了那条路**：两套后端意味着两套分页语义、两套错误处理、
// 两套搜索实现（一个在服务端、一个在本地），维护成本远大于它带来的便利。
// 现在只有一个后端，所以这里没有任何「探测 → 分支」的逻辑。
//
// 服务器地址**每次请求都从 SettingsService 实时读取**，
// 所以开发者在设置页改完地址后，下一次刷新立刻生效。

import 'package:dio/dio.dart';

import '../../core/globals.dart';

import '../models/json_utils.dart';
import '../models/market_feed.dart';
import '../services/miniapp_package_service.dart';
import '../services/settings_service.dart';

/// 统一的市场错误：`code` 给程序判断，`message` 给用户看，`detail` 给开发者看。
class MarketException implements Exception {
  const MarketException(this.code, this.message, {this.detail});

  final String code;
  final String message;
  final String? detail;

  @override
  String toString() => 'MarketException($code): $message${detail == null ? '' : ' | $detail'}';
}

class MarketRepository {
  MarketRepository({Dio? dio, SettingsService? settings})
      : _settings = settings ?? SettingsService.instance,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: _defaultTimeout,
                receiveTimeout: _defaultTimeout,
                sendTimeout: _defaultTimeout,
                headers: <String, String>{'Accept': 'application/json'},
                // 自己控制状态码，便于把 404 / 500 翻译成不同提示
                validateStatus: (int? status) =>
                    status != null && status >= 200 && status < 400,
              ),
            );

  static const Duration _defaultTimeout = Duration(seconds: 12);

  final Dio _dio;
  final SettingsService _settings;

  /// 把非 Map 的响应体压成一行短描述，用于错误详情与日志。
  ///
  /// 长度上限 200：错误详情会显示在界面上，太长反而看不清；
  /// 完整内容在运行日志里（用户可导出）。
  static String _describeBody(Object? raw) {
    if (raw == null) return '(空)';
    final String text = raw is String ? raw : raw.toString();
    final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '(空)';
    return flat.length <= 200 ? flat : '${flat.substring(0, 200)}…';
  }

  /// 当前生效的 feed 接口地址（开发者页展示用）
  String get feedUrl => '${_settings.serverUrl}/api/market/feed';

  /// 解析 `{ok, data, meta}` 并转成异常
  ///
  /// 解析失败时会把「实际收到了什么」写进 detail 与运行日志 ——
  /// 一句「不是 JSON 对象」对排查毫无帮助（服务端明明返回了合法 JSON
  /// 的情况就卡在这里）。现在能看到状态码、Content-Type 与响应片段。
  Map<String, dynamic> _unwrap(Response<dynamic> res, String path) {
    final Object? raw = res.data;
    if (raw is! Map) {
      final String contentType =
          res.headers.value(Headers.contentTypeHeader) ?? '(无)';
      final String snippet = _describeBody(raw);
      lemonLogError(
        'Market',
        '响应不是 JSON 对象：$path · HTTP ${res.statusCode}'
        ' · Content-Type: $contentType · 内容：$snippet',
      );
      throw MarketException(
        'bad_response',
        '服务器返回了无法识别的内容',
        detail: '$path 返回 HTTP ${res.statusCode}'
            '（Content-Type: $contentType），内容片段：$snippet',
      );
    }
    final Map<String, dynamic> json = raw.map<String, dynamic>(
      (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
    );
    if (json['ok'] == true) return json;
    final Object? err = json['error'];
    if (err is Map) {
      throw MarketException(
        (err['code'] ?? 'api_error').toString(),
        (err['message'] ?? '服务器返回错误').toString(),
        detail: path,
      );
    }
    throw MarketException('api_error', '服务器返回错误', detail: path);
  }

  /// 主页推荐（分段加载）
  ///
  /// [cursor] 传上一页返回的 nextCursor；null 表示从第一页开始。
  /// [category] 传分类 id，'' 或 'all' 表示全部。
  Future<MarketFeedPage> fetchFeed({
    int limit = 20,
    String? cursor,
    String category = '',
  }) async {
    final String base = _settings.serverUrl;
    final StringBuffer url = StringBuffer('$base/api/market/feed?limit=$limit');
    if (cursor != null && cursor.isNotEmpty) {
      url.write('&cursor=${Uri.encodeQueryComponent(cursor)}');
    }
    if (category.isNotEmpty && category != 'all') {
      url.write('&category=${Uri.encodeQueryComponent(category)}');
    }

    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url.toString(),
        options: Options(validateStatus: (int? s) => s != null),
      );
      if (res.statusCode != 200) {
        throw _httpError(res.statusCode, url.toString());
      }
      final Map<String, dynamic> json = _unwrap(res, url.toString());
      final Map<String, dynamic> data =
          asMap(json['data']) ?? <String, dynamic>{};
      final Map<String, dynamic> meta =
          asMap(json['meta']) ?? <String, dynamic>{};
      await _settings.setLastSyncAt(DateTime.now());
      return MarketFeedPage.fromJson(data, meta, base);
    } on DioException catch (e) {
      throw _mapDioException(e, base);
    }
  }

  /// 搜索
  ///
  /// [query] 关键词（可为空）；[tag] 标签 slug（可为空）；
  /// [offset] 分页偏移（搜索结果量级小，用 offset 便于「跳到下一页」）。
  Future<MarketSearchPage> search({
    String query = '',
    String tag = '',
    String category = '',
    int limit = 20,
    int offset = 0,
  }) async {
    final String base = _settings.serverUrl;
    final StringBuffer url = StringBuffer(
      '$base/api/market/search?limit=$limit&offset=$offset',
    );
    if (query.trim().isNotEmpty) {
      url.write('&q=${Uri.encodeQueryComponent(query.trim())}');
    }
    if (tag.trim().isNotEmpty) {
      url.write('&tag=${Uri.encodeQueryComponent(tag.trim())}');
    }
    if (category.isNotEmpty && category != 'all') {
      url.write('&category=${Uri.encodeQueryComponent(category)}');
    }

    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        url.toString(),
        options: Options(validateStatus: (int? s) => s != null),
      );
      if (res.statusCode != 200) {
        throw _httpError(res.statusCode, url.toString());
      }
      final Map<String, dynamic> json = _unwrap(res, url.toString());
      final Map<String, dynamic> data =
          asMap(json['data']) ?? <String, dynamic>{};
      final Map<String, dynamic> meta =
          asMap(json['meta']) ?? <String, dynamic>{};
      return MarketSearchPage.fromJson(data, meta, base);
    } on DioException catch (e) {
      throw _mapDioException(e, base);
    }
  }

  /// 检查已装小程序的升级。
  ///
  /// [installed] 是「本机已装的 (appId, version)」列表。
  /// 返回**确实需要更新**的条目（版本不一致就算，不比较大小 ——
  /// 版本号没有强制语义，猜「哪个更大」会出错）。
  ///
  /// 用 POST 而不是 GET：要带一组已装版本，放查询串会很长，
  /// 也更容易被日志记下来。
  Future<List<PackageUpdate>> checkUpdates(
    List<({String id, String version})> installed,
  ) async {
    if (installed.isEmpty) return const <PackageUpdate>[];
    final String base = _settings.serverUrl;

    try {
      final Response<dynamic> res = await _dio.post<dynamic>(
        '$base/api/market/updates',
        data: <String, dynamic>{
          'installed': installed
              .map((({String id, String version}) e) =>
                  <String, dynamic>{'id': e.id, 'version': e.version})
              .toList(growable: false),
        },
        options: Options(validateStatus: (int? s) => s != null),
      );
      if (res.statusCode != 200) return const <PackageUpdate>[];

      final Map<String, dynamic> json = _unwrap(res, '$base/api/market/updates');
      final Object? data = json['data'];
      if (data is! Map) return const <PackageUpdate>[];
      final Object? list = data['updates'];
      if (list is! List) return const <PackageUpdate>[];

      return list
          .whereType<Map>()
          .map(
            (Map m) => PackageUpdate.fromJson(
              m.map<String, dynamic>(
                (Object? k, Object? v) =>
                    MapEntry<String, dynamic>(k.toString(), v),
              ),
            ),
          )
          .whereType<PackageUpdate>()
          .toList(growable: false);
    } catch (e) {
      // 升级检查失败不该打扰用户（它只是「顺便看一眼」）
      lemonLog('Market', '检查更新失败：$e');
      return const <PackageUpdate>[];
    }
  }

  /// 全量标签（搜索页初始状态用）
  Future<List<MarketTag>> fetchTags() async {
    final String base = _settings.serverUrl;
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        '$base/api/market/tags',
        options: Options(validateStatus: (int? s) => s != null),
      );
      if (res.statusCode != 200) return const <MarketTag>[];
      final Map<String, dynamic> json = _unwrap(res, '$base/api/market/tags');
      final Object? data = json['data'];
      if (data is! List) return const <MarketTag>[];
      return data
          .whereType<Map>()
          .map(
            (Map m) => MarketTag.fromJson(
              m.map<String, dynamic>(
                (Object? k, Object? v) =>
                    MapEntry<String, dynamic>(k.toString(), v),
              ),
            ),
          )
          .whereType<MarketTag>()
          .toList(growable: false);
    } catch (_) {
      return const <MarketTag>[];
    }
  }

  MarketException _httpError(int? status, String url) {
    if (status == 404) {
      return MarketException(
        'http_404',
        '服务器上没有找到这个接口（404）',
        detail: url,
      );
    }
    return MarketException(
      'http_$status',
      '服务器返回异常状态码 $status',
      detail: url,
    );
  }

  /// DioException → 用户能看懂的 [MarketException]
  MarketException _mapDioException(DioException e, String base) {
    final int? status = e.response?.statusCode;
    if (status != null) {
      if (status == 404) {
        return MarketException(
          'http_404',
          '服务器上没有找到 index.json（404）',
          detail: '请确认 $base 根目录下存在 index.json',
        );
      }
      return MarketException(
        'http_$status',
        '服务器返回异常状态码 $status',
        detail: e.message,
      );
    }

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      // dio 5.9 起新增：响应体转换阶段超时
      case DioExceptionType.transformTimeout:
        return MarketException('timeout', '连接超时，请检查网络或服务器地址', detail: e.message);
      case DioExceptionType.badCertificate:
        return MarketException('bad_certificate', '服务器证书校验失败', detail: e.message);
      case DioExceptionType.cancel:
        return const MarketException('canceled', '请求已被取消');
      case DioExceptionType.connectionError:
        return MarketException('network', '网络连接失败，请检查网络设置', detail: e.message);
      case DioExceptionType.badResponse:
        return MarketException(
          'http_error',
          '服务器返回异常',
          detail: e.response?.statusCode?.toString(),
        );
      case DioExceptionType.unknown:
        return MarketException(
          'network',
          '网络请求失败：${e.message ?? '未知原因'}',
          detail: e.error?.toString(),
        );
    }
  }
}

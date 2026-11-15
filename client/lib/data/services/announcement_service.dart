// lib/data/services/announcement_service.dart
//
// 站点公告的客户端出口。
//
// 两个接口，都**不需要登录**：
//   GET /api/announcements/latest            客户端启动时拉一条弹窗
//   GET /api/announcements?limit&offset      设置 → 市场 → 公告 里的历史列表
//
// 为什么单开一个服务而不是塞进 MarketRepository：
// 市场仓库的语义是「应用数据」（feed / search / 详情），公告是站点级通知，
// 两者的失败处理也不同 —— 市场失败要占满整屏的错误态，
// 公告失败只该安静地不弹（用户是来用 App 的，不是来看「公告没加载出来」的）。
// 所以这里的 `fetchLatest()` 在网络错误时返回 null 而不是抛异常。
//
// 服务器地址每次请求都从 SettingsService 实时读，开发者改完地址立刻生效。

import 'package:dio/dio.dart';

import '../../core/globals.dart';
import '../models/announcement.dart';
import 'settings_service.dart';

/// 带状态的公告失败（历史页要显示「为什么是空的」）
class AnnouncementException implements Exception {
  const AnnouncementException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AnnouncementException($code): $message';
}

class AnnouncementService {
  AnnouncementService({Dio? dio, SettingsService? settings})
    : _settings = settings ?? SettingsService.instance,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: <String, String>{'Accept': 'application/json'},
            ),
          );

  final Dio _dio;
  final SettingsService _settings;

  String get _base => _settings.serverUrl.trim();

  /// 解析 `{ok, data, meta}`；失败抛 [AnnouncementException]
  Map<String, dynamic> _unwrap(Response<dynamic> res, String path) {
    final Object? raw = res.data;
    if (raw is! Map) {
      throw AnnouncementException('bad_response', '服务器返回了无法识别的内容（$path）');
    }
    final Map<String, dynamic> json = raw.map<String, dynamic>(
      (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
    );
    if (json['ok'] == true) return json;
    final Object? err = json['error'];
    if (err is Map) {
      throw AnnouncementException(
        (err['code'] ?? 'api_error').toString(),
        (err['message'] ?? '服务器返回错误').toString(),
      );
    }
    throw AnnouncementException('api_error', '服务器返回错误（$path）');
  }

  /// 最新一条公告；没有公告、或请求失败都返回 null。
  ///
  /// 「失败返回 null」是刻意的：这个方法是**启动路径**上的，
  /// 断网、服务端没起、域名填错都很常见，任何一种都不该让用户
  /// 在打开 App 的第一秒看到一个错误弹窗。
  Future<Announcement?> fetchLatest() async {
    try {
      final Response<dynamic> res = await _dio.get<dynamic>('$_base/api/announcements/latest');
      final Map<String, dynamic> json = _unwrap(res, '/api/announcements/latest');
      final Object? data = json['data'];
      if (data is! Map) return null;
      final Object? ann = data['announcement'];
      if (ann is! Map) return null;
      return Announcement.fromJson(
        ann.map<String, dynamic>(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        ),
      );
    } on AnnouncementException catch (e) {
      lemonLogError('Announcement', '拉最新公告失败：${e.code} ${e.message}');
      return null;
    } on DioException catch (e) {
      lemonLogError('Announcement', '拉最新公告失败：${e.type} ${e.message}');
      return null;
    }
  }

  /// 历史公告（按发布时间倒序）。失败**抛异常** —— 历史页需要告诉用户为什么是空的。
  Future<AnnouncementPage> fetchHistory({int limit = 20, int offset = 0}) async {
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        '$_base/api/announcements',
        queryParameters: <String, dynamic>{'limit': limit, 'offset': offset},
      );
      final Map<String, dynamic> json = _unwrap(res, '/api/announcements');
      final Object? data = json['data'];
      final Object? meta = json['meta'];
      return AnnouncementPage.fromJson(
        data is Map
            ? data.map<String, dynamic>(
                (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
              )
            : <String, dynamic>{},
        meta is Map
            ? meta.map<String, dynamic>(
                (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
              )
            : <String, dynamic>{},
      );
    } on AnnouncementException {
      rethrow;
    } on DioException catch (e) {
      throw AnnouncementException('network', _describeDio(e));
    }
  }

  String _describeDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查网络或服务器地址';
      case DioExceptionType.badResponse:
        return '服务器返回异常（${e.response?.statusCode}）';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络设置';
      default:
        return '网络请求失败：${e.message ?? '未知原因'}';
    }
  }
}

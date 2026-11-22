
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/globals.dart';
import '../models/app_item.dart';
import '../models/category.dart';
import '../models/market_feed.dart';
import 'settings_service.dart';

/// 一页缓存的 feed
@immutable
class CachedFeed {
  const CachedFeed({
    required this.apps,
    required this.categories,
    required this.nextCursor,
    required this.hasMore,
    required this.limit,
    required this.savedAt,
  });

  final List<AppItem> apps;
  final List<AppCategory> categories;
  final String? nextCursor;
  final bool hasMore;
  final int limit;
  final DateTime savedAt;

  bool get isEmpty => apps.isEmpty;
}

/// 一组关键词的缓存搜索结果
@immutable
class CachedSearch {
  const CachedSearch({
    required this.apps,
    required this.tags,
    required this.total,
    required this.hasMore,
    required this.limit,
    required this.savedAt,
    required this.query,
    required this.tag,
  });

  final List<AppItem> apps;
  final List<MarketTag> tags;
  final int total;
  final bool hasMore;
  final int limit;
  final DateTime savedAt;
  final String query;
  final String tag;
}

class MarketCacheService {
  MarketCacheService._(this._settings);

  static MarketCacheService? _instance;

  static MarketCacheService init(SettingsService settings) =>
      _instance = MarketCacheService._(settings);

  /// 可能还没初始化（单测 / 小程序独立窗口）—— 调用方按「没有缓存」处理
  static MarketCacheService? get maybeInstance => _instance;

  static MarketCacheService get instance {
    final MarketCacheService? s = _instance;
    if (s == null) {
      throw StateError('MarketCacheService 尚未初始化');
    }
    return s;
  }

  /// 键前缀。版本号进 key，是为了让「结构变了」时旧数据自然失效，
  /// 不必写迁移代码。
  static const String _feedPrefix = 'cache.market.feed.v1.';
  static const String _searchKey = 'cache.market.search.v1';

  /// feed 单类最多缓存多少条
  static const int _maxFeedApps = 200;

  /// 搜索缓存最多保留几组关键词
  static const int _maxSearchEntries = 10;

  /// 每组搜索最多缓存多少条
  static const int _maxSearchApps = 40;

  final SettingsService _settings;

  String get _server => _settings.serverUrl;

  String _feedKey(String category) =>
      '$_feedPrefix${category.isEmpty ? AppCategory.allId : category}';

  // ---------------------------------------------------------------- feed

  /// 读某分类的缓存。没有 / 服务器对不上 / 解析失败都返回 null。
  CachedFeed? readFeed(String category) {
    final String? raw = _settings.readRaw(_feedKey(category));
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Map<String, dynamic> json = _asStringMap(decoded);
      if ((json['server'] ?? '').toString() != _server) return null;

      final List<AppItem> apps = _parseApps(json['apps']);
      if (apps.isEmpty) return null;
      final String cursor = (json['nextCursor'] ?? '').toString().trim();
      return CachedFeed(
        apps: apps,
        categories: _parseCategories(json['categories']),
        nextCursor: cursor.isEmpty ? null : cursor,
        hasMore: json['hasMore'] == true,
        limit: (json['limit'] as num?)?.toInt() ?? 0,
        savedAt:
            DateTime.tryParse((json['savedAt'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (e) {
      lemonLog('MarketCache', 'feed 缓存解析失败，忽略：$e');
      return null;
    }
  }

  /// 写某分类的缓存。超过上限时只留最近的 200 条（用户滑到哪就留到哪）。
  Future<void> saveFeed({
    required String category,
    required List<AppItem> apps,
    required List<AppCategory> categories,
    required String? nextCursor,
    required bool hasMore,
    required int limit,
  }) async {
    if (apps.isEmpty) return;
    final List<AppItem> trimmed = apps.length <= _maxFeedApps
        ? apps
        : apps.sublist(apps.length - _maxFeedApps);
    final Map<String, dynamic> json = <String, dynamic>{
      'server': _server,
      'savedAt': DateTime.now().toIso8601String(),
      'nextCursor': nextCursor,
      'hasMore': hasMore,
      'limit': limit,
      'categories': categories
          .map((AppCategory c) => <String, dynamic>{'id': c.id, 'name': c.name})
          .toList(growable: false),
      'apps': trimmed.map((AppItem a) => a.toJson()).toList(growable: false),
    };
    await _settings.writeRaw(_feedKey(category), jsonEncode(json));
  }

  // ---------------------------------------------------------------- 搜索

  /// 读一组关键词的缓存
  CachedSearch? readSearch({required String query, required String tag}) {
    final String? raw = _settings.readRaw(_searchKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Map<String, dynamic> root = _asStringMap(decoded);
      if ((root['server'] ?? '').toString() != _server) return null;
      final Object? entries = root['entries'];
      if (entries is! List) return null;

      final String wanted = _searchKeyOf(query, tag);
      for (final Object? item in entries) {
        if (item is! Map) continue;
        final Map<String, dynamic> entry = _asStringMap(item);
        if ((entry['key'] ?? '').toString() != wanted) continue;
        final List<AppItem> apps = _parseApps(entry['apps']);
        return CachedSearch(
          apps: apps,
          tags: _parseTags(entry['tags']),
          total: (entry['total'] as num?)?.toInt() ?? apps.length,
          hasMore: entry['hasMore'] == true,
          limit: (entry['limit'] as num?)?.toInt() ?? 0,
          savedAt:
              DateTime.tryParse((entry['savedAt'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0),
          query: (entry['query'] ?? '').toString(),
          tag: (entry['tag'] ?? '').toString(),
        );
      }
      return null;
    } catch (e) {
      lemonLog('MarketCache', '搜索缓存解析失败，忽略：$e');
      return null;
    }
  }

  /// 写一组关键词的缓存（同一个 key 覆盖，最多保留 10 组）
  Future<void> saveSearch({
    required String query,
    required String tag,
    required List<AppItem> apps,
    required List<MarketTag> tags,
    required int total,
    required bool hasMore,
    required int limit,
  }) async {
    if (apps.isEmpty) return;
    final List<Map<String, dynamic>> entries = _readSearchEntries();
    final String key = _searchKeyOf(query, tag);
    entries.removeWhere((Map<String, dynamic> e) => e['key'] == key);
    entries.insert(0, <String, dynamic>{
      'key': key,
      'query': query,
      'tag': tag,
      'savedAt': DateTime.now().toIso8601String(),
      'total': total,
      'hasMore': hasMore,
      'limit': limit,
      'tags': tags
          .map(
            (MarketTag t) => <String, dynamic>{
              'name': t.name,
              'slug': t.slug,
              'count': t.count,
            },
          )
          .toList(growable: false),
      'apps': apps
          .take(_maxSearchApps)
          .map((AppItem a) => a.toJson())
          .toList(growable: false),
    });
    final List<Map<String, dynamic>> kept = entries
        .take(_maxSearchEntries)
        .toList();
    await _settings.writeRaw(
      _searchKey,
      jsonEncode(<String, dynamic>{'server': _server, 'entries': kept}),
    );
  }

  List<Map<String, dynamic>> _readSearchEntries() {
    final String? raw = _settings.readRaw(_searchKey);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <Map<String, dynamic>>[];
      final Map<String, dynamic> root = _asStringMap(decoded);
      if ((root['server'] ?? '').toString() != _server) {
        return <Map<String, dynamic>>[];
      }
      final Object? entries = root['entries'];
      if (entries is! List) return <Map<String, dynamic>>[];
      return entries.whereType<Map>().map(_asStringMap).toList(growable: true);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  // ---------------------------------------------------------------- 清理

  /// 清空全部市场缓存（退出登录 / 注销 / App 退出 / 手动清理时调用）
  Future<void> clear() async {
    final List<String> keys = _settings
        .keysWithPrefix('cache.market.')
        .toList(growable: false);
    if (keys.isEmpty) return;
    await _settings.removeMany(keys);
    lemonLog('MarketCache', '已清空市场缓存（${keys.length} 项）');
  }

  // ---------------------------------------------------------------- 工具

  static String _searchKeyOf(String query, String tag) =>
      '${query.trim().toLowerCase()}|${tag.trim().toLowerCase()}';

  static Map<String, dynamic> _asStringMap(Map<dynamic, dynamic> value) =>
      value.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );

  static List<AppItem> _parseApps(Object? value) {
    if (value is! List) return const <AppItem>[];
    return value
        .whereType<Map>()
        .map((Map m) => AppItem.fromJson(_asStringMap(m)))
        .whereType<AppItem>()
        .toList(growable: false);
  }

  static List<AppCategory> _parseCategories(Object? value) {
    if (value is! List) return const <AppCategory>[];
    return value
        .whereType<Map>()
        .map((Map m) => AppCategory.fromJson(_asStringMap(m)))
        .whereType<AppCategory>()
        .toList(growable: false);
  }

  static List<MarketTag> _parseTags(Object? value) {
    if (value is! List) return const <MarketTag>[];
    return value
        .whereType<Map>()
        .map((Map m) => MarketTag.fromJson(_asStringMap(m)))
        .whereType<MarketTag>()
        .toList(growable: false);
  }
}

// lib/data/models/market_feed.dart
//
// 服务端市场接口的响应模型。
//
// 与 index.json 的区别：
//   * index.json 是「一次性全量」（一个文件里所有应用）；
//   * 服务端是「分段加载」——每次只拿一页，带一个不透明游标去取下一页。
//
// 所以这里多了两个概念：
//   MarketFeedPage  —— 一页数据 + 下一页的游标
//   MarketTag       —— 搜索返回的标签（带该标签下的应用数）

import 'app_item.dart';
import 'category.dart';
import 'json_utils.dart';

/// 主页推荐的一页
class MarketFeedPage {
  const MarketFeedPage({
    this.apps = const <AppItem>[],
    this.categories = const <AppCategory>[],
    this.nextCursor,
    this.hasMore = false,
  });

  final List<AppItem> apps;

  /// 分类只在第一页返回（后续页为空，客户端要保留第一页拿到的）
  final List<AppCategory> categories;

  /// 下一页的游标；null 表示没有更多了
  final String? nextCursor;

  final bool hasMore;

  factory MarketFeedPage.fromJson(
    Map<String, dynamic> data,
    Map<String, dynamic> meta,
    String base,
  ) {
    final List<AppItem> apps = asMapList(data['apps'])
        .map(AppItem.fromJson)
        .whereType<AppItem>()
        .map((AppItem app) => app.resolveAgainst(base))
        .toList(growable: false);

    final List<AppCategory> categories = asMapList(data['categories'])
        .map(AppCategory.fromJson)
        .whereType<AppCategory>()
        .toList(growable: false);

    final Object? cursor = meta['nextCursor'];
    return MarketFeedPage(
      apps: apps,
      categories: categories,
      nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
      hasMore: meta['hasMore'] == true,
    );
  }
}

/// 一个标签（搜索页的筛选 chip）
class MarketTag {
  const MarketTag({required this.name, required this.slug, this.count = 0});

  final String name;
  final String slug;

  /// 该标签下的应用数
  final int count;

  static MarketTag? fromJson(Map<String, dynamic> json) {
    final String name = asString(json['name']);
    final String slug = asString(json['slug'], fallback: name);
    if (name.isEmpty && slug.isEmpty) return null;
    return MarketTag(
      name: name.isEmpty ? slug : name,
      slug: slug,
      count: asInt(json['count']),
    );
  }
}

/// 搜索结果的一页
class MarketSearchPage {
  const MarketSearchPage({
    this.apps = const <AppItem>[],
    this.tags = const <MarketTag>[],
    this.total = 0,
    this.hasMore = false,
    this.query = '',
    this.activeTag = '',
  });

  final List<AppItem> apps;

  /// 命中结果里实际出现过的标签（点了不会没结果）
  final List<MarketTag> tags;

  final int total;
  final bool hasMore;

  /// 回显的查询条件：用于「这个响应对应哪次输入」的判断，
  /// 避免快速输入时旧响应覆盖新响应
  final String query;
  final String activeTag;

  factory MarketSearchPage.fromJson(
    Map<String, dynamic> data,
    Map<String, dynamic> meta,
    String base,
  ) {
    final List<AppItem> apps = asMapList(data['apps'])
        .map(AppItem.fromJson)
        .whereType<AppItem>()
        .map((AppItem app) => app.resolveAgainst(base))
        .toList(growable: false);

    final List<MarketTag> tags = asMapList(data['tags'])
        .map(MarketTag.fromJson)
        .whereType<MarketTag>()
        .toList(growable: false);

    final Map<String, dynamic> q = asMap(data['query']) ?? <String, dynamic>{};

    return MarketSearchPage(
      apps: apps,
      tags: tags,
      total: asInt(data['total']),
      hasMore: meta['hasMore'] == true,
      query: asString(q['q']),
      activeTag: asString(q['tag']),
    );
  }
}

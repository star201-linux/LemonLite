// test/market_cache_test.dart
//
// 主页 / 搜索的本地分段缓存。
//
// 这块最怕两件事：
//   1. 序列化不对称（写进去的字段读不回来 → 缓存永远是空的）；
//   2. 换了服务器还在读旧服务器的缓存（用户会看到「新站里出现了旧站的应用」）。
// 两条都在这里钉住。

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/models/app_item.dart';
import 'package:lemonlite/data/models/category.dart';
import 'package:lemonlite/data/models/market_feed.dart';
import 'package:lemonlite/data/services/market_cache_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  late MarketCacheService cache;

  AppItem sample(String id) => AppItem(
    id: id,
    name: '应用 $id',
    description: '简介',
    category: 'tools',
    version: '1.2.0',
    author: '作者',
    packageUrl: 'https://example.com/$id.zip',
    packageSha256: 'abc',
    packageBytes: 1024,
    icon: 'https://example.com/$id.png',
    size: 1024,
    categories: const <AppCategory>[AppCategory(id: 'tools', name: '工具')],
    tags: const <String>['效率'],
    screenshots: const <String>['https://example.com/s.png'],
    permissions: const <String>['camera'],
    updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = await SettingsService.init();
    cache = MarketCacheService.init(settings);
  });

  test('AppItem 的 toJson / fromJson 是恒等变换', () {
    final AppItem original = sample('demo.app');
    final AppItem back = AppItem.fromJson(original.toJson())!;
    expect(back.id, original.id);
    expect(back.name, original.name);
    expect(back.description, original.description);
    expect(back.packageUrl, original.packageUrl);
    expect(back.packageSha256, original.packageSha256);
    expect(back.packageBytes, original.packageBytes);
    expect(back.icon, original.icon);
    expect(back.categories.single.id, 'tools');
    expect(back.tags, <String>['效率']);
    expect(back.permissions, <String>['camera']);
    expect(back.updatedAt, original.updatedAt);
  });

  test('feed 缓存：写入后能读回应用、分类、游标与每页条数', () async {
    await cache.saveFeed(
      category: AppCategory.allId,
      apps: <AppItem>[sample('a'), sample('b')],
      categories: const <AppCategory>[AppCategory(id: 'tools', name: '工具')],
      nextCursor: 'cursor-1',
      hasMore: true,
      limit: 25,
    );

    final CachedFeed? feed = cache.readFeed(AppCategory.allId);
    expect(feed, isNotNull);
    expect(feed!.apps.map((AppItem a) => a.id), <String>['a', 'b']);
    expect(feed.categories.single.name, '工具');
    expect(feed.nextCursor, 'cursor-1');
    expect(feed.hasMore, isTrue);
    expect(feed.limit, 25, reason: '每页条数要跟服务端一致，不能退回客户端写死的值');
  });

  test('缓存按服务器隔离：换了服务器读不到旧缓存', () async {
    await cache.saveFeed(
      category: AppCategory.allId,
      apps: <AppItem>[sample('a')],
      categories: const <AppCategory>[],
      nextCursor: null,
      hasMore: false,
      limit: 20,
    );
    expect(cache.readFeed(AppCategory.allId), isNotNull);

    await settings.setServerUrl('https://another.example.com');
    expect(
      cache.readFeed(AppCategory.allId),
      isNull,
      reason: '切服务器后旧站的列表绝不能再显示出来',
    );
  });

  test('不同分类各自独立缓存', () async {
    await cache.saveFeed(
      category: 'tools',
      apps: <AppItem>[sample('t1')],
      categories: const <AppCategory>[],
      nextCursor: null,
      hasMore: false,
      limit: 20,
    );
    await cache.saveFeed(
      category: 'fun',
      apps: <AppItem>[sample('f1'), sample('f2')],
      categories: const <AppCategory>[],
      nextCursor: null,
      hasMore: false,
      limit: 20,
    );
    expect(cache.readFeed('tools')!.apps.single.id, 't1');
    expect(cache.readFeed('fun')!.apps.length, 2);
    expect(cache.readFeed('nope'), isNull);
  });

  test('搜索缓存：同一组关键词 + 标签命中，大小写不敏感', () async {
    await cache.saveSearch(
      query: 'Notes',
      tag: '效率',
      apps: <AppItem>[sample('n1')],
      tags: const <MarketTag>[
        MarketTag(name: '效率', slug: 'efficiency', count: 1),
      ],
      total: 1,
      hasMore: false,
      limit: 15,
    );

    final CachedSearch? hit = cache.readSearch(query: 'notes', tag: '效率');
    expect(hit, isNotNull);
    expect(hit!.apps.single.id, 'n1');
    expect(hit.tags.single.slug, 'efficiency');
    expect(hit.limit, 15);
    expect(cache.readSearch(query: 'notes', tag: '别的'), isNull);
  });

  test('搜索缓存最多留 10 组关键词（旧的被挤掉）', () async {
    for (int i = 0; i < 12; i++) {
      await cache.saveSearch(
        query: 'q$i',
        tag: '',
        apps: <AppItem>[sample('app$i')],
        tags: const <MarketTag>[],
        total: 1,
        hasMore: false,
        limit: 20,
      );
    }
    // 最新的一定在
    expect(cache.readSearch(query: 'q11', tag: ''), isNotNull);
    // 最旧的被挤出去
    expect(cache.readSearch(query: 'q0', tag: ''), isNull);
  });

  test('clear 会同时清掉 feed 与搜索缓存', () async {
    await cache.saveFeed(
      category: AppCategory.allId,
      apps: <AppItem>[sample('a')],
      categories: const <AppCategory>[],
      nextCursor: null,
      hasMore: false,
      limit: 20,
    );
    await cache.saveSearch(
      query: 'q',
      tag: '',
      apps: <AppItem>[sample('a')],
      tags: const <MarketTag>[],
      total: 1,
      hasMore: false,
      limit: 20,
    );

    await cache.clear();
    expect(cache.readFeed(AppCategory.allId), isNull);
    expect(cache.readSearch(query: 'q', tag: ''), isNull);
  });

  test('坏数据当作没有缓存，不抛异常', () async {
    await settings.writeRaw('cache.market.feed.v1.all', '{not json');
    expect(cache.readFeed(AppCategory.allId), isNull);

    await settings.writeRaw('cache.market.search.v1', '[]');
    expect(cache.readSearch(query: 'x', tag: ''), isNull);
  });

  test('MarketFeedPage 会读取服务端给的 limit', () {
    final MarketFeedPage page = MarketFeedPage.fromJson(
      <String, dynamic>{
        'apps': <dynamic>[sample('a').toJson()],
        'categories': <dynamic>[],
      },
      <String, dynamic>{'hasMore': false, 'limit': 30},
      'https://example.com',
    );
    expect(page.limit, 30);
    expect(page.apps.single.id, 'a');
  });
}

// test/market_test.dart
//
// 0.4 新增的市场接口模型 + 定位权限映射的单元测试。
//
// 这两块都容易「看起来对但其实错了」：
//   * 分段加载的游标 / hasMore 语义错了，用户会看到重复卡片或提前到底；
//   * 定位权限映射错了，用户选「大致位置」却拿到了精确坐标（或反过来）。
// 所以都用断言钉住。

import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/bridge/web_permission.dart';
import 'package:lemonlite/data/models/app_item.dart';
import 'package:lemonlite/data/models/miniapp_permission.dart';
import 'package:lemonlite/data/models/market_feed.dart';

void main() {
  // ========================================================== 市场模型

  group('MarketFeedPage 解析', () {
    Map<String, dynamic> dataJson({
      List<Map<String, dynamic>> apps = const <Map<String, dynamic>>[],
      List<Map<String, dynamic>> categories = const <Map<String, dynamic>>[],
    }) => <String, dynamic>{'apps': apps, 'categories': categories};

    test('正常解析一页，并把相对地址解析成绝对地址', () {
      final MarketFeedPage page = MarketFeedPage.fromJson(
        dataJson(
          apps: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'a',
              'name': 'A',
              'packageUrl': 'https://example.com/pkgs/a.zip',
              'icon': 'icons/a.png',
            },
          ],
        ),
        <String, dynamic>{'nextCursor': 'abc', 'hasMore': true},
        'https://example.com',
      );

      expect(page.apps, hasLength(1));
      expect(page.apps.first.packageUrl, 'https://example.com/pkgs/a.zip');
      expect(page.apps.first.icon, 'https://example.com/icons/a.png');
      expect(page.nextCursor, 'abc');
      expect(page.hasMore, isTrue);
    });

    test('没有更多时 nextCursor 是 null', () {
      final MarketFeedPage page = MarketFeedPage.fromJson(
        dataJson(),
        <String, dynamic>{'nextCursor': null, 'hasMore': false},
        'https://example.com',
      );
      expect(page.nextCursor, isNull);
      expect(page.hasMore, isFalse);
    });

    test('空字符串游标也当作 null（服务端可能返回 ""）', () {
      final MarketFeedPage page = MarketFeedPage.fromJson(
        dataJson(),
        <String, dynamic>{'nextCursor': '', 'hasMore': true},
        'https://example.com',
      );
      expect(page.nextCursor, isNull);
    });

    test('apps 里非对象的条目被跳过，不会崩', () {
      final MarketFeedPage page = MarketFeedPage.fromJson(
        <String, dynamic>{
          'apps': <dynamic>[
            <String, dynamic>{'id': 'ok', 'name': 'OK', 'packageUrl': 'x'},
            'garbage',
            42,
            null,
          ],
        },
        <String, dynamic>{},
        'https://example.com',
      );
      expect(page.apps, hasLength(1));
      expect(page.apps.first.id, 'ok');
    });

    test('缺少 categories 时是空列表（后续页就是这种）', () {
      final MarketFeedPage page = MarketFeedPage.fromJson(
        <String, dynamic>{'apps': <dynamic>[]},
        <String, dynamic>{},
        'https://example.com',
      );
      expect(page.categories, isEmpty);
    });
  });

  group('MarketSearchPage 解析', () {
    test('标签按 count 字符串也能解析成数字', () {
      final MarketSearchPage page = MarketSearchPage.fromJson(
        <String, dynamic>{
          'apps': <dynamic>[],
          'tags': <dynamic>[
            <String, dynamic>{'name': '效率', 'slug': 'productivity', 'count': '3'},
          ],
          'total': 7,
          'query': <String, dynamic>{'q': '记事', 'tag': 'productivity'},
        },
        <String, dynamic>{'hasMore': true},
        'https://example.com',
      );

      expect(page.tags, hasLength(1));
      expect(page.tags.first.count, 3);
      expect(page.total, 7);
      expect(page.hasMore, isTrue);
      // 回显的查询条件用于「这个响应对应哪次输入」
      expect(page.query, '记事');
      expect(page.activeTag, 'productivity');
    });

    test('缺 slug 时用 name 兜底', () {
      final MarketTag? tag = MarketTag.fromJson(
        <String, dynamic>{'name': '游戏'},
      );
      expect(tag, isNotNull);
      expect(tag!.slug, '游戏');
    });

    test('name 与 slug 都空时返回 null', () {
      expect(MarketTag.fromJson(<String, dynamic>{}), isNull);
    });

    test('total 缺失时为 0', () {
      final MarketSearchPage page = MarketSearchPage.fromJson(
        <String, dynamic>{'apps': <dynamic>[]},
        <String, dynamic>{},
        'https://example.com',
      );
      expect(page.total, 0);
      expect(page.apps, isEmpty);
    });
  });

  // ========================================================== 定位映射

  group('定位权限映射（forGeolocation）', () {
    test('默认同时问精确与模糊两档，顺序固定按枚举', () {
      final List<MiniappPermission> ask = WebPermissionAsk.forGeolocation();
      expect(
        ask,
        <MiniappPermission>[
          MiniappPermission.geolocationFine,
          MiniappPermission.geolocationCoarse,
        ],
      );
    });

    test('requestFine=false 时只问模糊', () {
      final List<MiniappPermission> ask =
          WebPermissionAsk.forGeolocation(requestFine: false);
      expect(ask, <MiniappPermission>[MiniappPermission.geolocationCoarse]);
    });

    test('定位不在 onPermissionRequest 的映射表里（走另一个回调）', () {
      // 这是刻意的：Android WebView 的 onPermissionRequest 根本不回调定位。
      // 把它写进映射表只会让人以为定位在那儿被拦了。
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[PermissionResourceType.GEOLOCATION],
        ),
      );
      expect(ask.isUnmanaged, isTrue);
      expect(ask.permissions, isEmpty);
    });
  });

  group('剪贴板与通知的映射', () {
    test('CLIPBOARD_READ → clipboard', () {
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[
            PermissionResourceType.CLIPBOARD_READ,
          ],
        ),
      );
      expect(ask.permissions, <MiniappPermission>[MiniappPermission.clipboard]);
    });

    test('NOTIFICATIONS → notifications', () {
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[
            PermissionResourceType.NOTIFICATIONS,
          ],
        ),
      );
      expect(ask.permissions, <MiniappPermission>[MiniappPermission.notifications]);
    });

    test('同意剪贴板后回包只带 CLIPBOARD_READ', () {
      final WebPermissionAsk ask = WebPermissionAsk.from(
        PermissionRequest(
          origin: WebUri('https://example.com'),
          resources: <PermissionResourceType>[
            PermissionResourceType.CLIPBOARD_READ,
          ],
        ),
      );
      final PermissionResponse res = WebPermissionAsk.response(
        ask: ask,
        granted: <MiniappPermission>{MiniappPermission.clipboard},
      );
      expect(res.action, PermissionResponseAction.GRANT);
      expect(res.resources, <PermissionResourceType>[
        PermissionResourceType.CLIPBOARD_READ,
      ]);
    });
  });

  // ========================================================== 版本兼容

  group('与旧数据兼容', () {
    test('0.2 的旧权限 id 仍然被识别为「已退役」而不是错误', () {
      const List<String> oldIds = <String>[
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
      ];
      for (final String id in oldIds) {
        expect(MiniappPermission.isRetired(id), isTrue, reason: '$id 应退役');
        expect(MiniappPermission.byId(id), isNull, reason: '$id 不该还在枚举里');
      }
    });

    test('index.json 里混着旧 id 时，只认出新的那些', () {
      final AppItem? app = AppItem.fromJson(<String, dynamic>{
        'id': 'x',
        'name': 'X',
        'packageUrl': 'https://example.com/x.zip',
        'permissions': <dynamic>[
          'network', // 退役
          'camera', // 有效
          'geolocationFine', // 有效
          'camra', // 拼错
        ],
      });
      expect(app, isNotNull);
      expect(
        app!.declaredPermissions,
        <MiniappPermission>[
          MiniappPermission.camera,
          MiniappPermission.geolocationFine,
        ],
      );
      // 已退役的 id **不进** unknownPermissionIds（它是预期数据，不是错误）；
      // 只有真正拼错的才进 —— 那个字段的用途是「提醒市场数据维护者」。
      expect(app.unknownPermissionIds, isNot(contains('network')));
      expect(app.unknownPermissionIds, contains('camra'));
      // 退役 id 能被单独识别出来（详情页据此说明「已不再需要授权」）
      expect(
        app.permissions.where(MiniappPermission.isRetired),
        contains('network'),
      );
    });
  });

  // ========================================================== JSON 编码

  group('服务端响应格式', () {
    test('游标是 base64url 且去掉 padding（能原样放进 URL 查询串）', () {
      // 服务端用 Node 的 `Buffer.toString('base64url')` —— 它会**去掉** `=`
      // padding。Dart 的 base64Url.encode 默认保留 padding，所以这里显式
      // 去掉再比较，顺便把这个约定写进断言。
      const String raw = '{"w":0,"t":"2026-10-18 12:00:00.000","id":"a"}';
      final String cursor = base64Url
          .encode(utf8.encode(raw))
          .replaceAll('=', '');
      expect(cursor, isNot(contains('+')));
      expect(cursor, isNot(contains('/')));
      expect(cursor, isNot(contains('=')));
      // 不含需要额外转义的字符，所以查询串里可以直接放
      expect(Uri.encodeQueryComponent(cursor), cursor);
    });
  });
}

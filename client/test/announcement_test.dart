// test/announcement_test.dart
//
// 公告模型与时间展示。
//
// 重点在时间：服务端给的是**带 Z 的 UTC ISO**，如果客户端直接把它贴到界面上，
// 东八区用户会看到「早上 9 点发的」而实际是下午 5 点发的。
// 所以这里钉住两点：
//   1. `fromJson` 解析出来的是 UTC 时间；
//   2. `publishedLabel` 展示的是**本地时间**。

import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/models/announcement.dart';
import 'package:lemonlite/data/models/json_utils.dart';
import 'package:lemonlite/data/services/announcement_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Announcement.fromJson', () {
    test('解析完整字段', () {
      final Announcement ann = Announcement.fromJson(<String, dynamic>{
        'id': 7,
        'title': '维护通知',
        'content': '周日 02:00 停机维护。',
        'publishedAt': '2026-11-15T01:30:00.000Z',
      });
      expect(ann.id, 7);
      expect(ann.title, '维护通知');
      expect(ann.content, '周日 02:00 停机维护。');
      expect(ann.publishedAt!.isUtc, isTrue);
      expect(ann.publishedAt, DateTime.utc(2026, 11, 15, 1, 30));
    });

    test('缺字段不抛异常（老服务端 / 手工造的 JSON）', () {
      final Announcement ann = Announcement.fromJson(const <String, dynamic>{});
      expect(ann.id, 0);
      expect(ann.title, '');
      expect(ann.publishedAt, isNull);
      expect(ann.publishedLabel, '时间未知');
    });

    test('坏时间字符串 → null，而不是抛异常', () {
      final Announcement ann = Announcement.fromJson(<String, dynamic>{
        'id': 1,
        'title': 'x',
        'content': 'y',
        'publishedAt': '不是时间',
      });
      expect(ann.publishedAt, isNull);
    });

    test('publishedLabel 用本地时间展示', () {
      final Announcement ann = Announcement.fromJson(<String, dynamic>{
        'id': 1,
        'title': 't',
        'content': 'c',
        'publishedAt': '2026-11-15T01:30:00.000Z',
      });
      final DateTime local = DateTime.utc(2026, 11, 15, 1, 30).toLocal();
      expect(
        ann.publishedLabel,
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}',
      );
    });
  });

  group('AnnouncementPage', () {
    test('解析列表与分页 meta', () {
      final AnnouncementPage page = AnnouncementPage.fromJson(
        <String, dynamic>{
          'announcements': <dynamic>[
            <String, dynamic>{'id': 2, 'title': 'B', 'content': 'b'},
            <String, dynamic>{'id': 1, 'title': 'A', 'content': 'a'},
          ],
        },
        <String, dynamic>{'limit': 20, 'offset': 0, 'hasMore': true},
      );
      expect(page.items.length, 2);
      expect(page.items.first.title, 'B');
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 2);
    });

    test('空列表 + 没有 meta 也能构造', () {
      final AnnouncementPage page = AnnouncementPage.fromJson(
        const <String, dynamic>{},
        const <String, dynamic>{},
      );
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.limit, 20);
    });

    test('列表里混进非对象元素时跳过，不炸整页', () {
      final AnnouncementPage page = AnnouncementPage.fromJson(
        <String, dynamic>{
          'announcements': <dynamic>[
            'oops',
            42,
            <String, dynamic>{'id': 3, 'title': 'ok', 'content': 'x'},
          ],
        },
        const <String, dynamic>{},
      );
      expect(page.items.length, 1);
      expect(page.items.single.id, 3);
    });
  });

  group('公告级别', () {
    test('level 从 JSON 读出来', () {
      for (final int level in <int>[1, 2, 3, 4]) {
        final Announcement ann = Announcement.fromJson(<String, dynamic>{
          'id': 1,
          'title': 't',
          'content': 'c',
          'level': level,
        });
        expect(ann.level, level);
      }
    });

    test('缺 level 时按 1 处理（老服务端没这个字段）', () {
      final Announcement ann = Announcement.fromJson(<String, dynamic>{
        'id': 1,
        'title': 't',
        'content': 'c',
      });
      expect(ann.level, AnnouncementLevel.quiet);
    });

    test('越界的 level 夹回 1~4，而不是让未知值决定要不要弹窗', () {
      Announcement make(Object? raw) => Announcement.fromJson(<String, dynamic>{
        'id': 1,
        'title': 't',
        'content': 'c',
        'level': raw,
      });
      expect(make(0).level, 1);
      expect(make(-3).level, 1);
      expect(make(9).level, 4);
      expect(make('abc').level, 1);
    });

    test('isPopup 只对 3 / 4 为真', () {
      Announcement withLevel(int level) => Announcement(
        id: 1,
        title: 't',
        content: 'c',
        level: level,
      );
      expect(withLevel(1).isPopup, isFalse);
      expect(withLevel(2).isPopup, isFalse);
      expect(withLevel(3).isPopup, isTrue);
      expect(withLevel(4).isPopup, isTrue);
    });
  });

  group('pickPendingAnnouncement', () {
    Announcement ann(int id, int level) =>
        Announcement(id: id, title: 't$id', content: 'c', level: level);

    test('空列表 / 全是级别 1 → 不提醒', () {
      expect(pickPendingAnnouncement(<Announcement>[], <int>{}), isNull);
      expect(
        pickPendingAnnouncement(<Announcement>[ann(3, 1), ann(2, 1)], <int>{}),
        isNull,
      );
    });

    test('级别 2 → 横幅（不是弹窗）', () {
      final PendingAnnouncement? p = pickPendingAnnouncement(
        <Announcement>[ann(5, 2)],
        <int>{},
      );
      expect(p, isNotNull);
      expect(p!.announcement.id, 5);
      expect(p.asPopup, isFalse);
    });

    test('级别 3 未读 → 弹窗；已读 → 不再提醒', () {
      final List<Announcement> items = <Announcement>[ann(5, 3)];
      expect(pickPendingAnnouncement(items, <int>{})!.asPopup, isTrue);
      expect(pickPendingAnnouncement(items, <int>{5}), isNull);
    });

    test('级别 4 是最新一条 → 每次都弹，不看已读', () {
      final List<Announcement> items = <Announcement>[ann(9, 4)];
      final PendingAnnouncement? p = pickPendingAnnouncement(items, <int>{9});
      expect(p, isNotNull);
      expect(p!.announcement.id, 9);
      expect(p.asPopup, isTrue);
    });

    test('级别 4 后面又发了新公告 → 它退役，不再弹', () {
      // 列表是倒序的：新的在前
      final List<Announcement> items = <Announcement>[ann(10, 1), ann(9, 4)];
      expect(pickPendingAnnouncement(items, <int>{}), isNull);
    });

    test('退役的级别 4 不会挡住更早的未读级别 3', () {
      final List<Announcement> items = <Announcement>[
        ann(10, 1),
        ann(9, 4),
        ann(8, 3),
      ];
      final PendingAnnouncement? p = pickPendingAnnouncement(items, <int>{});
      expect(p, isNotNull);
      expect(p!.announcement.id, 8);
    });

    test('一次只提醒一条：新的优先', () {
      final List<Announcement> items = <Announcement>[
        ann(10, 3),
        ann(9, 3),
        ann(8, 2),
      ];
      final PendingAnnouncement? p = pickPendingAnnouncement(items, <int>{});
      expect(p!.announcement.id, 10);
    });

    test('最新的已读，就顺延到上一条未读', () {
      final List<Announcement> items = <Announcement>[ann(10, 3), ann(9, 2)];
      final PendingAnnouncement? p = pickPendingAnnouncement(items, <int>{10});
      expect(p!.announcement.id, 9);
      expect(p.asPopup, isFalse);
    });

    test('级别 1 不会因为「未读」被当成需要提醒', () {
      // 红点是另一条路径（unreadCount），不是「主动提醒」
      final List<Announcement> items = <Announcement>[ann(10, 1), ann(9, 1)];
      expect(pickPendingAnnouncement(items, <int>{}), isNull);
    });
  });

  group('AnnouncementService 的红点与提醒状态', () {
    late SettingsService settings;

    Announcement ann(int id, int level) => Announcement(
      id: id,
      title: 't$id',
      content: 'c$id',
      level: level,
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      settings = await SettingsService.init();
    });

    test('未读数 = 没被告知过的条数（级别 1 也算未读）', () {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      svc.debugSeed(<Announcement>[ann(3, 1), ann(2, 1), ann(1, 3)]);
      // 级别 3 未读 → 会弹窗，同时也算未读
      expect(svc.unreadCount, 3);
      expect(svc.popup?.id, 1);
    });

    test('级别 2 展示即算告知：横幅有、红点里没有它', () {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      svc.debugSeed(<Announcement>[ann(4, 1), ann(3, 2)]);
      expect(svc.banner?.id, 3);
      expect(svc.popup, isNull);
      // 4 是级别 1，未读；3 已经算告知
      expect(svc.unreadCount, 1);
    });

    test('点 × 关掉横幅', () {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      svc.debugSeed(<Announcement>[ann(3, 2)]);
      expect(svc.banner, isNotNull);
      svc.dismissBanner();
      expect(svc.banner, isNull);
    });

    test('确认弹窗后 popup 清空，且记进本地', () async {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      svc.debugSeed(<Announcement>[ann(7, 3)]);
      final Announcement? popup = svc.popup;
      expect(popup, isNotNull);

      await svc.confirmPopup(popup!);
      expect(svc.popup, isNull);
      expect(svc.unreadCount, 0);
      expect(settings.readRaw('ann.seen.v1'), contains('7'));
    });

    test('markAllRead 清空所有红点', () async {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      svc.debugSeed(<Announcement>[
        ann(5, 1),
        ann(4, 1),
        ann(3, 2),
      ]);
      expect(svc.unreadCount, greaterThan(0));
      await svc.markAllRead();
      expect(svc.unreadCount, 0);
      expect(svc.hasUnread, isFalse);
    });

    test('级别 4 确认后红点归零，但下次启动（同一份数据）还会弹', () async {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      svc.debugSeed(<Announcement>[ann(9, 4)]);
      await svc.confirmPopup(svc.popup!);
      expect(svc.unreadCount, 0);

      // 模拟下一次启动：已读集合里已经有 9，但级别 4 不看它
      svc.debugSeed(<Announcement>[ann(9, 4)], seen: <int>{9});
      expect(svc.popup?.id, 9);
    });

    test('syncHistory 会合并列表并让红点按最新数据算', () {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      svc.debugSeed(<Announcement>[ann(2, 1)]);
      expect(svc.unreadCount, 1);

      svc.syncHistory(<Announcement>[ann(3, 1), ann(2, 1)]);
      expect(svc.items.length, 2);
      expect(svc.unreadCount, 2);
    });

    test('未拉过数据时未读数是 0（而不是瞎猜）', () {
      final AnnouncementService svc = AnnouncementService(settings: settings);
      expect(svc.loaded, isFalse);
      expect(svc.unreadCount, 0);
      expect(svc.hasUnread, isFalse);
    });
  });

  group('formatDateTimeExact', () {
    test('补零到 yyyy-MM-dd HH:mm', () {
      expect(
        formatDateTimeExact(DateTime(2026, 1, 5, 7, 3)),
        '2026-01-05 07:03',
      );
    });

    test('null 显示「时间未知」', () {
      expect(formatDateTimeExact(null), '时间未知');
    });
  });
}

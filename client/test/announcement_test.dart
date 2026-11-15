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

void main() {
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

// lib/data/models/announcement.dart
//
// 站点公告：标题、内容、发布时间。
//
// 服务端返回的 publishedAt 是**带 Z 的 ISO 字符串**（UTC）。
// 这里统一解析成 `DateTime`（UTC），显示时再 `.toLocal()` ——
// 直接把字符串贴到界面上会显示服务器时间，用户会以为是「早上 9 点发的」，
// 而实际上那是 UTC 的 9 点。

import 'json_utils.dart';

class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.content,
    this.publishedAt,
  });

  final int id;
  final String title;
  final String content;

  /// 发布时间（UTC）。服务端没给或格式不对时为 null。
  final DateTime? publishedAt;

  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      publishedAt: asDateTime(json['publishedAt']),
    );
  }

  /// 发布时间的人话形式：`2026-11-15 09:30`
  String get publishedLabel => formatDateTimeExact(publishedAt);
}

/// 一页公告。服务端用 offset 分页（公告是短列表，游标没有意义）。
class AnnouncementPage {
  const AnnouncementPage({
    this.items = const <Announcement>[],
    this.hasMore = false,
    this.limit = 20,
    this.offset = 0,
  });

  final List<Announcement> items;
  final bool hasMore;
  final int limit;
  final int offset;

  int get nextOffset => offset + items.length;

  factory AnnouncementPage.fromJson(Map<String, dynamic> json, Map<String, dynamic> meta) {
    final List<dynamic> raw = json['announcements'] is List
        ? json['announcements'] as List<dynamic>
        : const <dynamic>[];
    return AnnouncementPage(
      items: raw
          .whereType<Map<dynamic, dynamic>>()
          .map(
            (Map<dynamic, dynamic> e) => Announcement.fromJson(
              e.map<String, dynamic>(
                (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
              ),
            ),
          )
          .toList(),
      hasMore: meta['hasMore'] == true,
      limit: (meta['limit'] as num?)?.toInt() ?? 20,
      offset: (meta['offset'] as num?)?.toInt() ?? 0,
    );
  }
}

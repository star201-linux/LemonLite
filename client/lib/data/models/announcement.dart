// lib/data/models/announcement.dart
//
// 站点公告：标题、内容、发布时间。
//
// 服务端返回的 publishedAt 是**带 Z 的 ISO 字符串**（UTC）。
// 这里统一解析成 `DateTime`（UTC），显示时再 `.toLocal()` ——
// 直接把字符串贴到界面上会显示服务器时间，用户会以为是「早上 9 点发的」，
// 而实际上那是 UTC 的 9 点。

import 'json_utils.dart';

/// 公告的打扰级别。数字越大越「吵」。
///
/// 服务端存 1~4，客户端只认这四个值；收到别的（老服务端没这个字段、
/// 或者被人手改过库）一律当 [quiet] —— 「安静地挂个红点」是最不会出错的兜底，
/// 反过来把未知值当「每次弹」就是灾难。
abstract final class AnnouncementLevel {
  /// 只在「设置 → 公告」上挂数字红点，不主动打扰
  static const int quiet = 1;

  /// 市场页顶部一条横幅，可关掉；关掉或下次启动就没了
  static const int banner = 2;

  /// 启动弹窗，确认一次后这台设备不再出现
  static const int once = 3;

  /// 启动弹窗，**每次启动都弹**，直到下一条公告发布
  static const int sticky = 4;
}

class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.content,
    this.level = AnnouncementLevel.quiet,
    this.publishedAt,
  });

  final int id;
  final String title;
  final String content;

  /// 1~4，见 [AnnouncementLevel]
  final int level;

  /// 发布时间（UTC）。服务端没给或格式不对时为 null。
  final DateTime? publishedAt;

  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      level: _parseLevel(json['level']),
      publishedAt: asDateTime(json['publishedAt']),
    );
  }

  /// 宽容读 level：`3`、`"3"` 都认，认不出就当 1。
  ///
  /// 不直接写 `as num?` —— 那个在遇到字符串时会**抛 TypeError**，
  /// 一条字段类型不对的公告就能让整个列表解析失败。公告是通知，
  /// 宁可把它降级成「安静的红点」，也不能让 App 打不开公告页。
  static int _parseLevel(Object? raw) {
    final int value;
    if (raw is num) {
      value = raw.toInt();
    } else if (raw is String) {
      value = int.tryParse(raw.trim()) ?? AnnouncementLevel.quiet;
    } else {
      value = AnnouncementLevel.quiet;
    }
    return value.clamp(AnnouncementLevel.quiet, AnnouncementLevel.sticky);
  }

  /// 发布时间的人话形式：`2026-11-15 09:30`
  String get publishedLabel => formatDateTimeExact(publishedAt);

  /// 会弹窗的级别
  bool get isPopup =>
      level == AnnouncementLevel.once || level == AnnouncementLevel.sticky;
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

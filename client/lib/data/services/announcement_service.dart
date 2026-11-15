// lib/data/services/announcement_service.dart
//
// 站点公告的客户端出口 + 「谁已经被告知过」的本地状态。
//
// 接口（都不需要登录）：
//   GET /api/announcements?limit&offset      已发布的公告，按发布时间倒序
//   GET /api/announcements/latest            最新一条（老接口，仍保留）
//
// 为什么这个类是 ChangeNotifier 而不是一堆纯函数：
//   公告的提醒方式**取决于用户读没读过**，而「读过」是本机状态。
//   红点（设置页）、横幅（市场页）、弹窗（启动）三处显示同一个数字/同一条内容，
//   若由三个页面各自去拉数据、各自判断，必然出现「红点没了但弹窗又弹一次」。
//   状态集中在这里，三个地方只负责画。
//
// 四级提醒的规则（服务端 announcements.level）：
//   1  只挂红点。进公告页就全清。
//   2  市场页顶部横幅。**展示即算告知**：点 × 或下次启动都不再出现。
//   3  启动弹窗。点确定后这台设备不再弹。
//   4  启动弹窗，每次都弹 —— 直到下一条公告发布（也就是「只有最新一条能是 4」）。
//
// 统一用一个 `ann.seen` 集合表示「这台设备已经被告知过哪些公告」：
//   * 红点 = 没被告知过的条数；
//   * L2 展示、L3 确认、进公告页都往里加；
//   * L4 **不看**这个集合（它的语义是「直到下一条」，不是「直到读过」）。
//
// 服务器地址每次请求都从 SettingsService 实时读，开发者改完地址立刻生效。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/globals.dart';
import '../models/announcement.dart';
import 'settings_service.dart';

/// 「这条公告该用哪种方式提醒」的判断结果。
///
/// 单独抽成一个类，是为了让这条规则能被单测覆盖 ——
/// 它决定了「用户会不会在打开 App 的第一秒被打断」，
/// 而它本身是纯逻辑，没有任何理由必须挂在网络请求后面。
class PendingAnnouncement {
  const PendingAnnouncement(this.announcement, {required this.asPopup});

  final Announcement announcement;

  /// true = 弹窗（L3 / L4），false = 市场页横幅（L2）
  final bool asPopup;
}

/// 从「按发布时间倒序的公告列表」里挑出**这一条**要提醒的公告。
///
/// 规则（详见文件头的四级说明）：
///   * 从新到旧扫，第一条需要提醒的就是它 —— 一次启动只打扰一次；
///   * L1 跳过（只挂红点，不算「主动提醒」）；
///   * L4 只有在它仍是**最新一条**时才弹（「直到下一条公告发布」）；
///   * L3 / L2 需要没被标记为已告知。
PendingAnnouncement? pickPendingAnnouncement(
  List<Announcement> items,
  Set<int> seen,
) {
  if (items.isEmpty) return null;
  final int latestId = items.first.id;
  for (final Announcement a in items) {
    if (a.level == AnnouncementLevel.quiet) continue;

    if (a.level == AnnouncementLevel.sticky) {
      // 已经有更新公告发布了 → 这条不再弹。
      // 用 continue 而不是 return：更旧的未读 L3 仍然该提醒，
      // 「这个 L4 退役了」不等于「所有老公告都不用管了」。
      if (a.id != latestId) continue;
      return PendingAnnouncement(a, asPopup: true);
    }

    if (seen.contains(a.id)) continue;

    if (a.level == AnnouncementLevel.once) {
      return PendingAnnouncement(a, asPopup: true);
    }

    if (a.level == AnnouncementLevel.banner) {
      return PendingAnnouncement(a, asPopup: false);
    }
  }
  return null;
}

/// 带状态的公告失败（历史页要显示「为什么是空的」）
class AnnouncementException implements Exception {
  const AnnouncementException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AnnouncementException($code): $message';
}

class AnnouncementService extends ChangeNotifier {
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

  /// 已告知过的公告 id。持久化在本地，**跨启动**。
  static const String _kSeenKey = 'ann.seen.v1';

  /// 这个集合的上限。一年几十条公告，300 条足够覆盖好几年；
  /// 不设上限的话，一个跑了几年的设备每次启动都要解析一个越来越大的数组。
  static const int _seenLimit = 300;

  /// 启动时拉多少条算「未读」。公告是短列表，50 条覆盖几个月。
  static const int _bootstrapLimit = 50;

  String get _base => _settings.serverUrl.trim();

  // ---------------------------------------------------------------- 状态

  List<Announcement> _items = const <Announcement>[];
  final Set<int> _seen = <int>{};

  /// 本次启动要展示的横幅（L2）。展示过就清掉，不会跨启动留存。
  Announcement? _banner;

  /// 本次启动要弹的窗（L3 未确认 / L4 最新）。
  Announcement? _popup;

  bool _loaded = false;
  bool _bootstrapping = false;

  /// 已发布的公告（倒序）。公告页之外的 UI 只用到条数和未读数。
  List<Announcement> get items => List<Announcement>.unmodifiable(_items);

  /// 是否成功拉到过公告列表。没拉到时红点一律不显示 ——
  /// 「红点 0」和「不知道有几条」在用户眼里是两回事，
  /// 用 0 掩盖失败会让「怎么没有红点」变成一个查不出来的问题。
  bool get loaded => _loaded;

  /// 未读条数（红点上的数字）
  int get unreadCount {
    if (!_loaded) return 0;
    int n = 0;
    for (final Announcement a in _items) {
      if (!_seen.contains(a.id)) n++;
    }
    return n;
  }

  bool get hasUnread => unreadCount > 0;

  /// 市场页顶部要展示的横幅；null 表示不显示。
  Announcement? get banner => _banner;

  /// 启动时要弹的窗；null 表示不弹。
  Announcement? get popup => _popup;

  // ---------------------------------------------------------------- 启动

  /// 拉一次公告并按级别决定横幅 / 弹窗。AppShell 启动时调一次。
  ///
  /// 失败**静默**：断网、服务器没起、地址填错都很常见，
  /// 不该在打开 App 的第一秒甩一个错误弹窗。公告页自己有错误态。
  Future<void> bootstrap() async {
    if (_bootstrapping) return;
    _bootstrapping = true;
    try {
      _loadSeen();
      final AnnouncementPage page = await fetchHistory(limit: _bootstrapLimit);
      _items = page.items;
      _loaded = true;
      _pickPending();
      notifyListeners();
    } on AnnouncementException catch (e) {
      lemonLogError('Announcement', '启动拉公告失败：${e.code} ${e.message}');
    } catch (e) {
      lemonLogError('Announcement', '启动拉公告失败：$e');
    } finally {
      _bootstrapping = false;
    }
  }

  /// 按 [pickPendingAnnouncement] 的结论设置本条启动要弹的窗 / 横幅。
  void _pickPending() {
    _popup = null;
    _banner = null;

    final PendingAnnouncement? pending = pickPendingAnnouncement(
      _items,
      _seen,
    );
    if (pending == null) return;

    if (pending.asPopup) {
      _popup = pending.announcement;
      return;
    }

    _banner = pending.announcement;
    // 展示即算告知：用户看到横幅 = 这条公告已经送达。
    // 这样「没点 × 直接杀 App」也不会在下次启动又冒出来。
    markSeen(pending.announcement.id);
  }

  // ---------------------------------------------------------------- 测试注入

  /// 直接塞入一份「服务器已经返回过的列表」，跳过网络。
  ///
  /// 只给测试与预览用：四级提醒的判定（谁弹、谁挂横幅、红点几）全靠
  /// `_pickPending`，而那部分不该只能靠「起一个假 HTTP 服务」来验证。
  @visibleForTesting
  void debugSeed(
    List<Announcement> items, {
    Set<int> seen = const <int>{},
  }) {
    _items = List<Announcement>.unmodifiable(items);
    _seen
      ..clear()
      ..addAll(seen);
    _loaded = true;
    _pickPending();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 交互

  /// 点横幅上的 ×。
  void dismissBanner() {
    if (_banner == null) return;
    _banner = null;
    notifyListeners();
  }

  /// 点弹窗的「确定」。L3 从此不再出现；L4 下次启动还会弹（只是红点归零）。
  Future<void> confirmPopup(Announcement announcement) async {
    _popup = null;
    notifyListeners();
    await markSeen(announcement.id);
  }

  /// 进公告页就算读过了 —— 「点进去，不用点开详细内容，所有小红点就消失」。
  /// 这也符合直觉：列表里标题与正文都铺开了，再要求逐条点开才算读过，
  /// 只是多一层无意义的点击。
  Future<void> markAllRead() async {
    if (_items.isEmpty) {
      notifyListeners();
      return;
    }
    bool changed = false;
    for (final Announcement a in _items) {
      if (_seen.add(a.id)) changed = true;
    }
    if (changed) await _saveSeen();
    // 即使 _seen 没变，_loaded 也可能刚从 false 变 true，红点需要重画
    notifyListeners();
  }

  /// 标记单条已读（同时持久化）
  Future<void> markSeen(int id) async {
    if (!_seen.add(id)) return;
    await _saveSeen();
    // 红点数字变了，但调用方（弹窗/横幅）自己也会 notify，
    // 这里再 notify 一次是幂等的 —— 早点让红点更新比少更新强。
    notifyListeners();
  }

  /// 公告页拉到新数据后同步进内存：红点要以「服务器现在的列表」为准，
  /// 否则用户在别处刚发了一条公告，这台设备还按旧列表算未读。
  void syncHistory(List<Announcement> items) {
    if (items.isEmpty) return;
    final Map<int, Announcement> merged = <int, Announcement>{
      for (final Announcement a in _items) a.id: a,
      for (final Announcement a in items) a.id: a,
    };
    final List<Announcement> sorted = merged.values.toList()
      ..sort((Announcement a, Announcement b) {
        final DateTime? ta = a.publishedAt;
        final DateTime? tb = b.publishedAt;
        if (ta != null && tb != null && ta != tb) return tb.compareTo(ta);
        return b.id.compareTo(a.id);
      });
    _items = sorted;
    _loaded = true;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 持久化

  void _loadSeen() {
    final String? raw = _settings.readRaw(_kSeenKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final Object? item in decoded) {
        if (item is num) _seen.add(item.toInt());
      }
    } catch (e) {
      // 坏数据（版本回滚、手改 prefs）只影响红点，不值得打断启动
      lemonLogError('Announcement', '已读记录解析失败，按全部未读处理：$e');
    }
  }

  Future<void> _saveSeen() async {
    // 只留最近的 N 条：按 id 倒序（id 越大越新）
    final List<int> ids = _seen.toList()..sort((int a, int b) => b.compareTo(a));
    final List<int> trimmed = ids.length > _seenLimit
        ? ids.sublist(0, _seenLimit)
        : ids;
    if (trimmed.length != _seen.length) {
      _seen
        ..clear()
        ..addAll(trimmed);
    }
    await _settings.writeRaw(_kSeenKey, jsonEncode(trimmed));
  }

  // ---------------------------------------------------------------- 网络

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
  /// 启动流程走 [bootstrap]（它要整份列表才能算未读），
  /// 这个方法留着是因为「只想知道最新一条」的场景仍然合理。
  Future<Announcement?> fetchLatest() async {
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        '$_base/api/announcements/latest',
      );
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

  /// 公告列表（按发布时间倒序）。失败**抛异常** —— 历史页需要告诉用户为什么是空的。
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
                (Object? k, Object? v) =>
                    MapEntry<String, dynamic>(k.toString(), v),
              )
            : <String, dynamic>{},
        meta is Map
            ? meta.map<String, dynamic>(
                (Object? k, Object? v) =>
                    MapEntry<String, dynamic>(k.toString(), v),
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

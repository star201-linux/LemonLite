// lib/data/services/application_registry.dart
//
// 「应用管理」的数据层：**应用清单的唯一真相来源**。
//
// 为什么要有这么一个东西：
//   在这之前，应用清单散在三处 —— 权限服务里的 known_apps 注册表、
//   SharedPreferences 里出现过的 appId、以及两个 appfiles 目录名。
//   每一处都只能看到一部分真相，于是「权限管理器里列着某个小程序、
//   应用管理里却没有」这种不一致迟早会发生。
//   现在统一成一份：谁要列应用，就问这里。
//
// 记录什么：
//   id / name / icon / url  —— 展示与再打开用
//   firstSeenAt / lastOpenedAt —— 排序与「多久没用了」的提示
//
// 为什么仍然要持久化而不是每次扫目录：小程序是远程 HTML，没有「安装」概念，
// 目录里也不会留下 tarball。打开过就是唯一可靠的「这个 appId 存在过」的证据。
// 但目录扫描仍然被当作**补充来源**（用户手工往 appfiles 里放东西也算数），
// 只是它补进来的条目不会带图标与名字，只有 id。

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/globals.dart';
import 'settings_service.dart';

/// 一个登记在案的应用（小程序）。
@immutable
class RegisteredApp {
  const RegisteredApp({
    required this.id,
    required this.name,
    this.icon,
    this.url,
    this.category,
    this.firstSeenAt,
    this.lastOpenedAt,
  });

  final String id;
  final String name;

  /// 图标地址（可能是相对路径，展示前用 resolveIcon 解析）
  final String? icon;

  /// 小程序的入口地址
  final String? url;

  /// 市场里的分类 id
  final String? category;

  final DateTime? firstSeenAt;
  final DateTime? lastOpenedAt;

  /// 展示名：没记名字时退化成 id（总比空白强）
  String get displayName => name.trim().isEmpty ? id : name;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    if (icon != null) 'icon': icon,
    if (url != null) 'url': url,
    if (category != null) 'category': category,
    if (firstSeenAt != null) 'first': firstSeenAt!.toIso8601String(),
    if (lastOpenedAt != null) 'last': lastOpenedAt!.toIso8601String(),
  };

  static RegisteredApp? fromJson(Map<String, dynamic> json) {
    final String id = json['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    return RegisteredApp(
      id: id,
      name: json['name']?.toString() ?? id,
      icon: _cleanOrNull(json['icon']),
      url: _cleanOrNull(json['url']),
      category: _cleanOrNull(json['category']),
      firstSeenAt: DateTime.tryParse(json['first']?.toString() ?? ''),
      lastOpenedAt: DateTime.tryParse(json['last']?.toString() ?? ''),
    );
  }

  static String? _cleanOrNull(Object? value) {
    final String text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  RegisteredApp copyWith({
    String? name,
    String? icon,
    String? url,
    String? category,
    DateTime? firstSeenAt,
    DateTime? lastOpenedAt,
  }) => RegisteredApp(
    id: id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    url: url ?? this.url,
    category: category ?? this.category,
    firstSeenAt: firstSeenAt ?? this.firstSeenAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
  );
}

/// 应用清单的读写与合并。
class ApplicationRegistry extends ChangeNotifier {
  ApplicationRegistry._(this._settings);

  final SettingsService _settings;

  static ApplicationRegistry? _instance;

  static ApplicationRegistry get instance {
    final ApplicationRegistry? s = _instance;
    if (s == null) {
      throw StateError('ApplicationRegistry 尚未初始化，请先看 main() 里的 init 顺序');
    }
    return s;
  }

  /// 在 main() 里、SettingsService.init() 之后调用
  static ApplicationRegistry init() =>
      _instance = ApplicationRegistry._(SettingsService.instance);

  /// 持久化 key。沿用 perm.known_apps 的**新名字**，
  /// 旧 key 由 [_migrateLegacy] 一次性搬过来（否则用户已有的应用清单会凭空消失）。
  static const String _kApps = 'apps.registry';

  /// 旧版权限服务用的 key
  static const String _kLegacyApps = 'perm.known_apps';

  bool _migrated = false;

  // ------------------------------------------------------------------ 读

  /// 全部应用，按「最近打开」倒序（没打开过的排后面，再按名字）
  List<RegisteredApp> get all {
    _migrateLegacy();
    final List<RegisteredApp> list = _read();
    list.sort(_byRecent);
    return list;
  }

  int get count => all.length;

  bool contains(String appId) => all.any((RegisteredApp a) => a.id == appId);

  RegisteredApp? byId(String appId) {
    for (final RegisteredApp app in all) {
      if (app.id == appId) return app;
    }
    return null;
  }

  String nameOf(String appId) => byId(appId)?.displayName ?? appId;

  static int _byRecent(RegisteredApp a, RegisteredApp b) {
    final DateTime da = a.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final DateTime db = b.lastOpenedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final int byTime = db.compareTo(da);
    return byTime != 0 ? byTime : a.displayName.compareTo(b.displayName);
  }

  // ------------------------------------------------------------------ 写

  /// 登记 / 更新一个应用。名字、图标、地址会随市场数据刷新（改过名的条目能自动纠正）。
  Future<void> record({
    required String appId,
    required String name,
    String? icon,
    String? url,
    String? category,
    bool opened = false,
  }) async {
    final String id = appId.trim();
    if (id.isEmpty) return;

    final List<RegisteredApp> list = _read();
    final int index = list.indexWhere((RegisteredApp a) => a.id == id);
    final DateTime now = DateTime.now();

    if (index >= 0) {
      final RegisteredApp existing = list[index];
      list[index] = existing.copyWith(
        name: name.trim().isEmpty ? existing.name : name.trim(),
        icon: _clean(icon),
        url: _clean(url),
        category: _clean(category),
        firstSeenAt: existing.firstSeenAt ?? now,
        lastOpenedAt: opened ? now : existing.lastOpenedAt,
      );
    } else {
      list.add(
        RegisteredApp(
          id: id,
          name: name.trim().isEmpty ? id : name.trim(),
          icon: _clean(icon),
          url: _clean(url),
          category: _clean(category),
          firstSeenAt: now,
          lastOpenedAt: opened ? now : null,
        ),
      );
    }
    await _write(list);
    notifyListeners();
  }

  /// 打开小程序时调用（等价于 record(opened: true)，只是参数少一点）
  Future<void> recordOpen(String appId, String name) =>
      record(appId: appId, name: name, opened: true);

  /// 只登记、不算「打开过」（例如从市场数据里把条目带进来）
  Future<void> ensureKnown({
    required String appId,
    required String name,
    String? icon,
    String? url,
    String? category,
  }) => record(appId: appId, name: name, icon: icon, url: url, category: category);

  /// 把目录扫描发现的、清单里还没有的 appId 补进来。
  ///
  /// 这类条目只有 id（没有名字与图标），因为目录名就是全部线索。
  /// 之所以要补：用户可能手工往 appfiles 里丢了东西，或者数据是从旧版本
  /// 留下来的 —— 它们占着磁盘，就该在应用管理里看得见、清得掉。
  Future<int> adoptOrphans(Iterable<String> appIds) async {
    final List<RegisteredApp> list = _read();
    final Set<String> existing = list.map((RegisteredApp a) => a.id).toSet();
    int added = 0;
    for (final String raw in appIds) {
      final String id = raw.trim();
      if (id.isEmpty || existing.contains(id)) continue;
      existing.add(id);
      list.add(RegisteredApp(id: id, name: id));
      added++;
    }
    if (added > 0) {
      await _write(list);
      notifyListeners();
    }
    return added;
  }

  /// 从应用管理里移除一个应用。
  ///
  /// 只动**清单**与权限记录；磁盘数据由调用方决定是否一起清
  /// （应用管理页会把「同时清除数据」交给用户勾选）。
  Future<void> remove(String appId) async {
    final List<RegisteredApp> list = _read()
      ..removeWhere((RegisteredApp a) => a.id == appId);
    await _write(list);
    await _clearPermissionRecords(appId);
    notifyListeners();
  }

  /// 批量移除
  Future<void> removeAll(Iterable<String> appIds) async {
    final Set<String> targets = appIds.toSet();
    final List<RegisteredApp> list = _read()
      ..removeWhere((RegisteredApp a) => targets.contains(a.id));
    await _write(list);
    for (final String id in targets) {
      await _clearPermissionRecords(id);
    }
    notifyListeners();
  }

  /// 清掉某个 appId 在权限侧的记录（决定 + 申请记录）。
  ///
  /// 刻意写在这里而不是让调用方自己拼 key：权限记录的 key 格式是权限服务的
  /// 内部细节，应用管理只需要知道「把这个应用的一切抹掉」。
  Future<void> _clearPermissionRecords(String appId) async {
    final List<String> keys = <String>[];
    for (final String id in _permissionIds) {
      keys.add('perm.decision.$appId.$id');
      keys.add('perm.usage.$appId.$id');
    }
    await _settings.removeMany(keys);
  }

  /// 权限 id 清单。
  ///
  /// 这里刻意**硬编码**而不是 import MiniappPermission：应用管理要清的是
  /// 「历史上写过的所有权限记录」，包括那些已经从枚举里删掉的旧权限 id ——
  /// 如果只遍历当前枚举，旧版本的残留记录永远清不掉。
  static const List<String> _permissionIds = <String>[
    // 当前版本
    'camera',
    'microphone',
    'sdcard',
    'bluetooth',
    'nfc',
    // 历史 id（sdcard 的旧名字）：升级前写下的决定要能一起清掉
    'allFiles',
    // 历史版本（已不再是权限，但记录可能还在盘上）
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

  // -------------------------------------------------------------- 持久化

  List<RegisteredApp> _read() {
    final String? raw = _settings.readRaw(_kApps);
    if (raw == null || raw.isEmpty) return <RegisteredApp>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <RegisteredApp>[];
      final List<RegisteredApp> result = <RegisteredApp>[];
      for (final Object? item in decoded) {
        if (item is! Map) continue;
        final RegisteredApp? app = RegisteredApp.fromJson(
          item.map<String, dynamic>(
            (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
        if (app != null) result.add(app);
      }
      return result;
    } catch (e) {
      lemonLog('AppRegistry', '应用清单损坏，重建：$e');
      return <RegisteredApp>[];
    }
  }

  Future<void> _write(List<RegisteredApp> apps) async {
    await _settings.writeRaw(
      _kApps,
      jsonEncode(apps.map((RegisteredApp a) => a.toJson()).toList()),
    );
  }

  /// 把旧版的 perm.known_apps 搬到新 key 下（只做一次）。
  ///
  /// 不搬的话，升级后用户会看到应用清单凭空清空 —— 那是最糟的一种回归。
  void _migrateLegacy() {
    if (_migrated) return;
    _migrated = true;

    if (_settings.readRaw(_kApps) != null) return;
    final String? legacy = _settings.readRaw(_kLegacyApps);
    if (legacy == null || legacy.isEmpty) return;

    try {
      final Object? decoded = jsonDecode(legacy);
      if (decoded is! List) return;
      final List<RegisteredApp> migrated = <RegisteredApp>[];
      for (final Object? item in decoded) {
        if (item is! Map) continue;
        final String id = item['id']?.toString().trim() ?? '';
        if (id.isEmpty) continue;
        migrated.add(
          RegisteredApp(
            id: id,
            name: item['name']?.toString() ?? id,
            firstSeenAt: DateTime.tryParse(item['first']?.toString() ?? ''),
            lastOpenedAt: DateTime.tryParse(item['last']?.toString() ?? ''),
          ),
        );
      }
      if (migrated.isEmpty) return;
      // 这里不 await：迁移是「顺手补一下」，不该阻塞首次读取。
      // 写失败也只是下次启动再迁一次，没有副作用。
      _write(migrated).then((_) {
        lemonLog('AppRegistry', '已从 perm.known_apps 迁移 ${migrated.length} 个应用');
      });
    } catch (e) {
      lemonLog('AppRegistry', '迁移旧注册表失败（忽略）：$e');
    }
  }

  static String? _clean(String? value) {
    final String text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

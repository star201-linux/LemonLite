
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
    this.permissionIds = const <String>[],
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

  final List<String> permissionIds;

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
    if (permissionIds.isNotEmpty) 'permissions': permissionIds,
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
      permissionIds: _cleanList(json['permissions']),
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
    List<String>? permissionIds,
    DateTime? firstSeenAt,
    DateTime? lastOpenedAt,
  }) => RegisteredApp(
    id: id,
    name: name ?? this.name,
    icon: icon ?? this.icon,
    url: url ?? this.url,
    category: category ?? this.category,
    permissionIds: permissionIds ?? this.permissionIds,
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
    List<String>? permissions,
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
        // 传 null = 这次没带图标信息，保留原值（安装完成时只补权限就是这种）
        icon: icon == null ? null : _clean(icon),
        url: url == null ? null : _clean(url),
        category: category == null ? null : _clean(category),
        permissionIds: permissions == null
            ? existing.permissionIds
            : _cleanList(permissions),
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
          permissionIds: _cleanList(permissions),
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
    List<String>? permissions,
  }) => record(
    appId: appId,
    name: name,
    icon: icon,
    url: url,
    category: category,
    permissions: permissions,
  );

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

  Future<void> _clearPermissionRecords(String appId) async {
    final List<String> keys = <String>[];
    for (final String id in _permissionIds) {
      keys.add('perm.decision.$appId.$id');
      keys.add('perm.usage.$appId.$id');
    }
    // 定位的精度 / 后台是单独一条键，不在上面的 id 清单里
    keys.add('perm.location.$appId');
    await _settings.removeMany(keys);
  }

  static const List<String> _permissionIds = <String>[
    // 当前版本（与 MiniappPermission.values 的 id 保持一致）
    'camera',
    'microphone',
    'displayCapture',
    'speakerSelection',
    'pictureInPicture',
    'location',
    'accelerometer',
    'gyroscope',
    'magnetometer',
    'ambientLight',
    'proximity',
    'gamepad',
    'vibrate',
    'midi',
    'bluetooth',
    'usb',
    'serial',
    'nfc',
    'networkInfo',
    'webauthn',
    'clipboard',
    'sdcard',
    'notifications',
    'battery',
    'deviceMemory',
    'print',
    // 历史 id（0.3 把定位合并成一项；sdcard 原名 allFiles）
    'geolocationFine',
    'geolocationCoarse',
    'geolocation',
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
    'plugin',
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

List<String> _cleanList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .map((Object? item) => item?.toString().trim() ?? '')
      .where((String item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

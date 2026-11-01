// lib/data/services/settings_service.dart
//
// 设置持久化服务（SharedPreferences 的唯一入口）。
//
// 阶段一需要持久化的东西只有 4 类：
//   1. 市场服务器地址（开发者模式可改）
//   2. 是否已进入开发者模式
//   3. 主题偏好（模式 / 种子色 / 是否动态取色）
//   4. 上次成功同步 index.json 的时间
//
// 这里做成全局单例：MarketRepository、BridgeApi 都不是 Widget，
// 通过 Provider 注入会很啰嗦，单例更直接。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/globals.dart';
import '../../theme/app_theme.dart';

class SettingsService extends ChangeNotifier {
  SettingsService._(this._prefs);

  final SharedPreferences _prefs;

  static SettingsService? _instance;

  /// 全局单例（必须先 await SettingsService.init()）
  static SettingsService get instance {
    final SettingsService? s = _instance;
    if (s == null) {
      throw StateError('SettingsService 尚未初始化，请先在 main() 中 await SettingsService.init()');
    }
    return s;
  }

  /// 在 main() 中调用一次
  static Future<SettingsService> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return _instance = SettingsService._(prefs);
  }

  // ---------------------------------------------------------------- keys

  static const String _kServerUrl = 'settings.server_url';
  static const String _kDeveloperMode = 'settings.developer_mode';
  static const String _kThemeMode = 'settings.theme_mode';
  static const String _kSeedColor = 'settings.seed_color';
  static const String _kUseDynamicColor = 'settings.use_dynamic_color';
  static const String _kLastSyncAt = 'settings.last_sync_at';

  /// 小程序 storage 的键前缀（和宿主设置项隔离，卸载小程序时按前缀清理即可）
  static const String miniappStoragePrefix = 'miniapp.storage.';

  // ------------------------------------------------- 市场服务器地址

  /// 当前生效的服务器地址。统一去掉结尾的 '/'，
  /// 保证拼出来的 `{server}/index.json` 不会出现 `//`。
  String get serverUrl {
    final String raw = _prefs.getString(_kServerUrl)?.trim() ?? '';
    if (raw.isEmpty) return kDefaultServerUrl;
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  /// 是否还在使用默认地址（开发者页用来决定「重置」按钮是否可点）
  bool get isDefaultServer => serverUrl == kDefaultServerUrl;

  /// 是否是自定义地址（首页用来提示「当前使用自定义服务器」）
  bool get isCustomServer => !isDefaultServer;

  /// 保存服务器地址。传默认值等价于重置。
  Future<void> setServerUrl(String url) async {
    String value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty || value == kDefaultServerUrl) {
      await _prefs.remove(_kServerUrl);
    } else {
      await _prefs.setString(_kServerUrl, value);
    }
    notifyListeners();
  }

  /// 重置为默认服务器地址
  Future<void> resetServerUrl() async {
    await _prefs.remove(_kServerUrl);
    notifyListeners();
  }

  // ------------------------------------------------------- 开发者模式

  bool get developerMode => _prefs.getBool(_kDeveloperMode) ?? false;

  Future<void> setDeveloperMode(bool value) async {
    await _prefs.setBool(_kDeveloperMode, value);
    notifyListeners();
  }

  // --------------------------------------------------------- 主题偏好

  ThemeMode get themeMode {
    switch (_prefs.getString(_kThemeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(
      _kThemeMode,
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      },
    );
    notifyListeners();
  }

  /// 手动选定的种子色（动态取色关闭时才生效）
  Color get seedColor {
    final int? value = _prefs.getInt(_kSeedColor);
    if (value == null) return kDefaultSeedColor;
    return Color(value);
  }

  Future<void> setSeedColor(Color color) async {
    await _prefs.setInt(_kSeedColor, color.toARGB32());
    notifyListeners();
  }

  /// 是否使用 Android 12+ 的系统壁纸色。默认开启（系统不支持时会自动回落到种子色）。
  bool get useDynamicColor => _prefs.getBool(_kUseDynamicColor) ?? true;

  Future<void> setUseDynamicColor(bool value) async {
    await _prefs.setBool(_kUseDynamicColor, value);
    notifyListeners();
  }

  // --------------------------------------------------------- 同步记录

  DateTime? get lastSyncAt {
    final String? raw = _prefs.getString(_kLastSyncAt);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setLastSyncAt(DateTime time) async {
    await _prefs.setString(_kLastSyncAt, time.toIso8601String());
    notifyListeners();
  }

  // ------------------------------------------------- 小程序 storage 用

  /// 拼接小程序 storage 的完整 key：`miniapp.storage.{appId}.{key}`
  static String miniappStorageKey(String appId, String key) =>
      '$miniappStoragePrefix$appId.$key';

  /// 列出某个小程序写入的全部 key
  List<String> miniappStorageKeys(String appId) {
    final String prefix = '$miniappStoragePrefix$appId.';
    return _prefs
        .getKeys()
        .where((String k) => k.startsWith(prefix))
        .map((String k) => k.substring(prefix.length))
        .toList(growable: false);
  }

  /// 小程序 storage 的「原始 key → 原始值」快照。
  ///
  /// 存储管理页要展示每个键占多少字节，所以这里返回的是**带前缀的完整 key**，
  /// 调用方自己决定怎么剥前缀（也能拿它直接删除）。
  Map<String, String> miniappStorageEntries(String appId) {
    final String prefix = '$miniappStoragePrefix$appId.';
    final Map<String, String> result = <String, String>{};
    for (final String key in _prefs.getKeys()) {
      if (!key.startsWith(prefix)) continue;
      final String? value = _prefs.getString(key);
      if (value != null) result[key] = value;
    }
    return result;
  }

  /// 已经从 storage 数据里出现过的 appId 集合。
  ///
  /// 用途：权限管理 / 存储管理页要列出「用户实际用过的小程序」，
  /// 而这些数据是唯一不会骗人的来源（注册表可能被清掉，storage 不会）。
  Set<String> miniappStorageAppIds() {
    final Set<String> result = <String>{};
    for (final String key in _prefs.getKeys()) {
      if (!key.startsWith(miniappStoragePrefix)) continue;
      final String rest = key.substring(miniappStoragePrefix.length);
      final int dot = rest.indexOf('.');
      // 没有 '.' 说明是异常残留，跳过而不是猜
      if (dot <= 0) continue;
      result.add(rest.substring(0, dot));
    }
    return result;
  }

  // ------------------------------------------------------- 通用原始读写

  String? readRaw(String key) => _prefs.getString(key);
  Future<bool> writeRaw(String key, String value) => _prefs.setString(key, value);
  Future<bool> removeRaw(String key) => _prefs.remove(key);

  /// 批量删除。返回实际删掉的条数。
  Future<int> removeMany(Iterable<String> keys) async {
    int removed = 0;
    for (final String key in keys) {
      if (await _prefs.remove(key)) removed++;
    }
    return removed;
  }
}

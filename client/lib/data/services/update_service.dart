// lib/data/services/update_service.dart
//
// 「小程序有没有新版本」的全局状态。
//
// 为什么从 HomePage 里搬出来：
//   更新检查的结果现在有两个消费方 —— 主页的提示条，与应用管理页的
//   小红点 / 单个应用的「可更新」标记。以前检查逻辑写在主页 State 里，
//   换个 Tab 就看不到结果；而且主页不打开就永远不检查。
//   现在它是**唯一真相**：启动时查一次（AppShell），打开某个小程序时再单查一次
//   （AppDetailPage），任何页面读同一份结果。
//
// 两种检查：
//   checkAll()  启动时（或应用管理下拉刷新）批量问「哪些已装的版本旧了」；
//   checkOne()  打开某个小程序前问「它现在最新是哪一版」，顺带更新这份状态。
//
// 为什么结果要落盘：
//   小红点必须在**下一次检查回来之前**也存在（冷启动那几秒、断网时）。
//   缓存会随着每次成功检查整体替换；检查失败时保留上一次的结果，
//   而不是把小红点清掉 —— 「网络抖了一下，更新提示消失了」是最糟的体验。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/globals.dart';
import '../models/app_version.dart';
import '../repositories/market_repository.dart';
import 'icon_cache_service.dart';
import 'miniapp_package_service.dart';
import 'settings_service.dart';

class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 持久化 key。带版本号：以后结构变了直接换 key，旧缓存自然失效。
  static const String _kCache = 'updates.cache.v1';

  /// appId → 待更新信息
  final Map<String, PackageUpdate> _updates = <String, PackageUpdate>{};

  bool _checking = false;
  DateTime? _lastCheckedAt;
  bool _restored = false;

  /// 待更新列表（按应用名排序，保证界面顺序稳定）
  List<PackageUpdate> get updates {
    final List<PackageUpdate> list = _updates.values.toList();
    list.sort((PackageUpdate a, PackageUpdate b) => a.name.compareTo(b.name));
    return List<PackageUpdate>.unmodifiable(list);
  }

  int get count => _updates.length;

  bool get hasUpdates => _updates.isNotEmpty;

  bool get checking => _checking;

  DateTime? get lastCheckedAt => _lastCheckedAt;

  PackageUpdate? of(String appId) => _updates[appId];

  bool hasUpdate(String appId) => _updates.containsKey(appId);

  /// 从本地缓存恢复（同步，第一帧就能显示小红点）。
  ///
  /// 只恢复一次；没有缓存 / 缓存坏了都静默跳过。
  void restore() {
    if (_restored) return;
    _restored = true;
    final String? raw = SettingsService.instance.readRaw(_kCache);
    if (raw == null || raw.isEmpty) return;

    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _lastCheckedAt = DateTime.tryParse((decoded['at'] ?? '').toString());
      final Object? list = decoded['updates'];
      if (list is! List) return;
      for (final Object? item in list) {
        if (item is! Map) continue;
        final PackageUpdate? update = PackageUpdate.fromJson(
          item.map<String, dynamic>(
            (Object? k, Object? v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
        if (update != null) _updates[update.appId] = update;
      }
      lemonLog('Updates', '从缓存恢复 ${_updates.length} 个待更新条目');
    } catch (e) {
      lemonLog('Updates', '更新缓存损坏，忽略：$e');
    }
  }

  /// 启动时检查**所有已装小程序**。
  ///
  /// [force] 为 true 时忽略「正在检查」以外的限制（目前没有节流，
  /// 保留参数是为了将来加「5 分钟内不重复请求」时调用方不用改）。
  Future<void> checkAll({
    required MarketRepository repository,
    bool force = false,
  }) async {
    if (_checking) return;
    _checking = true;
    notifyListeners();
    try {
      final List<InstalledPackage> installed = await MiniappPackageService
          .instance
          .installedAll();

      if (installed.isEmpty) {
        // 一个都没装：没有任何可更新项（也顺便清掉旧缓存里已卸载的应用）
        _updates.clear();
        _lastCheckedAt = DateTime.now();
        await _persist();
        return;
      }

      final List<PackageUpdate> result = await repository.checkUpdates(
        installed
            .map((InstalledPackage p) => (id: p.appId, version: p.version))
            .toList(growable: false),
      );

      _updates
        ..clear()
        ..addEntries(
          result.map(
            (PackageUpdate u) => MapEntry<String, PackageUpdate>(u.appId, u),
          ),
        );
      _lastCheckedAt = DateTime.now();
      await _persist();

      // 更新检查顺带把图标缓存下来（失败不影响检查结果）
      for (final PackageUpdate u in result) {
        unawaited(
          IconCacheService.instance.ensure(appId: u.appId, url: u.icon),
        );
      }
      lemonLog(
        'Updates',
        '检查完成：已装 ${installed.length} 个，${_updates.length} 个可更新',
      );
    } catch (e) {
      // 失败保留上一次结果（不清小红点），只记日志
      lemonLog('Updates', '检查所有更新失败：$e');
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// 打开某个小程序前检查它有没有新版本。
  ///
  /// 返回服务端当前版本信息（失败 / 已下架返回 null）。成功时同时更新
  /// 全局的待更新列表 —— 这样即便启动时没查到（当时没网），
  /// 打开一次之后应用管理里也会有小红点。
  Future<AppVersionInfo?> checkOne(
    String appId, {
    required MarketRepository repository,
  }) async {
    try {
      final AppVersionInfo info = await repository.fetchVersion(appId);
      final InstalledPackage? installed = await MiniappPackageService.instance
          .installed(appId);

      if (installed != null &&
          info.hasPackage &&
          installed.version != info.version) {
        _updates[appId] = PackageUpdate(
          appId: appId,
          name: info.name,
          installedVersion: installed.version,
          latestVersion: info.version,
          packageUrl: info.packageUrl,
          entry: info.entry,
          sha256: info.sha256,
          bytes: info.bytes,
          icon: info.icon,
          updatedAt: info.updatedAt,
        );
      } else {
        _updates.remove(appId);
      }
      await _persist();
      notifyListeners();

      unawaited(IconCacheService.instance.ensure(appId: appId, url: info.icon));
      lemonLog('Updates', '$appId 最新版本 ${info.version}');
      return info;
    } on MarketException catch (e) {
      // 404 = 管理员已经从市场下架了它：本地还能打开，但不再有更新
      if (e.code == 'http_404') {
        forget(appId);
      } else {
        lemonLog('Updates', '$appId 版本检查失败：${e.message}');
      }
      return null;
    } catch (e) {
      lemonLog('Updates', '$appId 版本检查失败：$e');
      return null;
    }
  }

  /// 某个应用已经更新 / 被移除：立刻把它的待更新项去掉。
  void forget(String appId) {
    if (_updates.remove(appId) == null) return;
    unawaited(_persist());
    notifyListeners();
  }

  /// 清空全部（调试 / 服务器地址变更时用）
  Future<void> clear() async {
    if (_updates.isEmpty) return;
    _updates.clear();
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final String raw = jsonEncode(<String, dynamic>{
        'at': (_lastCheckedAt ?? DateTime.now()).toIso8601String(),
        'updates': _updates.values
            .map((PackageUpdate u) => u.toJson())
            .toList(),
      });
      await SettingsService.instance.writeRaw(_kCache, raw);
    } catch (e) {
      lemonLog('Updates', '保存更新缓存失败：$e');
    }
  }
}

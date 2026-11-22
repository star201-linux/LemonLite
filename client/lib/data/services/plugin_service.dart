
import 'package:flutter/foundation.dart';

import '../models/bundle_manifest.dart';
import '../repositories/bundle_repository.dart';

class PluginService {
  PluginService._();

  static final PluginService instance = PluginService._();

  static BundleRepository get _repo => BundleRepository.instance;

  // ------------------------------------------------------------ 列表

  /// 全部已安装插件（含停用 / 平台不匹配的）
  Future<List<BundleManifest>> all() => _repo.scan(BundleType.plugin);

  /// 在某台设备上**真正生效**的插件：启用中 + 平台匹配。
  Future<List<BundleManifest>> active() async {
    final Set<String> disabled = await _repo.disabledIds();
    final List<BundleManifest> plugins = await all();
    return plugins
        .where(
          (BundleManifest plugin) =>
              !disabled.contains(plugin.id) && platformMatches(plugin),
        )
        .toList(growable: false);
  }

  Future<bool> isInstalled(String id) async =>
      (await all()).any((BundleManifest plugin) => plugin.id == id);

  Future<bool> isEnabled(BundleManifest plugin) async =>
      !(await _repo.disabledIds()).contains(plugin.id);

  /// 当前平台（供插件判断，也供 UI 显示"这台设备能不能跑"）
  static String get currentPlatformId {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'linux',
    };
  }

  /// 平台是否匹配。`platforms` 为空 = 全平台（老插件没写这一栏时的默认）。
  static bool platformMatches(BundleManifest plugin) {
    if (plugin.platforms.isEmpty) return true;
    return plugin.platforms.contains(currentPlatformId);
  }

  /// `lemonlite.plugins.list()` / 设置页用的总览。
  Future<Map<String, dynamic>> summary() async {
    final List<BundleManifest> plugins = await all();
    final Set<String> disabled = await _repo.disabledIds();
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final BundleManifest plugin in plugins) {
      final bool enabled = !disabled.contains(plugin.id);
      final bool matches = platformMatches(plugin);
      items.add(<String, dynamic>{
        'id': plugin.id,
        'name': plugin.name,
        'version': plugin.version,
        'description': plugin.description,
        'author': plugin.author,
        'type': plugin.type.wireName,
        'platforms': plugin.platforms,
        'capabilities': plugin.capabilities,
        'enabled': enabled,
        'platformSupported': matches,
        'active': enabled && matches,
      });
    }
    return <String, dynamic>{
      'platform': currentPlatformId,
      'count': items.length,
      'plugins': items,
    };
  }
}

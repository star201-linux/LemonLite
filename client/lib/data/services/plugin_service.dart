// lib/data/services/plugin_service.dart
//
// 插件（plugin）服务：宿主能力的**可插拔**来源。
//
// 和「模块」的区别（很多人会混）：
//   * 模块 = 往**页面**里注入 JS/CSS（见 bundle_manifest.dart）；
//     它改变的是"某个页面长什么样、能调什么"。
//   * 插件 = 给**宿主**增加一项能力，所有页面都能用；插件不注入任何代码。
//     它声明 capabilities，宿主按能力去问"谁能提供它"。
//
// 为什么多这一层：能力一旦写死在宿主里，就得随宿主一起发版；而插件是以包的
// 形式安装的（ZIP 导入），可以单独升级、停用、卸载。它同时是**多平台**的：
// manifest 里声明 platforms，宿主只在自己的平台上激活它，但不在这个平台上的
// 插件仍会出现在列表里（让用户知道"它在，只是跑不了"）。
//
// 落盘、扫描、启停、原子写入全部复用 BundleRepository，本文件只多算一件事：
// 「这个插件在当前设备上能不能用、是不是启用状态」。

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

// lib/data/services/plugin_service.dart
//
// 插件（plugin）服务：宿主能力的**可插拔**来源。
//
// 和「模块 / 扩展」的区别（很多人会混）：
//   * 扩展 / 模块 = 往**页面**里注入 JS/CSS（见 bundle_manifest.dart）；
//     它们改变的是"某个页面长什么样、能调什么"。
//   * 插件       = 给**宿主**增加一项能力，所有页面都能用；插件不注入任何代码。
//     它声明 capabilities（例如 wasm），宿主按能力去问"谁能提供它"。
//
// 为什么要多这一层：能力一旦写死在宿主里，就得随宿主一起发版；
// 而插件是以包的形式安装的（ZIP 导入 / 随包附带），可以单独升级、停用、卸载。
// 它同时是**多平台**的：manifest 里声明 platforms，宿主只在自己的平台上激活它，
// 但不在这个平台上的插件仍会出现在列表里（让用户知道"它在，只是跑不了"）。
//
// 这里的实现刻意薄：落盘、扫描、启停、原子写入全部复用 BundleRepository，
// 本文件只多做两件事 ——
//   1. 判断"这个插件在当前平台能不能用、是不是启用状态"；
//   2. 按能力读取插件里的资源（当前只有 wasm 模块）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../../core/globals.dart';
import '../models/bundle_manifest.dart';
import '../repositories/bundle_repository.dart';

/// 插件不可用（没装 / 停用 / 平台不支持 / 缺能力）。
class PluginUnavailableException implements Exception {
  const PluginUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一个「插件 + 它声明的 wasm 模块」的组合（列表页与桥接层都要用）
@immutable
class PluginWasmEntry {
  const PluginWasmEntry({required this.plugin, required this.module});

  final BundleManifest plugin;
  final PluginWasmModule module;

  String get name => module.name;
  String get description => module.description;
  List<String> get exports => module.exports;
}

class PluginService {
  PluginService._();

  static final PluginService instance = PluginService._();

  /// 随包附带的插件包（资源目录）。它只是一个**分发来源**：
  /// 装不装由用户决定，装完之后和从 ZIP 导入的插件没有任何区别。
  static const String bundledWasmAssetDir = 'assets/plugins/lemonlite-wasm';

  /// 随包附带的 WebAssembly 插件 id（与包内 manifest 的 id 一致）。
  /// 页面用它判断"要不要显示安装卡片"，不要在 UI 里硬编码字符串。
  static const String bundledWasmPluginId = 'lemonlite.wasm';

  /// 宿主认识的能力名。加新能力时在这里加常量 + 在桥接层接一个命名空间。
  static const String capabilityWasm = 'wasm';

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

  // ------------------------------------------------------------ 安装

  /// 安装随包附带的 WebAssembly 插件包。
  ///
  /// 走的是和用户导入 ZIP 完全相同的 `installArchive()`：同一套校验、
  /// 同一套原子写入，所以它不可能"因为是内置的就少做一步"。
  /// 返回 true 表示这次确实装了，false 表示已经装过（不覆盖用户的启停决定）。
  Future<bool> installBundledWasm() async {
    final BundleArchive archive = await _readBundledArchive(bundledWasmAssetDir);
    if (await isInstalled(archive.manifest.id)) return false;
    await _repo.installArchive(archive);
    return true;
  }

  /// 读随包附带的插件包（manifest + 它声明的 wasm 文件）。
  ///
  /// Flutter 的 asset 没有"列目录"能力，所以这里按 manifest 里声明的
  /// 文件清单逐个 load —— 也正因为这样，manifest 少写一个文件
  /// 会立刻在安装时报错，而不是等到调用时才失败。
  Future<BundleArchive> _readBundledArchive(String assetDir) async {
    final Uint8List manifestBytes = await _loadAssetBytes(
      '$assetDir/${BundleManifest.manifestFileName}',
      missing: '随包附带的插件包不存在（这个安装包可能少了 assets/plugins）',
    );
    final Object? decoded = jsonDecode(utf8.decode(manifestBytes, allowMalformed: true));
    if (decoded is! Map) {
      throw const PluginUnavailableException('插件 manifest 不是 JSON 对象');
    }
    final BundleManifest manifest = BundleManifest.parse(
      decoded.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      ),
    );
    if (manifest.type != BundleType.plugin) {
      throw const PluginUnavailableException('随包附带的包里写的不是插件类型');
    }

    final Map<String, Uint8List> files = <String, Uint8List>{
      BundleManifest.manifestFileName: manifestBytes,
    };
    for (final PluginWasmModule module in manifest.wasmModules) {
      files[module.file] = await _loadAssetBytes(
        '$assetDir/${module.file}',
        missing: '插件缺少资源：${module.file}',
      );
    }
    return BundleArchive(manifest: manifest, files: files);
  }

  /// 读 asset 字节；读不到时抛 [PluginUnavailableException]（带调用方给的说明）。
  Future<Uint8List> _loadAssetBytes(String path, {required String missing}) async {
    try {
      final ByteData data = await rootBundle.load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      throw PluginUnavailableException(missing);
    }
  }

  // ------------------------------------------------------------ wasm 能力

  /// 找到能提供 wasm 的插件（启用中 + 平台匹配 + 确实带模块）。
  Future<BundleManifest?> wasmProvider() async {
    for (final BundleManifest plugin in await active()) {
      if (plugin.hasCapability(capabilityWasm) && plugin.wasmModules.isNotEmpty) {
        return plugin;
      }
    }
    return null;
  }

  /// 全部可用 wasm 模块（带所属插件信息）
  Future<List<PluginWasmEntry>> wasmEntries() async {
    final List<PluginWasmEntry> entries = <PluginWasmEntry>[];
    for (final BundleManifest plugin in await active()) {
      if (!plugin.hasCapability(capabilityWasm)) continue;
      for (final PluginWasmModule module in plugin.wasmModules) {
        entries.add(PluginWasmEntry(plugin: plugin, module: module));
      }
    }
    return entries;
  }

  /// 读某个模块的字节。找不到时返回 null（调用方转成结构化错误）。
  Future<Uint8List?> wasmBytes(String name) async {
    for (final PluginWasmEntry entry in await wasmEntries()) {
      if (entry.module.name != name) continue;
      try {
        final Directory dir = await _repo.directoryOf(entry.plugin);
        final File file = File(p.join(dir.path, p.normalize(entry.module.file)));
        if (!file.existsSync()) return null;
        // 双重校验：路径必须还在插件目录里（manifest 里的 file 是包内相对路径，
        // 虽然导入时已经校验过，读的时候再确认一次不亏）。
        if (!p.isWithin(dir.path, file.path)) return null;
        return await file.readAsBytes();
      } catch (e) {
        lemonLog('Plugin', '读取 ${entry.plugin.id} 的 wasm 模块 ${name} 失败：$e');
        return null;
      }
    }
    return null;
  }

  /// `lemonlite.wasm.list()` 的返回体（与 0.1.4 及以前的字段保持兼容）。
  Future<Map<String, dynamic>> wasmListPayload() async {
    final List<PluginWasmEntry> entries = await wasmEntries();
    final List<Map<String, dynamic>> modules = <Map<String, dynamic>>[];
    for (final PluginWasmEntry entry in entries) {
      final Uint8List? bytes = await wasmBytes(entry.module.name);
      modules.add(<String, dynamic>{
        'name': entry.module.name,
        'description': entry.module.description,
        'bytes': bytes?.length ?? 0,
        'exports': entry.module.exports,
        'hasMemory': entry.module.hasMemory,
        // 新增：让小程序知道模块是哪个插件提供的（排障时非常有用）
        'plugin': entry.plugin.id,
        'pluginVersion': entry.plugin.version,
      });
    }
    return <String, dynamic>{
      'modules': modules,
      'count': modules.length,
      // WebAssembly 由 WebView 提供（Chromium 57+ 内置），宿主这边只负责供字节。
      // 没有模块时仍然是 true（能力本身存在），但 modules 为空，
      // 调用方据此给出"请先安装 WebAssembly 插件"的提示。
      'supported': true,
      'plugin': entries.isEmpty ? null : entries.first.plugin.id,
    };
  }

  /// `lemonlite.wasm.info(name)` / `wasm.bytes(name)` 的返回体。
  Future<Map<String, dynamic>> wasmReadPayload(String name) async {
    final List<PluginWasmEntry> entries = await wasmEntries();
    if (entries.isEmpty) {
      throw const PluginUnavailableException(
        '没有启用中的 WebAssembly 插件。请到「设置 → 插件」安装或启用它。',
      );
    }
    PluginWasmEntry? entry;
    for (final PluginWasmEntry candidate in entries) {
      if (candidate.module.name == name) entry = candidate;
    }
    if (entry == null) {
      final String available = entries.map((PluginWasmEntry e) => e.module.name).join(', ');
      throw PluginUnavailableException(
        '没有名为「$name」的 wasm 模块（可用：$available）',
      );
    }
    final Uint8List? bytes = await wasmBytes(name);
    if (bytes == null) {
      throw PluginUnavailableException('插件 ${entry.plugin.id} 的模块 $name 读取失败（文件可能被删了）');
    }
    return <String, dynamic>{
      'name': entry.module.name,
      'description': entry.module.description,
      'bytes': bytes.length,
      'base64': base64Encode(bytes),
      'exports': entry.module.exports,
      'hasMemory': entry.module.hasMemory,
      'plugin': entry.plugin.id,
      'pluginVersion': entry.plugin.version,
    };
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
        'wasmModules': plugin.wasmModules
            .map((PluginWasmModule m) => m.name)
            .toList(growable: false),
      });
    }
    final BundleManifest? provider = await wasmProvider();
    return <String, dynamic>{
      'platform': currentPlatformId,
      'count': items.length,
      'plugins': items,
      'wasm': <String, dynamic>{
        'available': provider != null,
        'plugin': provider?.id,
        'version': provider?.version,
      },
    };
  }
}

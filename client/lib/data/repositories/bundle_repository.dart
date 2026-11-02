// lib/data/repositories/bundle_repository.dart
//
// 模块 / 扩展包的落盘与读取。
//
// 目录布局（<应用私有目录> = path_provider 的 documents 目录）：
//   <docs>/lemonlite/extensions/<id>/lemonlite.json + inject.js + inject.css
//   <docs>/lemonlite/modules/<id>/...
//
// **为什么以「扫描目录」而不是「往 SharedPreferences 里存一份清单」作为真相来源**：
// 用户手动把包拷进目录、或用文件选择器导入后，如果不落盘成清单就同步不到；
// 反过来只信目录就不会出现「清单说有、文件没了」的幽灵条目。
// SharedPreferences 只存「哪些被停用了」这种轻量状态。
//
// 安全约束（解压外部文件必须做的事）：
//   1. 拒绝带 `..` 或绝对路径的条目 —— 否则一个精心构造的 zip 能写到目录外
//   2. 限制条目数与解压后总大小 —— 防 zip 炸弹把设备内存/磁盘打满
//   3. 落盘前用 manifest 里的 id / 引用的 js、css 文件做闭环校验，
//      不通过就整包丢弃，不留半截目录

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/globals.dart';
import '../models/bundle_manifest.dart';
import '../services/settings_service.dart';

/// 单个包出错时的统一异常（列表页把 message 直接显示出来）
class BundleException implements Exception {
  const BundleException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

/// 导入结果
class BundleImportResult {
  const BundleImportResult({required this.manifest, required this.replaced});

  final BundleManifest manifest;

  /// 是否覆盖了同 id 的旧包
  final bool replaced;
}

/// 一个包在内存里的完整内容（注入时用）
class BundlePayload {
  const BundlePayload({
    required this.manifest,
    required this.css,
    required this.js,
    this.runAtOverride,
    this.injectionKey,
  });

  final BundleManifest manifest;

  /// 所有 css 文件拼起来的文本（按 content_scripts 规则中的顺序）
  final String css;

  /// 所有 js 文件拼起来的文本
  final String js;

  /// 一个包里可以定义多条不同注入时机的规则；旧包沿用 manifest.runAt。
  final BundleRunAt? runAtOverride;

  /// 同一扩展多条规则可能同时命中；样式节点必须分开，否则后一个会覆盖前一个。
  final String? injectionKey;
  BundleRunAt get runAt => runAtOverride ?? manifest.runAt;

  /// 调试用短名
  String get label => '${manifest.type.label}·${manifest.name}';
}

class BundleRepository {
  BundleRepository._();

  static final BundleRepository instance = BundleRepository._();

  /// 解压安全上限
  static const int _maxEntries = 200;
  static const int _maxTotalBytes = 8 * 1024 * 1024;
  static const int _maxSingleFileBytes = 2 * 1024 * 1024;

  static const String _kDisabledKey = 'bundles.disabled_ids';

  // ------------------------------------------------------------ 目录

  Future<Directory> _root() async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory root = Directory(p.join(docs.path, 'lemonlite'));
    if (!root.existsSync()) root.createSync(recursive: true);
    return root;
  }

  /// 某一类包的根目录
  Future<Directory> _typeDir(BundleType type) async =>
      Directory(p.join((await _root()).path, type.directoryName));

  /// 某个包自己的目录
  Future<Directory> _bundleDir(BundleManifest manifest) async =>
      Directory(p.join((await _typeDir(manifest.type)).path, manifest.id));

  /// 某个包落盘后的目录（插件读自己的 wasm 文件要用）。
  /// 只读路径，不创建 —— 调用方自己判断是否存在。
  Future<Directory> directoryOf(BundleManifest manifest) => _bundleDir(manifest);

  /// 导入前预扫描：只读文件头里的 manifest，用于让用户「加入前先看一眼是什么」
  static Future<BundleManifest?> peekManifest(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      final BundleArchive raw = parseArchive(bytes, fileName);
      return raw.manifest;
    } catch (_) {
      // peek 只用于预览，解析失败交给真正的导入去报错
      return null;
    }
  }

  // ------------------------------------------------------------ 扫描

  /// 列出某类已落盘的包。目录里放什么就认什么，不做额外缓存。
  Future<List<BundleManifest>> scan(BundleType type) async {
    final Directory dir = await _typeDir(type);
    if (!dir.existsSync()) return <BundleManifest>[];

    final List<BundleManifest> result = <BundleManifest>[];
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! Directory) continue;
      try {
        final BundleManifest? manifest = _readManifestDir(
          Directory(entity.path),
        );
        if (manifest != null) result.add(manifest);
      } catch (e) {
        // 单个坏目录不能影响其它包：记一条日志跳过，列表页仍能看到其它包
        lemonLog('BundleRepo', '跳过损坏的包目录 ${entity.path}：$e');
      }
    }
    result.sort(
      (BundleManifest a, BundleManifest b) => a.name.compareTo(b.name),
    );
    return result;
  }

  /// 直接从目录读 manifest（安装后自检也复用它）
  BundleManifest? _readManifestDir(Directory dir) {
    final File manifestFile = File(
      p.join(dir.path, BundleManifest.manifestFileName),
    );
    if (!manifestFile.existsSync()) return null;
    final Object? decoded = jsonDecode(
      manifestFile.readAsStringSync(encoding: utf8),
    );
    if (decoded is! Map) {
      throw const BundleManifestException('root', 'manifest 不是 JSON 对象');
    }
    final BundleManifest manifest = BundleManifest.parse(
      decoded.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      ),
    );
    // 目录名与 id 不一致说明是手工拷进来的，改名以 id 为准
    if (p.basename(dir.path) != manifest.id) {
      lemonLog(
        'BundleRepo',
        '包目录名 ${p.basename(dir.path)} 与 id ${manifest.id} 不一致，按 id 归一',
      );
    }
    return manifest;
  }

  // ------------------------------------------------------------ 导入

  /// 从用户选中的文件导入（zip 包，或单个 manifest json）
  Future<BundleImportResult> importBundle(
    Uint8List bytes,
    String fileName,
  ) async {
    return installArchive(parseArchive(bytes, fileName));
  }

  /// 把已经解好的包落盘。
  ///
  /// 单独拆出来是为了让「不经用户选文件」的安装路径（内置插件包、
  /// 将来的在线安装）复用同一套校验与原子写入 —— 两条路走两份代码
  /// 迟早会有一边忘了校验。
  Future<BundleImportResult> installArchive(BundleArchive raw) async {
    final BundleManifest manifest = raw.manifest;

    // manifest 引用的脚本必须真实存在，否则装完是哑的。
    // 直接查解出来的文件表，不拼路径；每条规则也要独立闭环校验。
    final Iterable<String> references = <String>[
      ...manifest.jsFiles,
      ...manifest.cssFiles,
      // 插件声明的 wasm 模块同样必须真的在包里：装完才发现读不到
      // 等于装了一个"声明有 wasm 能力但其实是空的"插件。
      for (final PluginWasmModule module in manifest.wasmModules) module.file,
      for (final BundleContentScript rule
          in manifest.effectiveContentScripts) ...<String>[
        ...rule.jsFiles,
        ...rule.cssFiles,
      ],
    ];
    for (final String rel in references) {
      final String portable = rel.replaceAll('\\', '/');
      if (portable.isEmpty ||
          p.isAbsolute(portable) ||
          portable.split('/').contains('..')) {
        throw BundleException('包「${manifest.name}」引用了非法资源路径', detail: rel);
      }
      if (!raw.files.containsKey(p.normalize(portable))) {
        throw BundleException('包「${manifest.name}」引用的文件不存在', detail: rel);
      }
    }

    final Directory target = await _bundleDir(manifest);
    final bool replaced = target.existsSync();
    if (replaced) target.deleteSync(recursive: true);

    // 先写进临时目录再改名：中途失败不会留下半个包
    final Directory staging = Directory('${target.path}.tmp');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    try {
      for (final MapEntry<String, Uint8List> entry in raw.files.entries) {
        final File out = File(p.join(staging.path, p.normalize(entry.key)));
        out.parent.createSync(recursive: true);
        out.writeAsBytesSync(entry.value);
      }
      staging.renameSync(target.path);
    } catch (e) {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      throw BundleException('写入失败', detail: '$e');
    }

    lemonLog(
      'BundleRepo',
      '已导入 ${manifest.type.label} ${manifest.name} v${manifest.version}',
    );
    return BundleImportResult(manifest: manifest, replaced: replaced);
  }

  /// 删除某个包（连目录一起删）
  Future<void> remove(BundleManifest manifest) async {
    final Directory dir = await _bundleDir(manifest);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    // 从停用名单里摘掉，避免同名新包装回来时莫名其妙是停用的
    final Set<String> disabled = await disabledIds();
    if (disabled.remove(manifest.id)) await _saveDisabled(disabled);
  }

  // ------------------------------------------------------------ 启停

  Future<Set<String>> disabledIds() async {
    final String? raw = SettingsService.instance.readRaw(_kDisabledKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded
          .map((Object? e) => e.toString().trim())
          .where((String e) => e.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  bool isDisabled(String id, Set<String> disabled) => disabled.contains(id);

  Future<void> setDisabled(String id, bool disabled) async {
    final Set<String> set = await disabledIds();
    if (disabled) {
      set.add(id);
    } else {
      set.remove(id);
    }
    await _saveDisabled(set);
  }

  Future<void> _saveDisabled(Set<String> ids) async {
    final List<String> sorted = ids.toList()..sort();
    await SettingsService.instance.writeRaw(_kDisabledKey, jsonEncode(sorted));
  }

  // ------------------------------------------------------------ 读取内容

  /// 读取一批包的实际内容（注入前调用）。读不到的脚本记日志后跳过，不影响其它包。
  /// 按 URL 逐条筛注入规则，不能把不同站点的规则拍平。
  Future<List<BundlePayload>> readPayloads(
    List<BundleManifest> manifests, {
    String? url,
  }) async {
    final List<BundlePayload> result = <BundlePayload>[];
    for (final BundleManifest manifest in manifests) {
      try {
        final Directory dir = await _bundleDir(manifest);
        if (!dir.existsSync()) continue;
        final List<BundleContentScript> rules =
            manifest.effectiveContentScripts;
        for (int index = 0; index < rules.length; index++) {
          final BundleContentScript rule = rules[index];
          if (!contentScriptMatchesUrl(rule, url)) continue;
          result.add(
            BundlePayload(
              manifest: manifest,
              css: _joinFiles(dir, rule.cssFiles),
              js: _joinFiles(dir, rule.jsFiles),
              runAtOverride: rule.runAt,
              injectionKey: '${manifest.id}-$index',
            ),
          );
        }
      } catch (e) {
        lemonLog('BundleRepo', '读取 ${manifest.id} 的脚本失败：$e');
      }
    }
    return result;
  }

  String _joinFiles(Directory dir, List<String> relativePaths) {
    final List<String> chunks = <String>[];
    for (final String rel in relativePaths) {
      final File file = File(p.join(dir.path, p.normalize(rel)));
      if (!file.existsSync()) continue;
      final String text = file.readAsStringSync(encoding: utf8);
      chunks.add('/* --- $rel --- */\n$text');
    }
    return chunks.join('\n');
  }

  /// 模块声明的桥接方法 → 方法名映射，供 BridgeApi 分发
  Future<Map<String, BundleBridgeMethod>> activeModuleMethods() async {
    final Set<String> disabled = await disabledIds();
    final List<BundleManifest> modules = await scan(BundleType.module);
    final Map<String, BundleBridgeMethod> result =
        <String, BundleBridgeMethod>{};
    for (final BundleManifest manifest in modules) {
      if (disabled.contains(manifest.id)) continue;
      for (final BundleBridgeMethod method in manifest.bridgeMethods) {
        // 同名后加载的覆盖先加载的：列表按名称排序，结果稳定可预期
        result[method.name] = method;
      }
    }
    return result;
  }

  // ------------------------------------------------------------ 解包

  /// zip 或单个 manifest.json 的统一读取。**纯函数，不碰文件系统**，
  /// 所以能在单元测试里直接喂构造出来的 zip 字节。
  static BundleArchive parseArchive(Uint8List bytes, String fileName) {
    if (bytes.isEmpty) {
      throw const BundleException('文件是空的');
    }

    final String lower = fileName.toLowerCase();
    if (lower.endsWith('.json')) {
      return _readBareManifest(bytes);
    }
    if (lower.endsWith('.zip')) {
      return _readZip(bytes);
    }
    throw BundleException(
      '不认识的文件类型',
      detail: '$fileName（支持 .zip 包，或单个 lemonlite.json）',
    );
  }

  /// 单个 manifest.json：没有脚本文件，只能声明桥接方法
  static BundleArchive _readBareManifest(Uint8List bytes) {
    if (bytes.lengthInBytes > _maxSingleFileBytes) {
      throw const BundleException('manifest 太大了');
    }
    final BundleManifest manifest = _parseManifestText(
      utf8.decode(bytes, allowMalformed: false),
    );
    // 用一个不会存在的目录做存在性检查：裸 manifest 就不该声明 js/css
    for (final String rel in <String>[
      ...manifest.jsFiles,
      ...manifest.cssFiles,
    ]) {
      throw BundleException('单个 json 里不能引用脚本文件 $rel', detail: '要带脚本请打成 zip 包');
    }
    return BundleArchive(
      manifest: manifest,
      files: <String, Uint8List>{BundleManifest.manifestFileName: bytes},
    );
  }

  static BundleManifest _parseManifestText(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      throw BundleException('manifest 不是合法 JSON', detail: '$e');
    }
    if (decoded is! Map) {
      throw const BundleException('manifest 不是 JSON 对象');
    }
    try {
      return BundleManifest.parse(
        decoded.map<String, dynamic>(
          (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
        ),
      );
    } on BundleManifestException catch (e) {
      throw BundleException(
        'manifest 字段有误：${e.message}',
        detail: '字段 ${e.field}',
      );
    }
  }

  static BundleArchive _readZip(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw BundleException('zip 包解析失败', detail: '$e');
    }

    if (archive.files.length > _maxEntries) {
      throw BundleException(
        '包内文件过多（${archive.files.length} 个）',
        detail: '上限 $_maxEntries 个',
      );
    }

    // 有些打包工具会在最外层套一层目录，先把 manifest 找出来再决定根在哪
    final Map<String, Uint8List> all = <String, Uint8List>{};
    int total = 0;
    for (final ArchiveFile entry in archive.files) {
      if (!entry.isFile) continue;
      final String name = _safeEntryName(entry.name);
      final Uint8List? content = entry.readBytes();
      if (content == null) continue;
      if (content.lengthInBytes > _maxSingleFileBytes) {
        throw BundleException('包内单文件超过 2MB', detail: name);
      }
      total += content.lengthInBytes;
      if (total > _maxTotalBytes) {
        throw BundleException('解压后超过 8MB，疑似异常包');
      }
      all[name] = content;
    }

    if (all.isEmpty) throw const BundleException('zip 包是空的');

    final String prefix = _findManifestPrefix(all);

    // 剥掉最外层目录，并统一规范化（去掉 ./ 之类），这样才能与 manifest 里的相对路径对上。
    final Map<String, Uint8List> files = <String, Uint8List>{};
    for (final MapEntry<String, Uint8List> e in all.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final String rel = p.normalize(e.key.substring(prefix.length));
      if (rel.isEmpty || rel == '.') continue;
      files[rel] = e.value;
    }

    final Uint8List? lemonManifest = files[BundleManifest.manifestFileName];
    if (lemonManifest != null) {
      return BundleArchive(
        manifest: _parseManifestText(utf8.decode(lemonManifest)),
        files: files,
      );
    }

    throw const BundleException(
      '包里找不到扩展清单',
      detail: '需要 lemonlite.json（LemonLite 扩展格式）',
    );
  }

  /// 防路径穿越：拒绝绝对路径、盘符、`..` 段
  static String _safeEntryName(String raw) {
    final String name = raw.replaceAll('\\', '/');
    if (name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      throw BundleException('包内有非法路径', detail: raw);
    }
    for (final String seg in name.split('/')) {
      if (seg == '..') {
        throw BundleException('包内有非法路径（..）', detail: raw);
      }
    }
    return name;
  }

  /// 找出 manifest 所在的「根前缀」：根目录直接放，或最外层只有一个文件夹时用它的名字。
  static String _findManifestPrefix(Map<String, Uint8List> all) {
    if (all.containsKey(BundleManifest.manifestFileName)) {
      return '';
    }
    final Set<String> roots = <String>{};
    for (final String name in all.keys) {
      final int slash = name.indexOf('/');
      if (slash > 0) roots.add(name.substring(0, slash + 1));
    }
    if (roots.length == 1 &&
        all.containsKey(
          '${roots.first}${BundleManifest.manifestFileName}',
        )) {
      return roots.first;
    }
    throw BundleException(
      '包里找不到扩展清单',
      detail: roots.isEmpty
          ? '需要 lemonlite.json'
          : '最外层有多个目录：${roots.join(" / ")}',
    );
  }
}

/// 解包后的中间形态：manifest + 相对路径 → 内容。
/// 放在顶层是因为 Dart 不允许把类声明在类里面。
class BundleArchive {
  BundleArchive({required this.manifest, required this.files});

  final BundleManifest manifest;

  /// 相对包根的路径 → 内容（键已用 path 规范化过，可直接与 manifest 里的相对路径比对）
  final Map<String, Uint8List> files;
}

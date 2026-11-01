// lib/data/services/miniapp_storage_service.dart
//
// 小程序的「数据面」：进程内 storage（SharedPreferences 键值）+ 磁盘文件沙箱。
//
// 每个小程序有**两个**文件根目录，小程序自己选调用哪个（FileScope）：
//
//   files（共享目录，默认）
//     <getExternalStorageDirectory()>/appfiles/<appId>/
//     Android 上 getExternalStorageDirectory() = /storage/emulated/0/Android/data/<包名>/files
//     → /storage/emulated/0/Android/data/xyz.star201.lemonlite/files/appfiles/<小程序 id>
//     用户在系统文件管理器里能直接看到、能拷出来，适合放用户要拿走的文件。
//
//   private（私有目录）
//     <getApplicationSupportDirectory()>/appfiles/<appId>/
//     Android 上 getApplicationSupportDirectory() = /data/user/0/<包名>/files
//     → data/data/xyz.star201.lemonlite/files/appfiles/<小程序 id>
//     只有本应用（同一个 uid）读得到，卸载即消失，适合放缓存与内部状态。
//
// storage : SharedPreferences，key = `miniapp.storage.<appId>.<用户的 key>`
//           （键值存储不分作用域：它本来就在应用私有目录里）
//
// 为什么给每个小程序单独一个文件夹：
//   1. 卸载式清理只要删一个目录（clearFiles），不用遍历判断归属；
//   2. 路径穿越防护只需要在「小程序根」上做一次，子路径怎么折腾都出不去；
//   3. 用户能在系统文件管理器里按 id 找到对应数据。
//
// 两个根目录共用同一套路径校验（normalizeRelativePath + isWithin 复核），
// 所以「换个 scope」不会削弱任何一条安全约束 —— 逃逸出哪一个都不行。
//
// 这里同时也是「设置 → 存储」的数据层：占用统计、单 App 清理、键级清理都在这里，
// 页面只负责渲染。

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/globals.dart';
import '../models/json_utils.dart';
import 'permission_service.dart';
import 'settings_service.dart';

/// 小程序文件操作的作用域 —— 也就是「读写的到底是哪一个根目录」。
///
/// 之所以要做成小程序可选的：这两个目录的可见性完全不同。
/// 共享目录在 Android/data 下，用户连电脑就能拿走；私有目录在 data/data 下，
/// 只有宿主自己读得到。小程序该用哪个由它自己的数据语义决定，
/// 框架不替它猜 —— 但两条路径的越界校验是同一套，谁都不许爬出自己那棵树。
enum FileScope {
  files(
    id: 'files',
    label: '共享目录',
    description: '位于 Android/data/<包名>/files/appfiles/<小程序 id>，'
        '用户能在文件管理器里看到并拷走。',
  ),
  private(
    id: 'private',
    label: '私有目录',
    description: '位于 data/data/<包名>/files/appfiles/<小程序 id>，'
        '只有宿主读得到，卸载后随应用一起消失。',
  );

  const FileScope({
    required this.id,
    required this.label,
    required this.description,
  });

  /// 持久化 / 桥接参数用的稳定标识
  final String id;

  final String label;
  final String description;

  /// 默认作用域。保持成共享目录，是为了让既有小程序的行为完全不变。
  static const FileScope defaultScope = FileScope.files;

  /// 宽松解析：认不出来就回落到默认值（旧小程序不传 scope 也照常工作）
  static FileScope parse(Object? raw) {
    if (raw == null) return defaultScope;
    final String value = raw.toString().trim().toLowerCase();
    for (final FileScope scope in values) {
      if (scope.id == value) return scope;
    }
    return defaultScope;
  }
}

/// 文件类 API 的可预期失败。桥接层会把它转成结构化错误码回给 JS。
class AppFileException implements Exception {
  const AppFileException(this.message);

  final String message;

  @override
  String toString() => 'AppFileException: $message';
}

/// 单个 storage 键的占用
class MiniappStorageEntry {
  const MiniappStorageEntry({required this.key, required this.rawKey, required this.bytes});

  /// 小程序视角的 key（已剥掉框架前缀）
  final String key;

  /// SharedPreferences 里的完整 key（删除时用这个）
  final String rawKey;

  /// 值的 UTF-8 字节数
  final int bytes;
}

/// 一个 App 的完整数据占用（两个文件目录分别统计）
class MiniappStorageUsage {
  const MiniappStorageUsage({
    required this.appId,
    required this.name,
    required this.storageKeys,
    required this.storageBytes,
    required this.fileCount,
    required this.fileBytes,
    this.privateCount = 0,
    this.privateBytes = 0,
    this.lastOpenedAt,
    this.filesPath = '',
    this.privatePath = '',
  });

  final String appId;
  final String name;

  final int storageKeys;
  final int storageBytes;

  /// 共享目录（files）
  final int fileCount;
  final int fileBytes;

  /// 私有目录（private）
  final int privateCount;
  final int privateBytes;

  final DateTime? lastOpenedAt;

  /// 共享目录绝对路径（拿不到时为空串）
  final String filesPath;

  /// 私有目录绝对路径（拿不到时为空串）
  final String privatePath;

  int get totalBytes => storageBytes + fileBytes + privateBytes;

  int get totalFileCount => fileCount + privateCount;

  bool get isEmpty =>
      totalBytes == 0 && storageKeys == 0 && totalFileCount == 0;

  String get totalLabel => formatBytes(totalBytes);
  String get storageLabel => formatBytes(storageBytes);
  String get filesLabel => formatBytes(fileBytes);
  String get privateLabel => formatBytes(privateBytes);

  /// 某个作用域的占用（页面里按 scope 取用）
  int bytesOf(FileScope scope) =>
      scope == FileScope.files ? fileBytes : privateBytes;

  int countOf(FileScope scope) =>
      scope == FileScope.files ? fileCount : privateCount;

  String pathOf(FileScope scope) =>
      scope == FileScope.files ? filesPath : privatePath;

  /// 一句话摘要，列表里当 subtitle 用
  String get summaryLabel {
    if (isEmpty) return '没有占用';
    final List<String> parts = <String>[];
    if (storageBytes > 0 || storageKeys > 0) {
      parts.add('键值 ${formatBytes(storageBytes)}（$storageKeys 项）');
    }
    if (fileBytes > 0 || fileCount > 0) {
      parts.add('共享 ${formatBytes(fileBytes)}（$fileCount 个）');
    }
    if (privateBytes > 0 || privateCount > 0) {
      parts.add('私有 ${formatBytes(privateBytes)}（$privateCount 个）');
    }
    return parts.isEmpty ? '没有占用' : parts.join(' · ');
  }
}

/// 目录列举里的一项
class MiniappFileEntry {
  const MiniappFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.bytes,
    this.modifiedAt,
  });

  /// 文件/目录名
  final String name;

  /// 相对小程序根目录的路径（正斜杠，空串代表根）
  final String path;

  final bool isDirectory;
  final int bytes;
  final DateTime? modifiedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'path': path,
    'isDirectory': isDirectory,
    'bytes': bytes,
    'modifiedAt': modifiedAt?.millisecondsSinceEpoch ?? 0,
    'modifiedAtLabel': modifiedAt == null ? '' : formatDateTimeLabel(modifiedAt),
  };
}

/// exists / fileInfo 的返回
class MiniappFileInfo {
  const MiniappFileInfo({
    required this.path,
    required this.exists,
    required this.isDirectory,
    required this.bytes,
    this.modifiedAt,
  });

  final String path;
  final bool exists;
  final bool isDirectory;
  final int bytes;
  final DateTime? modifiedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'exists': exists,
    'isDirectory': isDirectory,
    'bytes': bytes,
    'modifiedAt': modifiedAt?.millisecondsSinceEpoch ?? 0,
  };
}

class MiniappStorageService {
  MiniappStorageService._();

  static final MiniappStorageService instance = MiniappStorageService._();

  /// 两个根目录的缓存（第一次访问时解析）
  static final Map<FileScope, Directory> _rootCache = <FileScope, Directory>{};

  /// 单次写入上限：超过就拒绝，避免小程序把 SharedPreferences / 磁盘写爆
  static const int maxFileBytes = 8 * 1024 * 1024;

  /// 递归统计的条目上限，防止异常深目录把 UI 卡死
  static const int maxScanEntries = 20000;

  // ------------------------------------------------------------ 目录解析

  /// 某个作用域的根目录：`<base>/appfiles`
  ///
  /// files   → 外部私有目录（Android/data/<包名>/files）
  /// private → 应用支持目录（data/data/<包名>/files）
  Future<Directory> rootFor(FileScope scope) async {
    final Directory? cached = _rootCache[scope];
    if (cached != null) return cached;

    Directory? base;
    try {
      base = scope == FileScope.files
          // Android 上 = /storage/emulated/0/Android/data/<包名>/files
          ? await getExternalStorageDirectory()
          // Android 上 = /data/user/0/<包名>/files（即 data/data/<包名>/files）
          : await getApplicationSupportDirectory();
    } catch (e) {
      lemonLog('Storage', '${scope.label}不可用，回落到应用文档目录：$e');
    }
    // 兜底：两个都拿不到时退回文档目录，至少不要让调用直接抛异常
    base ??= await getApplicationDocumentsDirectory();

    final Directory root = Directory(p.join(base.path, 'appfiles'));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _rootCache[scope] = root;
    return root;
  }

  /// 共享目录根（`.../files/appfiles`）。保留这个名字，既有调用点不用改。
  Future<Directory> appFilesRoot() => rootFor(FileScope.files);

  /// 私有目录根（`data/data/<包名>/files/appfiles`）
  Future<Directory> appPrivateRoot() => rootFor(FileScope.private);

  /// 某个小程序在某个作用域下的沙箱目录（会创建）
  Future<Directory> appFilesDir(
    String appId, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    final Directory root = await rootFor(scope);
    final Directory dir = Directory(p.join(root.path, _sanitizeAppId(appId)));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 某个小程序在某个作用域下的沙箱目录绝对路径（不创建，展示用）
  Future<String> appFilesPath(
    String appId, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    final Directory root = await rootFor(scope);
    return p.join(root.path, _sanitizeAppId(appId));
  }

  /// 展示给用户/小程序看的可读路径（不带 /storage/emulated/0 这类前缀）
  String displayPath(String appId, FileScope scope) {
    final String safe = _sanitizeAppId(appId);
    return scope == FileScope.files
        ? 'Android/data/${AppInfo.packageName}/files/appfiles/$safe'
        : 'data/data/${AppInfo.packageName}/files/appfiles/$safe';
  }

  /// appId 直接进路径，必须挡住 `/` 与 `..`，否则一个小程序能写到别人的目录
  String _sanitizeAppId(String appId) {
    final String value = appId.trim();
    if (value.isEmpty) throw const AppFileException('appId 不能为空');
    final String safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe == '.' || safe == '..') {
      throw const AppFileException('appId 不合法');
    }
    return safe;
  }

  /// 把小程序传来的相对路径规范成「一定还在本小程序目录内」的相对路径。
  ///
  /// 这一步是安全边界：拒绝绝对路径、拒绝 `..` 逃逸、限制长度。
  /// 空串 / `.` 表示小程序根目录自身。
  String normalizeRelativePath(String raw) {
    String value = raw.trim().replaceAll('\\', '/');
    if (value.isEmpty) return '.';
    if (value.length > 512) {
      throw const AppFileException('路径过长（上限 512 字符）');
    }
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw const AppFileException('只允许相对路径，不能以 / 开头');
    }
    final String normalized = p.posix.normalize(value);
    if (normalized == '..' || normalized.startsWith('../')) {
      throw const AppFileException('路径不能越过小程序目录（不允许 ..）');
    }
    return normalized;
  }

  /// 解析成绝对 File，并再校验一次是否真的落在该作用域的小程序目录内。
  Future<File> resolveFile(
    String appId,
    String rawPath, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    final Directory dir = await appFilesDir(appId, scope: scope);
    final String relative = normalizeRelativePath(rawPath);
    final String full = p.normalize(p.join(dir.path, relative));
    if (!p.isWithin(dir.path, full) && p.normalize(dir.path) != full) {
      throw const AppFileException('路径越界');
    }
    return File(full);
  }

  Future<Directory> _resolveDir(
    String appId,
    String rawPath, {
    FileScope scope = FileScope.defaultScope,
    bool create = true,
  }) async {
    final Directory dir = await appFilesDir(appId, scope: scope);
    final String relative = normalizeRelativePath(rawPath);
    final String full = p.normalize(p.join(dir.path, relative));
    if (!p.isWithin(dir.path, full) && p.normalize(dir.path) != full) {
      throw const AppFileException('路径越界');
    }
    final Directory target = Directory(full);
    if (create && !await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  // -------------------------------------------------------------- 文件 API

  /// 读文本 / base64。文件不存在时 found=false（不是异常 —— 小程序首次读很常见）。
  Future<Map<String, dynamic>> readFile(
    String appId,
    String path, {
    bool asBase64 = false,
    FileScope scope = FileScope.defaultScope,
  }) async {
    final File file = await resolveFile(appId, path, scope: scope);
    if (!await file.exists()) {
      return <String, dynamic>{
        'path': normalizeRelativePath(path),
        'scope': scope.id,
        'found': false,
        'data': '',
        'bytes': 0,
      };
    }
    final List<int> bytes = await file.readAsBytes();
    if (bytes.length > maxFileBytes) {
      throw AppFileException('文件过大（${formatBytes(bytes.length)}），上限 ${formatBytes(maxFileBytes)}');
    }
    return <String, dynamic>{
      'path': normalizeRelativePath(path),
      'scope': scope.id,
      'found': true,
      'data': asBase64 ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true),
      'bytes': bytes.length,
    };
  }

  /// 写文本 / base64。[append] 为 true 时追加。
  Future<Map<String, dynamic>> writeFile(
    String appId,
    String path,
    String data, {
    bool asBase64 = false,
    bool append = false,
    FileScope scope = FileScope.defaultScope,
  }) async {
    final List<int> bytes = asBase64
        ? _decodeBase64(data)
        : utf8.encode(data);
    if (bytes.length > maxFileBytes) {
      throw AppFileException('写入内容过大（${formatBytes(bytes.length)}），上限 ${formatBytes(maxFileBytes)}');
    }
    if (normalizeRelativePath(path) == '.') {
      throw const AppFileException('path 不能是空目录');
    }
    final File file = await resolveFile(appId, path, scope: scope);
    await file.parent.create(recursive: true);
    if (append) {
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    } else {
      await file.writeAsBytes(bytes, mode: FileMode.write, flush: true);
    }
    final int length = await file.length();
    return <String, dynamic>{
      'path': normalizeRelativePath(path),
      'scope': scope.id,
      'bytes': length,
      'written': bytes.length,
      'appended': append,
    };
  }

  Future<List<MiniappFileEntry>> listFiles(
    String appId,
    String path, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    final Directory dir = await _resolveDir(appId, path, scope: scope, create: false);
    if (!await dir.exists()) {
      throw AppFileException('目录不存在：${normalizeRelativePath(path)}');
    }
    final String rootPath = (await appFilesDir(appId, scope: scope)).path;
    final List<MiniappFileEntry> entries = <MiniappFileEntry>[];
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      final String relative = p.relative(entity.path, from: rootPath).replaceAll('\\', '/');
      final String name = p.basename(entity.path);
      if (entity is Directory) {
        entries.add(
          MiniappFileEntry(
            name: name,
            path: relative,
            isDirectory: true,
            bytes: await _directoryBytes(entity),
          ),
        );
      } else if (entity is File) {
        FileStat stat;
        try {
          stat = await entity.stat();
        } catch (_) {
          continue; // 列举过程中被删掉的条目直接跳过
        }
        entries.add(
          MiniappFileEntry(
            name: name,
            path: relative,
            isDirectory: false,
            bytes: stat.size,
            modifiedAt: stat.modified,
          ),
        );
      }
    }
    // 目录在前，然后按名字排 —— 稳定的顺序比「文件系统返回顺序」好预测
    entries.sort((MiniappFileEntry a, MiniappFileEntry b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// 删除文件或目录（递归）。返回是否真的删掉了东西。
  Future<bool> deleteFile(
    String appId,
    String path, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    final String relative = normalizeRelativePath(path);
    if (relative == '.') {
      throw const AppFileException('不允许删除小程序根目录，请用「清除数据」');
    }
    final Directory dir = await appFilesDir(appId, scope: scope);
    final String full = p.normalize(p.join(dir.path, relative));
    if (!p.isWithin(dir.path, full)) throw const AppFileException('路径越界');

    final FileSystemEntityType type = await FileSystemEntity.type(full);
    if (type == FileSystemEntityType.notFound) return false;
    if (type == FileSystemEntityType.directory) {
      await Directory(full).delete(recursive: true);
    } else {
      await File(full).delete();
    }
    return true;
  }

  Future<String> mkdir(
    String appId,
    String path, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    final Directory dir = await _resolveDir(appId, path, scope: scope);
    final String rootPath = (await appFilesDir(appId, scope: scope)).path;
    return p.relative(dir.path, from: rootPath).replaceAll('\\', '/');
  }

  Future<MiniappFileInfo> fileInfo(
    String appId,
    String path, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    final String relative = normalizeRelativePath(path);
    final Directory dir = await appFilesDir(appId, scope: scope);
    final String full = p.normalize(p.join(dir.path, relative));
    if (!p.isWithin(dir.path, full)) throw const AppFileException('路径越界');

    final FileSystemEntityType type = await FileSystemEntity.type(full);
    if (type == FileSystemEntityType.notFound) {
      return MiniappFileInfo(path: relative, exists: false, isDirectory: false, bytes: 0);
    }
    if (type == FileSystemEntityType.directory) {
      final Directory target = Directory(full);
      return MiniappFileInfo(
        path: relative,
        exists: true,
        isDirectory: true,
        bytes: await _directoryBytes(target),
      );
    }
    final File target = File(full);
    final FileStat stat = await target.stat();
    return MiniappFileInfo(
      path: relative,
      exists: true,
      isDirectory: false,
      bytes: stat.size,
      modifiedAt: stat.modified,
    );
  }

  static List<int> _decodeBase64(String data) {
    try {
      return base64Decode(data.trim());
    } catch (_) {
      throw const AppFileException('base64 内容不合法');
    }
  }

  // ---------------------------------------------------------------- 占用

  /// 某个小程序的 storage 键清单（含每个键的字节数），按体积倒序
  List<MiniappStorageEntry> storageEntries(String appId) {
    final Map<String, String> raw =
        SettingsService.instance.miniappStorageEntries(appId);
    final String prefix = '${SettingsService.miniappStoragePrefix}$appId.';
    final List<MiniappStorageEntry> entries = raw.entries
        .map(
          (MapEntry<String, String> e) => MiniappStorageEntry(
            key: e.key.startsWith(prefix) ? e.key.substring(prefix.length) : e.key,
            rawKey: e.key,
            bytes: utf8.encode(e.value).length,
          ),
        )
        .toList();
    entries.sort((MiniappStorageEntry a, MiniappStorageEntry b) => b.bytes.compareTo(a.bytes));
    return entries;
  }

  int storageBytes(String appId) => storageEntries(appId)
      .fold<int>(0, (int sum, MiniappStorageEntry e) => sum + e.bytes);

  Future<int> _directoryBytes(Directory dir) async {
    int total = 0;
    int visited = 0;
    try {
      await for (final FileSystemEntity entity
          in dir.list(recursive: true, followLinks: false)) {
        if (++visited > maxScanEntries) break;
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // 统计期间文件被删 / 没权限：跳过，不影响整体
        }
      }
    } catch (e) {
      lemonLog('Storage', '统计目录失败 ${dir.path}：$e');
    }
    return total;
  }

  Future<({int bytes, int count})> _directoryStats(Directory dir) async {
    int bytes = 0;
    int count = 0;
    int visited = 0;
    try {
      await for (final FileSystemEntity entity
          in dir.list(recursive: true, followLinks: false)) {
        if (++visited > maxScanEntries) break;
        if (entity is! File) continue;
        count++;
        try {
          bytes += await entity.length();
        } catch (_) {
          // 同上
        }
      }
    } catch (e) {
      lemonLog('Storage', '统计目录失败 ${dir.path}：$e');
    }
    return (bytes: bytes, count: count);
  }

  /// 统计某个作用域的占用；拿不到时返回全 0 与空路径，绝不抛。
  Future<({int bytes, int count, String path})> _scopeStats(
    String appId,
    FileScope scope,
  ) async {
    try {
      final Directory root = await rootFor(scope);
      final Directory dir = Directory(p.join(root.path, _sanitizeAppId(appId)));
      if (!await dir.exists()) {
        return (bytes: 0, count: 0, path: dir.path);
      }
      final ({int bytes, int count}) stats = await _directoryStats(dir);
      return (bytes: stats.bytes, count: stats.count, path: dir.path);
    } catch (e) {
      lemonLog('Storage', '读取 $appId ${scope.label}占用失败：$e');
      return (bytes: 0, count: 0, path: '');
    }
  }

  Future<MiniappStorageUsage> usageOf(
    String appId, {
    String? name,
    DateTime? lastOpenedAt,
  }) async {
    final List<MiniappStorageEntry> entries = storageEntries(appId);
    final int bytes = entries.fold<int>(0, (int s, MiniappStorageEntry e) => s + e.bytes);

    final ({int bytes, int count, String path}) shared =
        await _scopeStats(appId, FileScope.files);
    final ({int bytes, int count, String path}) priv =
        await _scopeStats(appId, FileScope.private);

    return MiniappStorageUsage(
      appId: appId,
      name: name ?? appId,
      storageKeys: entries.length,
      storageBytes: bytes,
      fileCount: shared.count,
      fileBytes: shared.bytes,
      privateCount: priv.count,
      privateBytes: priv.bytes,
      lastOpenedAt: lastOpenedAt,
      filesPath: shared.path,
      privatePath: priv.path,
    );
  }

  /// 某个作用域根目录下出现过的 appId（用户手工放进去的也算）
  Future<List<String>> filesAppIds({
    FileScope scope = FileScope.defaultScope,
  }) async {
    try {
      final Directory root = await rootFor(scope);
      final List<String> ids = <String>[];
      await for (final FileSystemEntity entity in root.list(followLinks: false)) {
        if (entity is Directory) ids.add(p.basename(entity.path));
      }
      return ids;
    } catch (e) {
      lemonLog('Storage', '列举 ${scope.label}失败：$e');
      return <String>[];
    }
  }

  /// 两个作用域下出现过的 appId 合集 —— 权限/应用管理页要用它兜住
  /// 「只放了文件、没写过键值、也没打开过」的小程序。
  Future<List<String>> allFilesAppIds() async {
    final Set<String> ids = <String>{};
    for (final FileScope scope in FileScope.values) {
      ids.addAll(await filesAppIds(scope: scope));
    }
    return ids.toList(growable: false);
  }

  /// 扫描全部小程序的数据占用（appId 来源：注册表 ∪ storage ∪ 两个文件目录）
  Future<List<MiniappStorageUsage>> scanAll({
    Map<String, String> nameHints = const <String, String>{},
    Map<String, DateTime?> lastOpened = const <String, DateTime?>{},
  }) async {
    final Set<String> ids = <String>{
      ...SettingsService.instance.miniappStorageAppIds(),
      ...await allFilesAppIds(),
      ...nameHints.keys,
      ...lastOpened.keys,
    };
    final List<MiniappStorageUsage> result = <MiniappStorageUsage>[];
    for (final String id in ids) {
      if (id.trim().isEmpty) continue;
      result.add(
        await usageOf(
          id,
          name: nameHints[id],
          lastOpenedAt: lastOpened[id],
        ),
      );
    }
    result.sort((MiniappStorageUsage a, MiniappStorageUsage b) {
      final int bySize = b.totalBytes.compareTo(a.totalBytes);
      if (bySize != 0) return bySize;
      return a.name.compareTo(b.name);
    });
    return result;
  }

  // ---------------------------------------------------------------- 清理

  /// 清空某个小程序的键值存储，返回清掉的键数
  Future<int> clearStorage(String appId) async {
    final List<String> keys = SettingsService.instance
        .miniappStorageEntries(appId)
        .keys
        .toList(growable: false);
    return SettingsService.instance.removeMany(keys);
  }

  /// 删除某个小程序在某个作用域下的整个目录，返回是否删掉了东西
  Future<bool> clearFiles(
    String appId, {
    FileScope scope = FileScope.defaultScope,
  }) async {
    try {
      final Directory root = await rootFor(scope);
      final Directory dir = Directory(p.join(root.path, _sanitizeAppId(appId)));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        return true;
      }
    } catch (e) {
      lemonLog('Storage', '删除 $appId ${scope.label}失败：$e');
      rethrow;
    }
    return false;
  }

  /// 删单个 storage 键
  Future<bool> removeStorageEntry(String rawKey) =>
      SettingsService.instance.removeRaw(rawKey);

  /// 「清除数据」= storage + 两个文件目录 + 用量记录。
  /// 刻意**不**动授权设置：那是用户对该小程序的信任决定，清数据不该顺手重置。
  Future<void> clearAllData(String appId) async {
    await clearStorage(appId);
    for (final FileScope scope in FileScope.values) {
      await clearFiles(appId, scope: scope);
    }
    await PermissionService.instance.clearUsage(appId);
  }
}

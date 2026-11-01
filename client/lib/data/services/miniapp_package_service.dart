// lib/data/services/miniapp_package_service.dart
//
// 小程序包的下载 / 校验 / 解压 / 版本管理。
//
// 数据流（这是 0.6 的核心变化）：
//
//   服务端 /api/market/feed  → 拿到 packageUrl / version / sha256
//        ↓  比对本地已装版本
//   /data/user/0/<包名>/files/miniapps/<appId>/<version>/
//        ↓  完全不同就下载 zip → 校验 sha256 → 解压
//   WebView 用 file:// 打开 <dir>/<entry>
//
// 为什么不再用远程网页：
//   * 断网就用不了（小程序本该是「装好的东西」）
//   * 每次打开都要重新拉页面
//   * 没有版本概念 —— 用户没法知道装的是哪一版，也没法回滚
//
// 目录布局：
//   miniapps/<appId>/<version>/index.html     ← 解压后的包
//   miniapps/<appId>/<version>/.complete      ← 完成标记（解压成功的唯一凭据）
//
// 为什么用「.complete 标记」而不是「目录存在就算装好」：
//   解压到一半被系统杀掉，目录会存在但不完整。下次打开就会白屏/404，
//   而用户完全不知道发生了什么。写标记是最后一步，
//   没有标记的目录一律当作损坏，直接删掉重下。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/globals.dart';

/// 一个本地已安装的小程序包
class InstalledPackage {
  const InstalledPackage({
    required this.appId,
    required this.version,
    required this.entry,
    required this.dir,
  });

  final String appId;
  final String version;

  /// 入口文件的**包内相对路径**（如 `index.html`）
  final String entry;

  /// 解压后的根目录（绝对路径）
  final String dir;

  /// 入口文件的绝对路径
  String get entryPath => p.join(dir, entry);

  /// WebView 用的 file:// 地址
  String get entryUri => Uri.file(entryPath).toString();

  bool get isUsable => File(entryPath).existsSync();
}

/// 下载进度
class PackageProgress {
  const PackageProgress({
    required this.received,
    required this.total,
  });

  final int received;

  /// 总字节；0 表示服务端没给 Content-Length
  final int total;

  double? get fraction =>
      total > 0 ? (received / total).clamp(0.0, 1.0) : null;

  String get label => total > 0
      ? '${(received / 1024).toStringAsFixed(0)} / ${(total / 1024).toStringAsFixed(0)} KB'
      : '${(received / 1024).toStringAsFixed(0)} KB';
}

class PackageException implements Exception {
  const PackageException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'PackageException($code): $message';
}

/// 一次升级检查的结果
class PackageUpdate {
  const PackageUpdate({
    required this.appId,
    required this.name,
    required this.installedVersion,
    required this.latestVersion,
    required this.packageUrl,
    required this.entry,
    required this.sha256,
    required this.bytes,
  });

  final String appId;
  final String name;
  final String installedVersion;
  final String latestVersion;
  final String packageUrl;
  final String entry;
  final String sha256;
  final int bytes;

  /// 「1.0.0 → 1.1.0」
  String get versionLabel => installedVersion.isEmpty
      ? '新版本 $latestVersion'
      : '$installedVersion → $latestVersion';

  static PackageUpdate? fromJson(Map<String, dynamic> json) {
    final String id = (json['id'] ?? '').toString();
    final String url = (json['packageUrl'] ?? '').toString();
    if (id.isEmpty || url.isEmpty) return null;
    return PackageUpdate(
      appId: id,
      name: (json['name'] ?? id).toString(),
      installedVersion: (json['installedVersion'] ?? '').toString(),
      latestVersion: (json['latestVersion'] ?? '').toString(),
      packageUrl: url,
      entry: (json['packageEntry'] ?? 'index.html').toString(),
      sha256: (json['packageSha256'] ?? '').toString(),
      bytes: (json['packageBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class MiniappPackageService {
  MiniappPackageService._();

  static final MiniappPackageService instance = MiniappPackageService._();

  static const String _kCompleteMarker = '.complete';

  /// 单个包解压后的上限。与服务端的上传上限呼应（服务端 20MB 压缩包，
  /// 解压后按 4 倍膨胀留余量）。
  static const int maxExtractedBytes = 80 * 1024 * 1024;
  static const int maxEntries = 2000;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // 下载大文件不能按「请求超时」算，这里只限制「多久没收到数据」
      receiveTimeout: const Duration(minutes: 2),
      validateStatus: (int? s) => s != null,
    ),
  );

  Directory? _rootCache;

  /// miniapps/ 根目录
  Future<Directory> _root() async {
    final Directory? cached = _rootCache;
    if (cached != null && cached.existsSync()) return cached;
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(base.path, 'miniapps'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _rootCache = dir;
    return dir;
  }

  /// 某个应用的目录（含所有版本）
  Future<Directory> appDir(String appId) async {
    final Directory root = await _root();
    final String safe = _safeSegment(appId);
    return Directory(p.join(root.path, safe));
  }

  /// appId / version 会被当目录名用，必须挡住 `../` 之类
  String _safeSegment(String raw) {
    final String v = raw.trim();
    if (v.isEmpty) {
      throw const PackageException('bad_id', '应用 id 不能为空');
    }
    if (!RegExp(r'^[\w.\-+]+$').hasMatch(v)) {
      throw PackageException('bad_id', '应用 id 含非法字符：$raw');
    }
    return v;
  }

  // ---------------------------------------------------------------- 查询

  /// 本地已装的版本。没装 / 装坏了都返回 null。
  Future<InstalledPackage?> installed(String appId) async {
    final Directory dir = await appDir(appId);
    if (!dir.existsSync()) return null;

    // 目录里可能有多个版本；.complete 里记录了当前生效的那一个
    final File pointer = File(p.join(dir.path, 'current'));
    if (!pointer.existsSync()) return null;

    final String version;
    final String entry;
    try {
      final Map<String, dynamic> meta =
          jsonDecode(pointer.readAsStringSync()) as Map<String, dynamic>;
      version = (meta['version'] ?? '').toString();
      entry = (meta['entry'] ?? 'index.html').toString();
      if (version.isEmpty) return null;
    } catch (_) {
      return null;
    }

    final Directory versionDir = Directory(p.join(dir.path, _safeSegment(version)));
    if (!File(p.join(versionDir.path, _kCompleteMarker)).existsSync()) {
      // 目录在但没有完成标记：解压到一半被杀过。当作没装。
      lemonLog('Package', '$appId v$version 缺少完成标记，视为未安装');
      return null;
    }

    final InstalledPackage pkg = InstalledPackage(
      appId: appId,
      version: version,
      entry: entry,
      dir: versionDir.path,
    );
    return pkg.isUsable ? pkg : null;
  }

  /// 所有已装的包（升级检查要用）
  Future<List<InstalledPackage>> installedAll() async {
    final Directory root = await _root();
    final List<InstalledPackage> result = <InstalledPackage>[];
    if (!root.existsSync()) return result;

    for (final FileSystemEntity e in root.listSync()) {
      if (e is! Directory) continue;
      final InstalledPackage? pkg = await installed(p.basename(e.path));
      if (pkg != null) result.add(pkg);
    }
    return result;
  }

  // ---------------------------------------------------------------- 安装

  /// 下载并安装/升级一个包。
  ///
  /// [onProgress] 只在下载阶段回调（解压很快，不值得为它做 UI）。
  /// 成功后返回可打开的 [InstalledPackage]。
  Future<InstalledPackage> install({
    required String appId,
    required String version,
    required String packageUrl,
    required String sha256,
    String entry = 'index.html',
    void Function(PackageProgress)? onProgress,
  }) async {
    if (packageUrl.trim().isEmpty) {
      throw const PackageException('no_url', '这个应用还没有可下载的包');
    }
    final String safeVersion = _safeSegment(version);

    final Directory dir = await appDir(appId);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // ---- 1. 下载到临时文件 ----
    //
    // 为什么不整块读进内存：包上限 20MB，读进内存再校验也能跑，
    // 但下载失败时内存里那坨东西没有任何价值；落盘能让断点续传
    // （将来）与「校验前先确认大小」都更容易。
    final File tmp = File(p.join(dir.path, '.download-${DateTime.now().millisecondsSinceEpoch}.zip'));
    try {
      final Response<ResponseBody> res = await _dio.get<ResponseBody>(
        packageUrl,
        options: Options(responseType: ResponseType.stream),
      );
      // 先落到局部变量：`res.data` 是公共字段，Dart 的类型提升不会跨字段生效，
      // 后面每次 res.data.xxx 都要 `!` 的话很容易漏。
      final ResponseBody? body = res.data;
      if (res.statusCode != 200 || body == null) {
        throw PackageException(
          'download_failed',
          '下载失败（HTTP ${res.statusCode}）',
        );
      }

      final IOSink sink = tmp.openWrite();
      final int totalBytes = body.contentLength;
      int received = 0;
      try {
        await for (final List<int> chunk in body.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(PackageProgress(
            received: received,
            total: totalBytes,
          ));
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      // ---- 2. 校验 SHA-256 ----
      //
      // **这是唯一能保证「下载到的就是上架的那份」的手段。**
      // 没有它，一个被劫持的网络就能塞进任意 HTML —— 那个 HTML
      // 能调所有 JSBridge 能力。
      final String expected = sha256.trim().toLowerCase();
      if (expected.isNotEmpty) {
        final String actual =
            crypto.sha256.convert(await tmp.readAsBytes()).toString();
        if (actual != expected) {
          throw PackageException(
            'checksum_mismatch',
            '包校验失败（下载可能被中断或被篡改），已丢弃',
          );
        }
      } else {
        lemonLog('Package', '$appId 的服务端没给 sha256，跳过完整性校验');
      }

      // ---- 3. 解压到 <appId>/<version>/ ----
      final Directory target = Directory(p.join(dir.path, safeVersion));
      // 重装同一版本：先清掉旧的（否则旧文件会和新文件混在一起）
      if (target.existsSync()) target.deleteSync(recursive: true);
      target.createSync(recursive: true);

      final List<int> bytes = tmp.readAsBytesSync();
      await _extractTo(bytes, target);

      // ---- 4. 确认入口存在 ----
      final File entryFile = File(p.join(target.path, entry));
      if (!entryFile.existsSync()) {
        target.deleteSync(recursive: true);
        throw PackageException(
          'missing_entry',
          '包里没有入口文件 $entry（检查 lemonlite.json / package_entry）',
        );
      }

      // ---- 5. 写完成标记 + 切 current ----
      //
      // 顺序很重要：先写 .complete，再更新 current 指针。
      // 反过来的话，如果两步之间被杀，current 会指向一个没标记的目录 ——
      // installed() 会把它当作「没装」，用户看到的是「白下了一次」。
      File(p.join(target.path, _kCompleteMarker))
          .writeAsStringSync(DateTime.now().toIso8601String());

      File(p.join(dir.path, 'current')).writeAsStringSync(
        jsonEncode(<String, dynamic>{'version': safeVersion, 'entry': entry}),
      );

      lemonLog('Package', '$appId 安装完成：v$safeVersion（$received 字节）');

      return InstalledPackage(
        appId: appId,
        version: safeVersion,
        entry: entry,
        dir: target.path,
      );
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  /// 解压（带安全校验）。
  ///
  /// 安全约束与 bundle_repository 一致，但**这里的包来自我们自己的服务端**，
  /// 所以限制放宽了一点（2000 个文件 / 80MB）—— 一个正经的小程序
  /// 可能带不少图片。
  Future<void> _extractTo(List<int> bytes, Directory target) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (e) {
      throw PackageException('bad_zip', '包解析失败：$e');
    }

    if (archive.files.length > maxEntries) {
      throw PackageException(
        'too_many_files',
        '包内文件过多（${archive.files.length} 个，上限 $maxEntries）',
      );
    }

    int total = 0;
    final String rootPath = target.path;

    for (final ArchiveFile entry in archive.files) {
      if (!entry.isFile) continue;

      // 路径穿越防护：`../`、绝对路径、盘符一律拒绝。
      // 这是唯一能防止「包写到应用私有目录之外」的地方 ——
      // 而小程序目录在 data/data 里，旁边就是数据库与其它应用的数据。
      final String raw = entry.name.replaceAll('\\', '/');
      if (raw.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
        throw PackageException('bad_path', '包内有绝对路径：$raw');
      }
      final String normalized = p.normalize(raw);
      if (normalized == '..' || normalized.startsWith('../')) {
        throw PackageException('bad_path', '包内有越界路径：$raw');
      }

      final String outPath = p.join(rootPath, normalized);
      if (!p.isWithin(rootPath, outPath) && outPath != rootPath) {
        throw PackageException('bad_path', '包内路径越界：$raw');
      }

      final List<int>? content = entry.readBytes();
      if (content == null) continue;
      total += content.length;
      if (total > maxExtractedBytes) {
        throw const PackageException(
          'too_large',
          '解压后体积超过上限（疑似异常包）',
        );
      }

      final File outFile = File(outPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(content);
    }
  }

  // ---------------------------------------------------------------- 清理

  /// 删掉某个应用的所有包
  Future<void> remove(String appId) async {
    final Directory dir = await appDir(appId);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// 清理「不是当前版本」的旧目录（升级后留下的）
  Future<int> pruneOldVersions(String appId) async {
    final InstalledPackage? current = await installed(appId);
    if (current == null) return 0;
    final Directory dir = await appDir(appId);
    if (!dir.existsSync()) return 0;

    int removed = 0;
    final String currentName = p.basename(current.dir);
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! Directory) continue;
      if (p.basename(e.path) == currentName) continue;
      try {
        e.deleteSync(recursive: true);
        removed++;
      } catch (err) {
        lemonLog('Package', '清理旧版本失败（$err）');
      }
    }
    return removed;
  }

  /// 所有包占用的磁盘空间
  Future<int> totalBytes() async {
    final Directory root = await _root();
    if (!root.existsSync()) return 0;
    int total = 0;
    for (final FileSystemEntity e in root.listSync(recursive: true)) {
      if (e is File) {
        try {
          total += e.lengthSync();
        } catch (_) {
          // 文件刚好被删掉：忽略
        }
      }
    }
    return total;
  }

  /// 单个应用占用
  Future<int> appBytes(String appId) async {
    final Directory dir = await appDir(appId);
    if (!dir.existsSync()) return 0;
    int total = 0;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File) {
        try {
          total += e.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  }
}

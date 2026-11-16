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
//   WebView 用虚拟 https 源打开 <dir>/<entry>（见 core/miniapp_web_origin.dart）
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
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/globals.dart';
import '../../core/miniapp_web_origin.dart';
import '../models/miniapp_metadata.dart';

/// 一个本地已安装的小程序包
class InstalledPackage {
  const InstalledPackage({
    required this.appId,
    required this.version,
    required this.entry,
    required this.dir,
    this.metadata,
  });

  final String appId;
  final String version;

  /// 包自带的 metadata.json（老包可能没有）
  final MiniappMetadata? metadata;

  /// 入口文件的**包内相对路径**（如 `index.html`）
  final String entry;

  /// 解压后的根目录（绝对路径）
  final String dir;

  /// 入口文件的绝对路径
  String get entryPath => p.join(dir, entry);

  /// 入口的 file:// 地址 —— 只用于排障展示，WebView 不再加载它。
  ///
  /// 包里的 `<script type="module">` 在 file:// 下会被 CORS 挡掉（见
  /// core/miniapp_web_origin.dart 的说明），真正给 WebView 的是 [webUri]。
  String get entryUri => Uri.file(entryPath).toString();

  /// WebView 实际加载的虚拟 https 地址
  Uri get webUri => MiniappWebOrigin.entryUrl(
    appId: appId,
    version: version,
    entry: entry,
  );

  bool get isUsable => File(entryPath).existsSync();
}

/// 下载进度
class PackageProgress {
  const PackageProgress({required this.received, required this.total});

  final int received;

  /// 总字节；0 表示服务端没给 Content-Length
  final int total;

  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;

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
    this.icon = '',
    this.updatedAt,
  });

  final String appId;
  final String name;
  final String installedVersion;
  final String latestVersion;
  final String packageUrl;
  final String entry;
  final String sha256;
  final int bytes;

  /// 最新版本的图标地址（服务端返回绝对地址；可能为空）。
  /// 更新检查顺带把它缓存到本机，应用管理里才有图标可显示。
  final String icon;

  final DateTime? updatedAt;

  /// 「1.0.0 → 1.1.0」
  String get versionLabel => installedVersion.isEmpty
      ? '新版本 $latestVersion'
      : '$installedVersion → $latestVersion';

  /// 上次检查后服务端又发了一版？只要版本字符串不同就算（不比较大小）。
  bool get isInstalledOlder => installedVersion != latestVersion;

  PackageUpdate copyWith({String? icon, String? name, String? packageUrl}) =>
      PackageUpdate(
        appId: appId,
        name: name ?? this.name,
        installedVersion: installedVersion,
        latestVersion: latestVersion,
        packageUrl: packageUrl ?? this.packageUrl,
        entry: entry,
        sha256: sha256,
        bytes: bytes,
        icon: icon ?? this.icon,
        updatedAt: updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': appId,
    'name': name,
    'installedVersion': installedVersion,
    'latestVersion': latestVersion,
    'packageUrl': packageUrl,
    'packageEntry': entry,
    'packageSha256': sha256,
    'packageBytes': bytes,
    if (icon.isNotEmpty) 'icon': icon,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

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
      icon: (json['icon'] ?? '').toString(),
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()),
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

  /// 测试用：直接指定 miniapps 根目录，绕过 path_provider。
  ///
  /// 「导入本地 zip」的绝大部分逻辑是文件系统操作（解压、找入口、写完成标记、
  /// 清理旧版本），而这些恰恰是最容易写错的部分。为了测它们去 mock
  /// path_provider 的平台通道不值得 —— 给一个目录覆盖点更直接。
  @visibleForTesting
  Directory? debugRootOverride;

  /// miniapps/ 根目录
  ///
  /// WebView 的资源拦截器也要用它把虚拟 URL 映射回文件，所以对外暴露一份。
  Future<Directory> rootDirectory() => _root();

  Future<Directory> _root() async {
    final Directory? override = debugRootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
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

    final Directory versionDir = Directory(
      p.join(dir.path, _safeSegment(version)),
    );
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
      metadata: _tryReadMetadata(versionDir),
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
    final File tmp = File(
      p.join(
        dir.path,
        '.download-${DateTime.now().millisecondsSinceEpoch}.zip',
      ),
    );
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
          onProgress?.call(
            PackageProgress(received: received, total: totalBytes),
          );
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
        final String actual = crypto.sha256
            .convert(await tmp.readAsBytes())
            .toString();
        if (actual != expected) {
          throw PackageException('checksum_mismatch', '包校验失败（下载可能被中断或被篡改），已丢弃');
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

      // ---- 4. 读 metadata.json（包自己的身份与权限声明） ----
      //
      // 这一步在「确认入口」之前：入口路径以包自己的声明为准，
      // 服务端那份 package_entry 只是没有 metadata.json 时的兜底。
      //
      // 允许 zip 外面再套一层目录（作者用「右键压缩文件夹」打出来的包
      // 就是这样）：metadata.json 在唯一子目录里时，那个子目录就是包根，
      // 入口要带上这层前缀 —— 与 Service 端 zip_meta.js 的规则保持一致。
      final File? metadataFile = _findMetadataFile(target);
      final MiniappMetadata? metadata = metadataFile == null
          ? null
          : _readMetadataFile(metadataFile, appId: appId);
      final String prefix = metadataFile == null
          ? ''
          : p.relative(p.dirname(metadataFile.path), from: target.path);
      final String effectiveEntry = metadata == null
          ? entry
          : p.posix.normalize(
              p.posix.join(prefix.replaceAll('\\', '/'), metadata.entry),
            );

      // ---- 5. 确认入口存在 ----
      final File entryFile = File(p.join(target.path, effectiveEntry));
      if (!entryFile.existsSync()) {
        target.deleteSync(recursive: true);
        throw PackageException(
          'missing_entry',
          '包里没有入口文件 $effectiveEntry（检查 metadata.json 的 entry）',
        );
      }

      // ---- 6. 写完成标记 + 切 current ----
      //
      // 顺序很重要：先写 .complete，再更新 current 指针。
      // 反过来的话，如果两步之间被杀，current 会指向一个没标记的目录 ——
      // installed() 会把它当作「没装」，用户看到的是「白下了一次」。
      File(
        p.join(target.path, _kCompleteMarker),
      ).writeAsStringSync(DateTime.now().toIso8601String());

      File(p.join(dir.path, 'current')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'version': safeVersion,
          'entry': effectiveEntry,
        }),
      );

      lemonLog('Package', '$appId 安装完成：v$safeVersion（$received 字节）');

      return InstalledPackage(
        appId: appId,
        version: safeVersion,
        entry: effectiveEntry,
        dir: target.path,
        metadata: metadata,
      );
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  // ---------------------------------------------------------------- 本地导入
  //
  // 开发者模式下「小程序测试」用的入口：直接选一个本地 zip 打开，
  // 不用先传到服务端上架。
  //
  // 和上面 install() 的区别只在「包的来源」：
  //   * 不校验 sha256（包是用户自己选的，没有可比的期望值）；
  //   * 不比对版本号（调试时就是要覆盖，版本固定 `dev-<时间戳>`）；
  //   * 解压、路径穿越防护、入口确认、.complete 标记**完全复用**同一套 ——
  //     本地包也是包，不该走一条更宽松的路径。
  //
  // appId 优先取包内 metadata.json 的 id（这样一个调试包和将来上架的同 id
  // 应用共用沙箱，行为一致）；没有 metadata.json 就用文件名推一个。

  /// 本地 zip 的大小上限。与服务端上传上限一致（20MB）。
  static const int maxLocalZipBytes = 20 * 1024 * 1024;

  /// 从 zip 字节安装一个调试包，返回可打开的 [InstalledPackage]。
  Future<InstalledPackage> installLocalZip(
    Uint8List bytes, {
    String fileName = '',
    void Function(double fraction)? onProgress,
  }) async {
    if (bytes.isEmpty) {
      throw const PackageException('empty_zip', '这个文件是空的');
    }
    if (bytes.length > maxLocalZipBytes) {
      throw PackageException(
        'too_large',
        '包太大了（${(bytes.length / 1024 / 1024).toStringAsFixed(1)}MB，'
        '上限 ${maxLocalZipBytes ~/ 1024 ~/ 1024}MB）',
      );
    }

    final Directory root = await _root();
    final String stamp = DateTime.now().millisecondsSinceEpoch.toString();

    // 先解到临时目录：appId 要等读完 metadata.json 才知道，
    // 而目标路径依赖 appId。同盘 rename 是原子的，不会留下半个包。
    final Directory staging = Directory(p.join(root.path, '.import-$stamp'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);

    try {
      onProgress?.call(0.3);
      await _extractTo(bytes, staging);
      onProgress?.call(0.7);

      final File? metadataFile = _findMetadataFile(staging);
      final MiniappMetadata? metadata;
      final String appId;

      if (metadataFile != null) {
        final Object? decoded;
        try {
          decoded = jsonDecode(metadataFile.readAsStringSync());
        } catch (e) {
          throw PackageException('bad_metadata', 'metadata.json 不是合法 JSON：$e');
        }
        if (decoded is! Map) {
          throw const PackageException('bad_metadata', 'metadata.json 顶层必须是对象');
        }
        final String declared = (decoded['id'] ?? '').toString().trim();
        if (declared.isEmpty) {
          throw const PackageException(
            'bad_metadata',
            'metadata.json 缺少 id（它决定这个包以谁的身份运行）',
          );
        }
        appId = _safeSegment(declared);
        metadata = _readMetadataFile(metadataFile, appId: appId);
      } else {
        appId = _developerAppId(fileName);
        metadata = null;
      }

      final String prefix = metadataFile == null
          ? ''
          : p.relative(p.dirname(metadataFile.path), from: staging.path);
      final String entry = metadata == null
          ? 'index.html'
          : p.posix.normalize(
              p.posix.join(prefix.replaceAll('\\', '/'), metadata.entry),
            );

      // 版本固定带时间戳：每次导入都是一个干净的目录，
      // 不会出现「旧文件还留在里面，改了配置却没生效」这种诡异现象。
      final String version = 'dev-$stamp';
      final Directory appRoot = Directory(p.join(root.path, appId));
      appRoot.createSync(recursive: true);
      final Directory target = Directory(p.join(appRoot.path, version));
      if (target.existsSync()) target.deleteSync(recursive: true);

      onProgress?.call(0.9);
      staging.renameSync(target.path);

      if (!File(p.join(target.path, entry)).existsSync()) {
        target.deleteSync(recursive: true);
        // 顺手把刚建出来的空 <appId>/ 目录也删掉：
        // 留着它无害，但会让「导入失败后磁盘上多了个空目录」变成
        // 一个每次都要重新确认「这是不是上次失败留下的」的问题。
        _removeIfEmpty(appRoot);
        throw PackageException(
          'missing_entry',
          '包里没有入口文件 $entry（检查 metadata.json 的 entry，'
          '或者把首页命名成 index.html）',
        );
      }

      File(
        p.join(target.path, _kCompleteMarker),
      ).writeAsStringSync(DateTime.now().toIso8601String());
      File(p.join(appRoot.path, 'current')).writeAsStringSync(
        jsonEncode(<String, dynamic>{'version': version, 'entry': entry}),
      );

      // 只留这一次导入的结果：调试包没必要在磁盘上堆十个版本。
      _pruneDevVersions(appRoot, keep: version);

      onProgress?.call(1);
      lemonLog('Package', '本地导入 $appId：$version（${bytes.length} 字节）');

      return InstalledPackage(
        appId: appId,
        version: version,
        entry: entry,
        dir: target.path,
        metadata: metadata,
      );
    } finally {
      // 成功时 staging 已经被 rename 走了，这里只剩失败路径要清
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (_) {
          /* 清理失败不影响错误信息，下次导入会覆盖 */
        }
      }
    }
  }

  void _removeIfEmpty(Directory dir) {
    try {
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    } catch (_) {
      /* 删不掉就算了，空目录不影响功能 */
    }
  }

  /// 删掉同应用下旧的 `dev-*` 目录（不动正式安装的版本）
  void _pruneDevVersions(Directory appRoot, {required String keep}) {
    if (!appRoot.existsSync()) return;
    for (final FileSystemEntity e in appRoot.listSync()) {
      if (e is! Directory) continue;
      final String name = p.basename(e.path);
      if (!name.startsWith('dev-') || name == keep) continue;
      try {
        e.deleteSync(recursive: true);
      } catch (_) {
        /* 文件被占用时留到下次 */
      }
    }
  }

  /// 没有 metadata.json 时用文件名推 appId。
  ///
  /// 必须带 `dev.local.` 前缀：这样它永远不会和市场上的正式应用撞 id
  /// （正式 id 是作者自己填的反向域名，不会以 dev 开头）。
  String _developerAppId(String fileName) {
    String base = fileName.trim();
    if (base.isEmpty) base = 'package';
    base = p.basenameWithoutExtension(base);
    final String safe = base.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final String trimmed = safe.isEmpty ? 'package' : safe;
    return _safeSegment('dev.local.$trimmed');
  }

  /// 找 metadata.json：包根，或**唯一**子目录（作者多套了一层文件夹）。
  ///
  /// 多个子目录时不做猜测 —— 猜错会把入口指到别处，比直接报「没有 metadata」
  /// 更难排查。
  File? _findMetadataFile(Directory dir) {
    final File atRoot = File(p.join(dir.path, MiniappMetadata.fileName));
    if (atRoot.existsSync()) return atRoot;

    Directory? only;
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! Directory) continue;
      if (p.basename(entity.path).startsWith('.')) continue;
      if (only != null) return null;
      only = entity;
    }
    if (only == null) return null;
    final File nested = File(p.join(only.path, MiniappMetadata.fileName));
    return nested.existsSync() ? nested : null;
  }

  /// 严格读取 metadata.json（安装时用）：**存在就必须合法**，
  /// 因为它决定这个包以谁的身份运行、能拿到哪些权限。
  MiniappMetadata? _readMetadataFile(File file, {required String appId}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } catch (e) {
      throw PackageException('bad_metadata', 'metadata.json 不是合法 JSON：$e');
    }
    if (decoded is! Map) {
      throw const PackageException('bad_metadata', 'metadata.json 顶层必须是对象');
    }

    final MiniappMetadata? metadata = MiniappMetadata.parse(
      decoded.map<String, dynamic>(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      ),
    );
    if (metadata == null) {
      throw const PackageException(
        'bad_metadata',
        'metadata.json 缺少 id 或 name（这两个字段必须有）',
      );
    }
    if (metadata.id != appId) {
      // 顶替别人的 id 等于继承别人已授权的权限，必须拦在这里。
      throw PackageException(
        'metadata_mismatch',
        'metadata.json 的 id（${metadata.id}）与被安装的应用（$appId）不一致',
      );
    }
    if (metadata.needsNewerFramework) {
      throw PackageException(
        'framework_too_old',
        '这个包要求宿主 ${metadata.minFrameworkVersion} 以上，'
            '当前是 ${MiniappMetadata.currentFramework}，请先升级轻柠',
      );
    }
    return metadata;
  }

  /// 宽松读取（打开已有包时用）：读坏了就当没有，不能让小程序打不开。
  MiniappMetadata? _tryReadMetadata(Directory dir) {
    final File? file = _findMetadataFile(dir);
    if (file == null) return null;
    try {
      return _readMetadataFile(file, appId: p.basename(p.dirname(dir.path)));
    } catch (_) {
      return null;
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
        throw const PackageException('too_large', '解压后体积超过上限（疑似异常包）');
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

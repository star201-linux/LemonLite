
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/globals.dart';

class IconCacheService {
  IconCacheService._();

  static final IconCacheService instance = IconCacheService._();

  /// 单张图标上限。超过就丢弃：图标是几十 KB 的东西，一张 2MB 的「图标」
  /// 要么是数据错了，要么是有人想拿它占磁盘。
  static const int maxBytes = 2 * 1024 * 1024;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (int? status) =>
          status != null && status >= 200 && status < 300,
      // 图标可能被 302 到 CDN
      followRedirects: true,
      maxRedirects: 3,
    ),
  );

  Directory? _dirCache;

  /// 同一张图可能被列表里多处同时请求，合并成一次下载
  final Map<String, Future<String?>> _inflight = <String, Future<String?>>{};

  Future<Directory> _dir() async {
    final Directory? cached = _dirCache;
    if (cached != null && cached.existsSync()) return cached;
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(base.path, 'icons'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dirCache = dir;
    return dir;
  }

  /// appId 会进文件名：挡住 `/` 与 `..`
  String _safeId(String appId) {
    final String value = appId.trim();
    if (value.isEmpty) return '_';
    return value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  Future<File> _imageFile(String appId) async =>
      File(p.join((await _dir()).path, '${_safeId(appId)}.img'));

  Future<File> _metaFile(String appId) async =>
      File(p.join((await _dir()).path, '${_safeId(appId)}.src'));

  /// 本地已缓存的图标路径；没有则 null。
  Future<String?> pathOf(String appId) async {
    try {
      final File file = await _imageFile(appId);
      return file.existsSync() ? file.path : null;
    } catch (e) {
      lemonLog('IconCache', '读取 $appId 图标失败：$e');
      return null;
    }
  }

  /// 确保某个应用的图标已缓存，返回本地路径（失败时返回已有的旧图或 null）。
  ///
  /// [url] 为空表示「没有远程图标」：这时只返回已有的本地文件，不做任何下载。
  Future<String?> ensure({required String appId, String? url}) async {
    final String remote = url?.trim() ?? '';
    if (remote.isEmpty) return pathOf(appId);

    final String key = '$appId|$remote';
    final Future<String?>? running = _inflight[key];
    if (running != null) return running;

    final Future<String?> task = _download(appId, remote);
    _inflight[key] = task;
    try {
      return await task;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<String?> _download(String appId, String url) async {
    File? image;
    try {
      image = await _imageFile(appId);
      final File meta = await _metaFile(appId);

      // 已经缓存过同一张图：直接用
      if (image.existsSync() &&
          meta.existsSync() &&
          meta.readAsStringSync().trim() == url) {
        return image.path;
      }

      final Response<List<int>> res = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final List<int>? bytes = res.data;
      if (bytes == null || bytes.isEmpty) return _existing(image);
      if (bytes.length > maxBytes) {
        lemonLog('IconCache', '$appId 图标超过 ${maxBytes ~/ 1024} KB，忽略');
        return _existing(image);
      }
      // 只接受能识别的图片格式：服务端返回一个 404 页面也能拿到 200，
      // 存下来只会让 Image.file 报错并退回占位图，不如直接不写。
      if (!_looksLikeImage(bytes)) {
        lemonLog('IconCache', '$appId 的图标不是图片（${res.statusCode}），忽略');
        return _existing(image);
      }

      final File tmp = File('${image.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(image.path);
      await meta.writeAsString(url, flush: true);
      lemonLog('IconCache', '$appId 图标已缓存（${bytes.length} 字节）');
      return image.path;
    } catch (e) {
      // 网络失败不是错误状态：保留旧图，下次再试
      lemonLog('IconCache', '$appId 图标缓存失败：$e');
      if (image != null) return _existing(image);
      return null;
    }
  }

  String? _existing(File image) => image.existsSync() ? image.path : null;

  static bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 12) return false;
    final bool png =
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47;
    final bool jpeg = bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
    final bool gif = bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
    final bool webp =
        bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    return png || jpeg || gif || webp;
  }

  /// 删除某个应用的图标缓存（移除应用 / 清数据时调用）
  Future<void> remove(String appId) async {
    try {
      final File image = await _imageFile(appId);
      final File meta = await _metaFile(appId);
      if (image.existsSync()) image.deleteSync();
      if (meta.existsSync()) meta.deleteSync();
    } catch (e) {
      lemonLog('IconCache', '删除 $appId 图标失败：$e');
    }
  }

  /// 批量补齐。返回 appId → 本地路径。
  Future<Map<String, String?>> ensureAll(Map<String, String?> urls) async {
    final Map<String, String?> result = <String, String?>{};
    await Future.wait(
      urls.entries.map((MapEntry<String, String?> e) async {
        result[e.key] = await ensure(appId: e.key, url: e.value);
      }),
    );
    return result;
  }
}

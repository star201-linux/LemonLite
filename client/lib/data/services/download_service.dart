// lib/data/services/download_service.dart
//
// 下载管理的数据层：一条记录 = 系统 DownloadManager 里的一个任务。
//
// 设计上有一条硬约束：**文件落在公共「下载」目录，由系统下载器负责写**。
// 原因是 Android 10 起应用不能直接往 Download/ 写文件（要么 MediaStore、
// 要么 SAF、要么 MANAGE_EXTERNAL_STORAGE）。宿主不申请「所有文件」，
// 所以下载必须是「交给系统」，这也正是用户要的「网页下载调用下载器」。
//
// 由此产生的两个后果，都在这里处理：
//   1. 宿主读不了那些文件 → 记录里只存元数据（名字/大小/时间/状态），
//      「打开 / 删除」都走 DownloadManager 自己的 API（见 Kotlin DownloadBridge）。
//   2. DownloadManager 的 id 是系统分配的，重启 app 仍然有效 → 记录落盘，
//      启动时按 id 回查真实状态；查不到（用户清了数据、重装）就当失败条目留着，
//      由用户自己删掉，而不是悄悄消失。
//
// 平台：只有 Android 有通道。其它平台 `isSupported == false`，enqueue 直接抛
// DownloadException（界面据此显示「当前平台不支持下载」），不会静默不动。

import 'dart:async';
import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/globals.dart';
import '../../core/native_bridge.dart';
import '../models/json_utils.dart';
import 'settings_service.dart';

/// 下载状态。字符串值与 Kotlin 侧 DownloadBridge.statusName() 逐字对应。
enum DownloadStatus {
  pending('pending', '等待中'),
  running('running', '下载中'),
  paused('paused', '已暂停'),
  success('success', '已完成'),
  failed('failed', '失败'),
  canceled('canceled', '已取消');

  const DownloadStatus(this.id, this.label);

  final String id;
  final String label;

  /// 还在进行中（需要轮询进度）
  bool get isActive =>
      this == DownloadStatus.pending ||
      this == DownloadStatus.running ||
      this == DownloadStatus.paused;

  bool get isFinished => this == DownloadStatus.success;

  /// 宽松解析：认不出来就回落到 failed —— 一个不认识的系统状态
  /// 更可能是出错，而不是"完成了"。
  static DownloadStatus parse(
    Object? raw, {
    DownloadStatus fallback = DownloadStatus.failed,
  }) {
    final String value = raw?.toString().trim().toLowerCase() ?? '';
    for (final DownloadStatus status in values) {
      if (status.id == value) return status;
    }
    return fallback;
  }
}

/// 一条下载记录（不可变；进度更新时整体替换）。
@immutable
class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    required this.subDir,
    required this.createdAt,
    this.mimeType = '',
    this.status = DownloadStatus.pending,
    this.bytesReceived = 0,
    this.bytesTotal = 0,
    this.reason = '',
    this.localUri = '',
  });

  /// DownloadManager 的 id（系统分配；0 表示本地占位，不会出现在正常记录里）
  final int id;

  final String url;
  final String fileName;
  final String subDir;
  final String mimeType;
  final DateTime createdAt;

  final DownloadStatus status;
  final int bytesReceived;

  /// 总字节数；系统还不知道大小时是 -1（DownloadManager 的约定），
  /// 这里统一归一成 0，表示"未知"。
  final int bytesTotal;

  /// 失败/暂停原因（Kotlin 侧翻译好的人话）
  final String reason;

  /// 完成后的 content:// Uri（仅调试展示用）
  final String localUri;

  /// 相对下载目录的路径，如 `LemonLite/a.pdf`
  String get relativePath => subDir.isEmpty ? fileName : '$subDir/$fileName';

  /// 0~1；总大小未知时返回 null（界面显示不确定进度条）
  double? get progress {
    if (bytesTotal <= 0) return null;
    return (bytesReceived / bytesTotal).clamp(0.0, 1.0).toDouble();
  }

  String get sizeLabel {
    if (bytesTotal > 0)
      return '${formatBytes(bytesReceived)} / ${formatBytes(bytesTotal)}';
    if (bytesReceived > 0) return formatBytes(bytesReceived);
    return '未知大小';
  }

  String get createdLabel => formatDateTimeLabel(createdAt);

  DownloadTask copyWith({
    DownloadStatus? status,
    int? bytesReceived,
    int? bytesTotal,
    String? reason,
    String? localUri,
  }) => DownloadTask(
    id: id,
    url: url,
    fileName: fileName,
    subDir: subDir,
    mimeType: mimeType,
    createdAt: createdAt,
    status: status ?? this.status,
    bytesReceived: bytesReceived ?? this.bytesReceived,
    bytesTotal: bytesTotal ?? this.bytesTotal,
    reason: reason ?? this.reason,
    localUri: localUri ?? this.localUri,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'url': url,
    'fileName': fileName,
    'subDir': subDir,
    'mimeType': mimeType,
    // 落盘只存毫秒时间戳：ISO 字符串在不同时区/版本下解析过一次就够了
    'createdAt': createdAt.millisecondsSinceEpoch,
    'status': status.id,
    'bytesReceived': bytesReceived,
    'bytesTotal': bytesTotal,
    'reason': reason,
    if (localUri.isNotEmpty) 'localUri': localUri,
  };

  /// 宽松解析：缺 id / url 的条目直接丢弃（返回 null），
  /// 因为缺了它们这条记录既打不开也删不掉。
  static DownloadTask? fromJson(Map<String, dynamic> json) {
    final int id = (json['id'] as num?)?.toInt() ?? 0;
    final String url = asString(json['url']);
    if (id <= 0 || url.isEmpty) return null;
    final int createdAtMillis = (json['createdAt'] as num?)?.toInt() ?? 0;
    return DownloadTask(
      id: id,
      url: url,
      fileName: asString(json['fileName'], fallback: 'download-$id'),
      subDir: asString(json['subDir']),
      mimeType: asString(json['mimeType']),
      createdAt: createdAtMillis > 0
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMillis)
          : DateTime.now(),
      status: DownloadStatus.parse(
        json['status'],
        fallback: DownloadStatus.failed,
      ),
      bytesReceived: (json['bytesReceived'] as num?)?.toInt() ?? 0,
      bytesTotal: (json['bytesTotal'] as num?)?.toInt() ?? 0,
      reason: asString(json['reason']),
      localUri: asString(json['localUri']),
    );
  }
}

/// 下载失败的可预期原因。界面直接展示 message。
class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 下载服务（单例）。
///
/// 为什么是 ChangeNotifier + 单例：下载进度要在「小程序页面（触发）」与
/// 「下载管理页（展示）」之间共享，而且要能跨页面存活。轮询只在这一层做，
/// 页面只消费快照。
class DownloadService extends ChangeNotifier {
  DownloadService._(this._settings);

  final SettingsService _settings;

  static DownloadService? _instance;

  static DownloadService get instance {
    final DownloadService? service = _instance;
    if (service == null) {
      throw StateError('DownloadService 尚未初始化，请先看 main() 里的 init 顺序');
    }
    return service;
  }

  /// 在 main()、SettingsService.init() 之后调用。
  ///
  /// 刻意同步：初始化只读 SharedPreferences，没有网络/文件扫描。
  static DownloadService init() =>
      _instance = DownloadService._(SettingsService.instance);

  /// 与 Kotlin 侧 DownloadBridge.CHANNEL_NAME 逐字一致。
  static const MethodChannel channel = MethodChannel('lemonlite/downloads');

  static const String _kTasks = 'download.tasks';
  static const String _kSubDir = 'download.subdir';

  /// 记录上限：只保留最近这么多条，避免 SharedPreferences 无限增长。
  static const int maxRecords = 100;

  /// 轮询间隔。系统下载器本身没有"进度回调"，
  /// 查得太密没意义，1 秒足够让进度条看起来是连续的。
  static const Duration pollInterval = Duration(seconds: 1);

  static const String _legacyWritePermission =
      'android.permission.WRITE_EXTERNAL_STORAGE';

  List<DownloadTask> _tasks = <DownloadTask>[];
  Timer? _pollTimer;
  int? _sdkInt;

  /// 是否支持（只有 Android 有下载通道）
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 全部记录，最新的在前
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  List<DownloadTask> get activeTasks => _tasks
      .where((DownloadTask t) => t.status.isActive)
      .toList(growable: false);

  bool get hasActive => activeTasks.isNotEmpty;

  /// 已完成的条数（页面上的概览用）
  int get finishedCount =>
      _tasks.where((DownloadTask t) => t.status.isFinished).length;

  /// 失败 / 已取消的条数（"清理"按钮只针对这些）
  int get cleanupableCount => _tasks
      .where(
        (DownloadTask t) =>
            t.status == DownloadStatus.failed ||
            t.status == DownloadStatus.canceled,
      )
      .length;

  /// 下载子目录（相对公共下载目录）。默认空串 = 直接放在 Download/ 根下。
  String get subDir => _settings.readRaw(_kSubDir) ?? '';

  Future<void> setSubDir(String value) async {
    final String cleaned = _sanitizeSubDir(value);
    if (cleaned == subDir) return;
    await _settings.writeRaw(_kSubDir, cleaned);
    notifyListeners();
  }

  /// 完整的下载目录展示（`Download/` 或 `Download/LemonLite/`）
  String get directoryLabel => subDir.isEmpty ? 'Download' : 'Download/$subDir';

  // ------------------------------------------------------------ 初始化

  /// 启动时调用：读盘 + 回查未完成任务。
  ///
  /// 这里刻意不 await 任何东西：启动路径已经够长了，
  /// 回查进度在后台跑，界面晚一秒看到结果完全可以接受。
  void start() {
    _loadTasks();
    if (!isSupported) return;
    unawaited(refresh());
  }

  void _loadTasks() {
    final String? raw = _settings.readRaw(_kTasks);
    if (raw == null || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final List<DownloadTask> loaded = <DownloadTask>[];
      for (final Object? item in decoded) {
        if (item is! Map) continue;
        final DownloadTask? task = DownloadTask.fromJson(
          item.map<String, dynamic>(
            (Object? k, Object? v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
        if (task != null) loaded.add(task);
      }
      _tasks = loaded;
    } catch (e) {
      lemonLog('Download', '下载记录损坏，按空处理：$e');
      _tasks = <DownloadTask>[];
    }
  }

  Future<void> _persist() async {
    if (_tasks.length > maxRecords) {
      _tasks = _tasks.take(maxRecords).toList(growable: true);
    }
    try {
      await _settings.writeRaw(
        _kTasks,
        jsonEncode(_tasks.map((DownloadTask t) => t.toJson()).toList()),
      );
    } catch (e) {
      lemonLog('Download', '保存下载记录失败：$e');
    }
  }

  // ------------------------------------------------------------ 权限

  /// Android 9 及以下往公共下载目录写文件需要 WRITE_EXTERNAL_STORAGE。
  ///
  /// 只有这一层需要：Android 10+ 由系统下载器落盘，零权限。
  Future<bool> ensureLegacyPermission() async {
    if (!isSupported) return true;
    final int sdk = await _androidSdkInt();
    if (sdk >= 29) return true;
    try {
      return await NativeBridge.requestRuntimePermissions(<String>[
        _legacyWritePermission,
      ]);
    } catch (e) {
      lemonLog('Download', '申请存储权限失败：$e');
      return false;
    }
  }

  /// 当前系统是否属于"需要申请存储权限"的老版本（设置页据此显示权限入口）
  Future<bool> get needsLegacyPermission async =>
      isSupported && (await _androidSdkInt()) < 29;

  Future<int> _androidSdkInt() async {
    final int? cached = _sdkInt;
    if (cached != null) return cached;
    try {
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      _sdkInt = info.version.sdkInt;
    } catch (e) {
      lemonLog('Download', '读取系统版本失败，按新系统处理（不申请存储权限）：$e');
      _sdkInt = 33;
    }
    return _sdkInt!;
  }

  // ------------------------------------------------------------ 新建下载

  /// 发起一次下载。
  ///
  /// [fileName] 为空时按 [deriveFileName] 从 suggest / Content-Disposition /
  /// URL / MIME 推断；推断不出来才用时间戳兜底 —— 绝不把空的 url 路径
  /// 直接当文件名（那会得到 `download`，多下几次就互相覆盖）。
  Future<DownloadTask> enqueue({
    required String url,
    String? fileName,
    String? mimeType,
    Map<String, String>? headers,
  }) async {
    if (!isSupported) {
      throw const DownloadException('当前平台不支持下载（只有 Android 会调用系统下载器）');
    }
    final String trimmed = url.trim();
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const DownloadException(
        '只能下载 http(s) 链接；blob: / data: 这类地址请让页面改成直接给出文件地址',
      );
    }

    final bool allowed = await ensureLegacyPermission();
    if (!allowed) {
      throw const DownloadException('没有存储权限，无法写入下载目录。请到系统设置里允许「存储」权限后重试。');
    }

    final String name = deriveFileName(
      suggested: fileName,
      url: trimmed,
      mimeType: mimeType,
    );

    try {
      final Object? raw = await channel
          .invokeMethod<Object?>('enqueue', <String, Object?>{
            'url': trimmed,
            'fileName': name,
            'subDir': subDir,
            'mimeType': mimeType ?? '',
            if (headers != null && headers.isNotEmpty) 'headers': headers,
          });
      if (raw is! Map) {
        throw const DownloadException('系统下载器返回了无法识别的结果');
      }
      final int id = (raw['id'] as num?)?.toInt() ?? 0;
      if (id <= 0) throw const DownloadException('系统下载器没有返回任务 id');

      final DownloadTask task = DownloadTask(
        id: id,
        url: trimmed,
        fileName: asString(raw['fileName'], fallback: name),
        subDir: asString(raw['subDir'], fallback: subDir),
        mimeType: asString(raw['mimeType'], fallback: mimeType ?? ''),
        createdAt: DateTime.now(),
      );
      _tasks.insert(0, task);
      await _persist();
      notifyListeners();
      _startPolling();
      lemonLog('Download', '开始下载 #$id：${task.relativePath} ← $trimmed');
      return task;
    } on PlatformException catch (e) {
      throw DownloadException('系统下载器拒绝了这个任务：${e.message ?? e.code}');
    } on MissingPluginException {
      throw const DownloadException('下载通道未注册（这个安装包可能是旧版本）');
    }
  }

  // ------------------------------------------------------------ 进度

  /// 回查所有未完成任务的真实状态。
  Future<void> refresh() async {
    if (!isSupported) return;
    if (_tasks.isEmpty) return;

    bool changed = false;
    final List<DownloadTask> next = List<DownloadTask>.of(_tasks);
    for (int i = 0; i < next.length; i++) {
      final DownloadTask task = next[i];
      if (!task.status.isActive && task.status != DownloadStatus.canceled)
        continue;
      if (task.status == DownloadStatus.canceled) continue;
      try {
        final Object? raw = await channel.invokeMethod<Object?>(
          'query',
          <String, Object?>{'id': task.id},
        );
        if (raw is! Map) continue;
        if (raw['found'] != true) {
          // 系统里已经没有这个任务（清了下载器数据/重装）：标记失败并留痕
          next[i] = task.copyWith(
            status: DownloadStatus.failed,
            reason: '系统下载器里找不到这个任务（可能被清除过数据）',
          );
          changed = true;
          continue;
        }
        final DownloadStatus status = DownloadStatus.parse(
          raw['status'],
          fallback: task.status,
        );
        final int received =
            (raw['bytesReceived'] as num?)?.toInt() ?? task.bytesReceived;
        final int totalRaw =
            (raw['bytesTotal'] as num?)?.toInt() ?? task.bytesTotal;
        final int total = totalRaw < 0 ? 0 : totalRaw;
        final String reason = asString(raw['reasonText']);
        final String localUri = asString(raw['localUri']);
        if (status != task.status ||
            received != task.bytesReceived ||
            total != task.bytesTotal ||
            reason != task.reason) {
          next[i] = task.copyWith(
            status: status,
            bytesReceived: received,
            bytesTotal: total,
            reason: reason,
            localUri: localUri,
          );
          changed = true;
        }
      } on PlatformException catch (e) {
        lemonLog('Download', '查询 #${task.id} 失败：${e.message}');
      } on MissingPluginException {
        return; // 通道没注册：整条链路都不通，别再挨个试
      }
    }

    if (changed) {
      _tasks = next;
      await _persist();
      notifyListeners();
    }
    _syncPolling();
  }

  void _startPolling() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(pollInterval, (Timer _) {
      unawaited(refresh());
    });
  }

  void _syncPolling() {
    if (!hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
    } else {
      _startPolling();
    }
  }

  // ------------------------------------------------------------ 操作

  /// 取消（DownloadManager.remove 会连同已下载的部分一起删掉）
  Future<bool> cancel(int id) async {
    final bool removed = await _nativeRemove(id);
    _replaceStatus(
      id,
      DownloadStatus.canceled,
      reason: removed ? '已取消' : '已取消（系统里没找到该任务）',
    );
    return removed;
  }

  /// 删除记录。`deleteFile` 为 true 时同时让系统删掉文件。
  Future<bool> delete(int id, {bool deleteFile = true}) async {
    if (deleteFile) await _nativeRemove(id);
    _tasks.removeWhere((DownloadTask t) => t.id == id);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<bool> _nativeRemove(int id) async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>(
        'remove',
        <String, Object?>{'id': id},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      lemonLog('Download', '删除 #$id 失败：${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 用系统里注册的「打开方式」打开已下载的文件
  Future<bool> open(int id) async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>(
        'open',
        <String, Object?>{'id': id},
      );
      return ok ?? false;
    } on PlatformException catch (e) {
      lemonLog('Download', '打开 #$id 失败：${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开系统的「下载」界面
  Future<bool> openDirectory() async {
    if (!isSupported) return false;
    try {
      final bool? ok = await channel.invokeMethod<bool>('openDirectory');
      return ok ?? false;
    } on PlatformException catch (e) {
      lemonLog('Download', '打开下载目录失败：${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 重试：去掉旧记录，用同一个地址重新入队（文件名沿用）。
  Future<DownloadTask?> retry(int id) async {
    final DownloadTask? old = _taskById(id);
    if (old == null) return null;
    await delete(id);
    try {
      return await enqueue(
        url: old.url,
        fileName: old.fileName,
        mimeType: old.mimeType.isEmpty ? null : old.mimeType,
      );
    } on DownloadException catch (e) {
      lemonLog('Download', '重试 #$id 失败：${e.message}');
      return null;
    }
  }

  /// 清掉失败 / 已取消的**记录**（不动正在下载的，也不动已完成的）。
  ///
  /// 为什么不顺手把已完成的也清掉：清记录不删文件 —— 那会让文件留在
  /// Download/ 里却查不到来源，是比"记录多"糟糕得多的问题；
  /// 而删除文件需要用户明确点一次（管理页每条都有删除按钮）。
  Future<int> clearFinished() async {
    final int before = _tasks.length;
    _tasks.removeWhere(
      (DownloadTask t) =>
          t.status == DownloadStatus.canceled ||
          t.status == DownloadStatus.failed,
    );
    final int removed = before - _tasks.length;
    if (removed > 0) {
      await _persist();
      notifyListeners();
    }
    return removed;
  }

  void _replaceStatus(int id, DownloadStatus status, {String? reason}) {
    final int index = _tasks.indexWhere((DownloadTask t) => t.id == id);
    if (index < 0) return;
    _tasks[index] = _tasks[index].copyWith(status: status, reason: reason);
    unawaited(_persist());
    notifyListeners();
    _syncPolling();
  }

  DownloadTask? _taskById(int id) {
    for (final DownloadTask task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  // ------------------------------------------------------------ 纯函数

  /// 从各种来源推断文件名。**纯函数**，方便单测。
  ///
  /// 优先级：显式 suggest > Content-Disposition > URL 路径 > 时间戳兜底。
  /// 这个顺序对应"可信度"：网页自己给的名字最准，URL 里的名字常被编码过，
  /// 而兜底名字唯一的作用是让文件不重名。
  static String deriveFileName({
    String? suggested,
    String? contentDisposition,
    required String url,
    String? mimeType,
    DateTime? now,
  }) {
    final List<String?> candidates = <String?>[
      suggested,
      _fromContentDisposition(contentDisposition),
      _fromUrl(url),
    ];
    for (final String? candidate in candidates) {
      // 先只取「路径最后一段」再清洗：suggested 里可能带 `../../etc/passwd`
      // 这种路径，直接清洗会得到 `_.._etc_passwd`（安全但不像个文件名）。
      // 注意 sanitizeFileName 本身仍然负责「把分隔符换成 _」，两者职责不同。
      final String raw = (candidate ?? '').replaceAll('\\', '/');
      final int slash = raw.lastIndexOf('/');
      final String leaf = slash >= 0 ? raw.substring(slash + 1) : raw;
      final String cleaned = sanitizeFileName(leaf);
      if (cleaned.isNotEmpty) return _withExtension(cleaned, mimeType);
    }
    final int stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final String fallback = 'download-$stamp';
    return _withExtension(fallback, mimeType);
  }

  /// 文件名清洗：这是一条**安全边界**（文件名来自网页/服务端，属于不可信输入）。
  ///
  /// 挡掉的东西：路径分隔符（能写出子目录甚至穿越）、Windows 保留字符、
  /// 控制字符、前导点（隐藏文件）、超长名字（保留扩展名截断）。
  static String sanitizeFileName(String raw) {
    String name = raw.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    name = name.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    name = name.replaceFirst(RegExp(r'^\.+'), '');
    if (name == '_' || name == '-') return '';
    if (name.length > 200) {
      final int dot = name.lastIndexOf('.');
      final String ext = dot > 0 && name.length - dot <= 10
          ? name.substring(dot)
          : '';
      name = name.substring(0, 200 - ext.length) + ext;
    }
    return name;
  }

  static String? _fromContentDisposition(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    // RFC 5987 的 filename*=UTF-8''... 先解析：它比 filename= 更准（支持非 ASCII）
    final RegExp extended = RegExp(
      r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)",
      caseSensitive: false,
    );
    final RegExpMatch? extMatch = extended.firstMatch(raw);
    if (extMatch != null) {
      try {
        final String decoded = Uri.decodeComponent(extMatch.group(2)!.trim());
        if (decoded.trim().isNotEmpty) return decoded;
      } catch (_) {
        // 编码坏了就退回普通 filename
      }
    }
    final RegExp plain = RegExp(
      r'filename\s*=\s*"([^"]*)"',
      caseSensitive: false,
    );
    final RegExpMatch? quoted = plain.firstMatch(raw);
    if (quoted != null) return quoted.group(1);
    final RegExp bare = RegExp(r'filename\s*=\s*([^;]+)', caseSensitive: false);
    final RegExpMatch? loose = bare.firstMatch(raw);
    if (loose != null) return loose.group(1)!.replaceAll('"', '').trim();
    return null;
  }

  static String? _fromUrl(String url) {
    try {
      final Uri uri = Uri.parse(url);
      final List<String> segments = uri.pathSegments
          .where((String s) => s.isNotEmpty)
          .toList(growable: false);
      if (segments.isEmpty) return null;
      // pathSegments **已经做过百分号解码**，这里不能再 decodeComponent 一次：
      // 二次解码遇到中文会直接抛 Illegal percent encoding（旧实现的 bug），
      // 结果所有带中文文件名的 URL 都会退化成时间戳文件名。
      return segments.last;
    } catch (_) {
      return null;
    }
  }

  static const Map<String, String> _mimeExtensions = <String, String>{
    'application/pdf': 'pdf',
    'application/zip': 'zip',
    'application/json': 'json',
    'application/x-tar': 'tar',
    'application/gzip': 'gz',
    'application/vnd.android.package-archive': 'apk',
    'application/octet-stream': 'bin',
    'text/plain': 'txt',
    'text/html': 'html',
    'text/csv': 'csv',
    'text/markdown': 'md',
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/gif': 'gif',
    'image/webp': 'webp',
    'audio/mpeg': 'mp3',
    'audio/ogg': 'ogg',
    'video/mp4': 'mp4',
    'video/webm': 'webm',
  };

  /// 名字没有扩展名时按 MIME 补一个；有扩展名就原样返回。
  static String _withExtension(String name, String? mimeType) {
    if (name.contains('.') && !name.endsWith('.')) return name;
    final String mime = (mimeType ?? '').split(';').first.trim().toLowerCase();
    final String? ext = _mimeExtensions[mime];
    if (ext == null) return name;
    return '$name.$ext';
  }

  /// 子目录清洗：只允许相对路径，挡掉 `..` 与绝对路径（与录文件名同一套理由）。
  static String _sanitizeSubDir(String raw) {
    final List<String> parts = raw
        .trim()
        .replaceAll('\\', '/')
        .split('/')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && s != '.')
        .map((String s) => sanitizeFileName(s))
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
    return parts.join('/');
  }
}

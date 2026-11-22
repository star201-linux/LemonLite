
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一条日志
@immutable
class LogEntry {
  const LogEntry({
    required this.at,
    required this.tag,
    required this.message,
    this.level = LogLevel.info,
  });

  final DateTime at;
  final String tag;
  final String message;
  final LogLevel level;

  /// `12:34:56.789  [Tag]  内容`
  String get formatted {
    final String t = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}.'
        '${at.millisecond.toString().padLeft(3, '0')}';
    return '$t  [${level.label}] [$tag]  $message';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': at.toIso8601String(),
    'lvl': level.name,
    'tag': tag,
    'msg': message,
  };
}

enum LogLevel {
  debug('D'),
  info('I'),
  warn('W'),
  error('E');

  const LogLevel(this.label);
  final String label;
}

/// 全局日志缓冲区
class RunLog {
  RunLog._();

  static final RunLog instance = RunLog._();

  /// 最多保留多少条。超出后丢**最旧**的（最近的更可能相关）。
  static const int maxEntries = 2000;

  final List<LogEntry> _entries = <LogEntry>[];

  /// 监听器（调试页要实时刷新）
  final List<VoidCallback> _listeners = <VoidCallback>[];

  /// 本次运行开始的时间（导出文件的头部用）
  final DateTime startedAt = DateTime.now();

  /// 应用版本（main 里写入，导出文件头部用）
  String appVersion = '';
  String frameworkVersion = '';

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  /// 记一条
  void add(String tag, Object? message, {LogLevel level = LogLevel.info}) {
    final String text = _redact('$message');
    _entries.add(
      LogEntry(at: DateTime.now(), tag: tag, message: text, level: level),
    );

    if (_entries.length > maxEntries) {
      _entries.removeRange(0, (maxEntries * 0.1).ceil());
    }

    // 错误额外走一次 debugPrint，方便连着 adb 时直接看到
    if (level == LogLevel.error) {
      debugPrint('[$tag] $text');
    }

    for (final VoidCallback l in _listeners) {
      l();
    }
  }

  void debug(String tag, Object? message) =>
      add(tag, message, level: LogLevel.debug);
  void info(String tag, Object? message) =>
      add(tag, message, level: LogLevel.info);
  void warn(String tag, Object? message) =>
      add(tag, message, level: LogLevel.warn);
  void error(String tag, Object? message) =>
      add(tag, message, level: LogLevel.error);

  void installErrorHooks() {
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details); // 保留原本为（debug 红屏 / release 静默）
      add(
        'flutter',
        details.exceptionAsString(),
        level: LogLevel.error,
      );
      // 堆栈对定位至关重要，但可能很长 —— 截断到前 40 行
      final String? stack = details.stack?.toString();
      if (stack != null && stack.isNotEmpty) {
        final List<String> lines = stack.split('\n');
        add(
          'flutter',
          lines.take(40).join('\n'),
          level: LogLevel.debug,
        );
      }
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      add(
        'uncaught',
        '$error\n${stack.toString().split('\n').take(40).join('\n')}',
        level: LogLevel.error,
      );
      return true; // 已记录，交给默认处理
    };
  }

  /// 清空（调试页上的「清空」按钮）
  void clear() {
    _entries.clear();
    for (final VoidCallback l in _listeners) {
      l();
    }
  }

  // ---------------------------------------------------------------- 导出

  /// 导出成文本。返回写入的文件。
  ///
  /// 落在**应用私有目录**下：不需要存储权限，而且「导出」的实际动作
  /// 是把路径显示给用户 / 走系统分享（见调试页）。
  Future<File> export() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final Directory logs = Directory(p.join(dir.path, 'logs'));
    if (!logs.existsSync()) logs.createSync(recursive: true);

    final String stamp = _fileStamp(DateTime.now());
    final File file = File(p.join(logs.path, 'lemonlite-$stamp.log'));
    await file.writeAsString(_buildReport());
    return file;
  }

  /// 导出成 JSON（给机器读；排障时比文本更好筛）
  Future<File> exportJson() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final Directory logs = Directory(p.join(dir.path, 'logs'));
    if (!logs.existsSync()) logs.createSync(recursive: true);

    final String stamp = _fileStamp(DateTime.now());
    final File file = File(p.join(logs.path, 'lemonlite-$stamp.json'));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'startedAt': startedAt.toIso8601String(),
        'exportedAt': DateTime.now().toIso8601String(),
        'appVersion': appVersion,
        'frameworkVersion': frameworkVersion,
        'entryCount': _entries.length,
        'entries': _entries.map((LogEntry e) => e.toJson()).toList(),
      }),
    );
    return file;
  }

  /// 导出文本的全文（也用于「复制到剪贴板」）
  String _buildReport() {
    final StringBuffer b = StringBuffer();
    b.writeln('LemonLite 运行日志');
    b.writeln('=' * 60);
    b.writeln('应用版本   $appVersion');
    b.writeln('框架版本   $frameworkVersion');
    b.writeln('启动时间   ${startedAt.toIso8601String()}');
    b.writeln('导出时间   ${DateTime.now().toIso8601String()}');
    b.writeln('日志条数   ${_entries.length}');
    b.writeln('=' * 60);
    b.writeln('');
    for (final LogEntry e in _entries) {
      b.writeln(e.formatted);
    }
    return b.toString();
  }

  String _fileStamp(DateTime t) =>
      '${t.year}${pad2(t.month)}${pad2(t.day)}-'
      '${pad2(t.hour)}${pad2(t.minute)}${pad2(t.second)}';

  static String pad2(int v) => v.toString().padLeft(2, '0');

  static String _redact(String input) {
    String out = input;

    // Bearer <token>
    out = out.replaceAllMapped(
      RegExp(r'(Bearer\s+)([A-Za-z0-9._~+/=-]{8,})', caseSensitive: false),
      (Match m) => '${m.group(1)}***',
    );

    // token=xxx / password=xxx / secret=xxx（查询串或日志里的 k=v）
    out = out.replaceAllMapped(
      RegExp(
        r'\b(token|password|passwd|pwd|secret|api[_-]?key|authorization)'
        r'(\s*[=:]\s*)([^\s,;&"]{4,})',
        caseSensitive: false,
      ),
      (Match m) => '${m.group(1)}${m.group(2)}***',
    );

    // 本服务的 token 前缀
    out = out.replaceAll(RegExp(r'lmn_[A-Za-z0-9_-]{8,}'), 'lmn_***');

    // 三段式 JWT
    out = out.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}'),
      'eyJ***',
    );

    return out;
  }
}

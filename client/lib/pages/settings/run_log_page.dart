// lib/pages/settings/run_log_page.dart
//
// 开发者选项 →「运行日志」。
//
// 这个页面存在的唯一目的：让用户把「刚才到底发生了什么」发回来。
// 所以它的第一优先级是**导出**，而不是好看。
//
// 三件事：
//   1. 实时显示日志（带级别筛选）
//   2. 导出成 .log 文件 / 复制到剪贴板
//   3. 显示导出文件的路径（用户要能找到它）

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/run_log.dart';
import '../../theme/app_theme.dart';

class RunLogPage extends StatefulWidget {
  const RunLogPage({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (BuildContext context) => const RunLogPage());

  @override
  State<RunLogPage> createState() => _RunLogPageState();
}

class _RunLogPageState extends State<RunLogPage> {
  /// 当前筛选：null = 全部
  LogLevel? _levelFilter;

  /// 自动滚到底
  bool _autoScroll = true;

  final ScrollController _scroll = ScrollController();

  /// 导出后的路径（显示在顶部）
  String? _exportedPath;

  @override
  void initState() {
    super.initState();
    RunLog.instance.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    RunLog.instance.removeListener(_onLogChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onLogChanged() {
    if (!mounted) return;
    setState(() {});
    if (_autoScroll) {
      // 放到帧末尾：日志可能在 build 期间到达
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  List<LogEntry> get _visible {
    final List<LogEntry> all = RunLog.instance.entries;
    if (_levelFilter == null) return all;
    return all.where((LogEntry e) => e.level == _levelFilter).toList(growable: false);
  }

  /// 导出文本日志并**弹系统分享面板**。
  ///
  /// 为什么必须分享而不是只写文件：文件落在应用私有目录
  ///（`/data/data/<pkg>/files/logs/…`），未 root 的机器上连文件管理器
  /// 都进不去，用户拿不到 —— 那等于没导出。分享面板能把文件交给
  /// 微信 / 邮件 / 保存到「下载」，这才算真的导出。
  Future<void> _export() async {
    await _share(() => RunLog.instance.export(), '运行日志');
  }

  Future<void> _exportJson() async {
    await _share(() => RunLog.instance.exportJson(), '运行日志（JSON）');
  }

  /// 写文件 → 调起分享。失败时把原因显示出来（用户要能判断怎么绕）。
  Future<void> _share(Future<File> Function() build, String subject) async {
    try {
      final File file = await build();
      if (!mounted) return;
      setState(() => _exportedPath = file.path);

      // 分享的是**文件本身**（不是路径字符串）。
      // sharePositionOrigin 是 iPad 上弹出气泡必需的，Android 忽略。
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        <XFile>[XFile(file.path, mimeType: 'text/plain')],
        subject: subject,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (e) {
      if (!mounted) return;
      AppTheme.showToast('导出失败：$e', isError: true);
    }
  }

  Future<void> _copy() async {
    final StringBuffer b = StringBuffer();
    for (final LogEntry e in _visible) {
      b.writeln(e.formatted);
    }
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (!mounted) return;
    AppTheme.showToast('已复制 ${_visible.length} 条日志');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<LogEntry> visible = _visible;
    final int total = RunLog.instance.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: <Widget>[
          IconButton(
            tooltip: '复制到剪贴板',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: visible.isEmpty ? null : _copy,
          ),
          IconButton(
            tooltip: '导出为文件',
            icon: const Icon(Icons.save_alt),
            onPressed: _export,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (String v) {
              if (v == 'clear') {
                RunLog.instance.clear();
                setState(() => _exportedPath = null);
              } else if (v == 'json') {
                _exportJson();
              }
            },
            itemBuilder: (BuildContext c) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'json', child: Text('导出为 JSON')),
              PopupMenuItem<String>(value: 'clear', child: Text('清空日志')),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // ---- 概要 ----
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            color: scheme.surfaceContainerHigh,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '$total 条日志 · 应用 ${RunLog.instance.appVersion}'
                  ' · 框架 ${RunLog.instance.frameworkVersion}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (_exportedPath != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    '已生成日志文件，可在分享面板里发送或保存到「下载」。',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                        ),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    '路径：$_exportedPath',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),

          // ---- 级别筛选 ----
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: const Text('全部'),
                    selected: _levelFilter == null,
                    onSelected: (_) => setState(() => _levelFilter = null),
                  ),
                ),
                for (final LogLevel level in LogLevel.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(_levelLabel(level)),
                      selected: _levelFilter == level,
                      onSelected: (bool on) =>
                          setState(() => _levelFilter = on ? level : null),
                    ),
                  ),
                const SizedBox(width: 8),
                // 自动滚到底的开关：看历史日志时要关掉，否则会被拽走
                FilterChip(
                  label: const Text('跟随最新'),
                  selected: _autoScroll,
                  onSelected: (bool on) => setState(() => _autoScroll = on),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ---- 日志正文 ----
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        total == 0
                            ? '还没有日志。\n\n'
                                '正常使用一会儿（打开一个小程序、刷新一下市场）'
                                '再回来看。'
                            : '当前筛选下没有日志。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  )
                : Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: visible.length,
                      itemBuilder: (BuildContext ctx, int i) =>
                          _logRow(context, visible[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _logRow(BuildContext context, LogEntry e) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = switch (e.level) {
      LogLevel.error => scheme.error,
      LogLevel.warn => scheme.tertiary,
      LogLevel.debug => scheme.onSurfaceVariant,
      LogLevel.info => scheme.onSurface,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 时间只留时分秒，毫秒对排障意义不大但很占宽度
          Text(
            '${e.at.hour.toString().padLeft(2, '0')}:'
            '${e.at.minute.toString().padLeft(2, '0')}:'
            '${e.at.second.toString().padLeft(2, '0')}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 12,
            child: Text(
              e.level.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              '[${e.tag}] ${e.message}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  static String _levelLabel(LogLevel level) => switch (level) {
    LogLevel.debug => '调试',
    LogLevel.info => '信息',
    LogLevel.warn => '警告',
    LogLevel.error => '错误',
  };
}

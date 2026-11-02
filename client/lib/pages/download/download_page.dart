// lib/pages/download/download_page.dart
//
// 下载管理页。
//
// 三件事：下载目录（可改子目录）、逐条记录（进度/打开/取消/重试/删除）、
// 以及老系统上的「存储权限」入口。
//
// 为什么目录只有一个「子目录」可改：落盘是系统 DownloadManager 干的，
// 它只允许写到公共目录（Downloads / Documents）下的相对路径 —— 这是
// Android 的硬约束，不是我们的简化。所以这里能选的是「放在 Download/
// 根下」还是「放在 Download/<子目录> 下」，目标根目录固定是系统下载目录。
//
// 页面不自己轮询：进度由 DownloadService 统一查（它跨页面存活），
// 这里只监听它的变化重绘。

import 'package:flutter/material.dart';

import '../../data/services/download_service.dart';
import '../home/widgets/state_views.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (BuildContext context) => const DownloadPage());

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  DownloadService get _service => DownloadService.instance;

  /// 老系统（Android 9 及以下）才需要，null = 还在查
  bool? _needsPermission;

  @override
  void initState() {
    super.initState();
    _checkPermissionNeed();
  }

  Future<void> _checkPermissionNeed() async {
    final bool needed = await _service.needsLegacyPermission;
    if (!mounted) return;
    setState(() => _needsPermission = needed);
  }

  Future<void> _requestPermission() async {
    final bool ok = await _service.ensureLegacyPermission();
    if (!mounted) return;
    _toast(ok ? '存储权限已授予' : '没有拿到存储权限，Android 9 及以下无法写入下载目录');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final DownloadService service = _service;
    return Scaffold(
      appBar: AppBar(title: const Text('下载管理')),
      body: AnimatedBuilder(
        animation: service,
        builder: (BuildContext context, Widget? _) {
          final List<DownloadTask> tasks = service.tasks;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              _directoryCard(context, service),
              if (_needsPermission == true) _permissionTile(context),
              _listHeader(context, service, tasks),
              if (tasks.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 32, 16, 16),
                  child: EmptyView(
                    icon: Icons.download_outlined,
                    title: '还没有下载',
                    message: '在小程序网页里点下载链接，文件会交给系统下载器，保存在下载目录里',
                  ),
                )
              else
                ...tasks.map((DownloadTask task) => _taskTile(context, service, task)),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------- 目录

  Widget _directoryCard(BuildContext context, DownloadService service) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Column(
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('下载目录'),
              subtitle: Text(
                '${service.directoryLabel}\n'
                '目标根目录固定是系统「下载」目录（Download/），子目录可改',
              ),
              isThreeLine: true,
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => _editSubDir(service),
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: const Text('更改子目录'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final bool ok = await service.openDirectory();
                    if (!ok) _toast('这台设备的系统没有「下载」界面');
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('打开下载目录'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editSubDir(DownloadService service) async {
    final TextEditingController controller =
        TextEditingController(text: service.subDir);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('下载子目录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '相对 Download/ 的路径',
                hintText: '留空 = 直接放在 Download/ 根下',
              ),
              onSubmitted: (String value) => Navigator.of(context).pop(value),
            ),
            const SizedBox(height: 12),
            Text(
              '只允许相对路径；`..` 与绝对路径会被丢弃。'
              '修改只影响之后的新下载，已下载的文件不搬家。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await service.setSubDir(result);
    if (!mounted) return;
    _toast('下载目录：${service.directoryLabel}');
  }

  // ------------------------------------------------------------- 权限

  Widget _permissionTile(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        child: ListTile(
          leading: const Icon(Icons.warning_amber_outlined),
          title: const Text('需要「存储」权限'),
          subtitle: const Text(
            '这台设备是 Android 9 或更早：系统下载器往公共下载目录写文件之前，'
            '应用必须先拿到 WRITE_EXTERNAL_STORAGE。',
          ),
          trailing: TextButton(
            onPressed: _requestPermission,
            child: const Text('去申请'),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 列表

  Widget _listHeader(
    BuildContext context,
    DownloadService service,
    List<DownloadTask> tasks,
  ) {
    final int cleanupable = service.cleanupableCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              tasks.isEmpty ? '记录' : '记录（${tasks.length}）',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (cleanupable > 0)
            TextButton(
              onPressed: () async {
                final int removed = await service.clearFinished();
                _toast('已清理 $removed 条记录');
              },
              child: const Text('清理失败记录'),
            ),
        ],
      ),
    );
  }

  Widget _taskTile(BuildContext context, DownloadService service, DownloadTask task) {
    final ThemeData theme = Theme.of(context);
    final bool active = task.status.isActive;
    final String subtitle = <String>[
      task.status.label,
      task.sizeLabel,
      if (task.reason.isNotEmpty) task.reason,
    ].where((String s) => s.isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(_iconFor(task), size: 28, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: 2),
                    Text(
                      task.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: task.status == DownloadStatus.failed
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                    if (active) ...<Widget>[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      '${task.relativePath} · ${task.createdLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _actions(context, service, task),
            ],
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }

  Widget _actions(BuildContext context, DownloadService service, DownloadTask task) {
    if (task.status.isFinished) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: '打开',
            icon: const Icon(Icons.open_in_new),
            onPressed: () async {
              final bool ok = await service.open(task.id);
              if (!ok) _toast('没有能找到打开这个文件的应用');
            },
          ),
          IconButton(
            tooltip: '删除（连同文件）',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(service, task),
          ),
        ],
      );
    }
    if (task.status == DownloadStatus.failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: '重试',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final DownloadTask? again = await service.retry(task.id);
              _toast(again == null ? '重试失败（可能没有存储权限）' : '已重新加入下载队列');
            },
          ),
          IconButton(
            tooltip: '删除记录',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(service, task),
          ),
        ],
      );
    }
    if (task.status == DownloadStatus.canceled) {
      return IconButton(
        tooltip: '删除记录',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(service, task),
      );
    }
    return IconButton(
      tooltip: '取消下载',
      icon: const Icon(Icons.close),
      onPressed: () async {
        final bool ok = await service.cancel(task.id);
        _toast(ok ? '已取消' : '系统里没找到这个任务');
      },
    );
  }

  Future<void> _confirmDelete(DownloadService service, DownloadTask task) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除下载'),
        content: Text(
          '会连文件一起删掉：\n${task.relativePath}\n\n'
          '（行为与系统下载器一致：删任务即删文件）',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await service.delete(task.id);
    if (!mounted) return;
    _toast('已删除');
  }

  IconData _iconFor(DownloadTask task) {
    final String mime = task.mimeType.toLowerCase();
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.contains('zip') || mime.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }
}

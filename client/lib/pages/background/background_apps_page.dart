// lib/pages/background/background_apps_page.dart
//
// 后台应用：宿主里正在运行的小程序（主页右上角按钮 / 小程序悬浮菜单 / 设置都能进）。
//
// 这一页存在的意义：小程序退到「后台运行」后**并没有消失**，它还在进程里跑、
// 还占着内存、还可能在做定时任务。没有这个列表，用户就只能靠重新打开来猜。
//
// 三个动作：
//   切到前台 —— 不重新加载，直接恢复那个 WebView；
//   关闭     —— 真正销毁（释放 WebView 与 JS 堆）；
//   关闭后台项 / 全部关闭 —— 批量回收。
//
// 页面上如实写明「进程内保活」的边界：宿主不做前台 Service，
// 系统内存紧张时仍可能回收整个进程。宁可说清楚，也不要让用户以为这是「永不掉线」。

import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/json_utils.dart';
import '../../data/services/icon_cache_service.dart';
import '../../data/models/miniapp_session.dart';
import '../../theme/app_theme.dart';
import '../miniapp/miniapp_host.dart';

class BackgroundAppsPage extends StatelessWidget {
  const BackgroundAppsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const BackgroundAppsPage(),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('后台应用')),
      body: ListenableBuilder(
        listenable: MiniappHost.instance,
        builder: (BuildContext context, Widget? child) {
          final List<MiniappSession> sessions = MiniappHost.instance.sessions;
          if (sessions.isEmpty) {
            return const _EmptyState();
          }
          return _buildList(context, sessions);
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, List<MiniappSession> sessions) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int background = sessions
        .where((MiniappSession s) => s.isBackground)
        .length;

    // 前台排前面，其余按最近活跃倒序 —— 「我刚从哪个切走的」最可能是想回去的那个
    final List<MiniappSession> ordered = List<MiniappSession>.of(sessions)
      ..sort((MiniappSession a, MiniappSession b) {
        if (a.isForeground != b.isForeground) return a.isForeground ? -1 : 1;
        return b.lastActiveAt.compareTo(a.lastActiveAt);
      });

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.layers_outlined, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '正在运行 ${sessions.length} 个小程序',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  background == 0
                      ? '当前显示在最前面的那个就是唯一在跑的'
                      : '其中 $background 个在后台运行（页面未销毁，可以直接切回）',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    if (background > 0)
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          await MiniappHost.instance.closeBackground();
                          if (context.mounted) {
                            AppTheme.showToast('已关闭后台运行的小程序');
                          }
                        },
                        icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                        label: Text('关闭后台项（$background）'),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => _confirmCloseAll(context, sessions.length),
                      icon: Icon(Icons.close, size: 18, color: scheme.error),
                      label: Text(
                        '全部关闭',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        for (final MiniappSession session in ordered)
          Card.outlined(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: _SessionAvatar(session: session),
              title: Text(session.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: 2),
                  Text(
                    '${session.appId} · ${session.isForeground ? '前台' : '后台'} · '
                    '最近 ${formatDateTimeLabel(session.lastActiveAt)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    session.entry,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              isThreeLine: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (session.isBackground)
                    IconButton(
                      tooltip: '切到前台',
                      icon: const Icon(Icons.open_in_full),
                      onPressed: () =>
                          MiniappHost.instance.foreground(session.appId),
                    ),
                  IconButton(
                    tooltip: '关闭',
                    icon: Icon(Icons.close, color: scheme.error),
                    onPressed: () async {
                      final String title = session.title;
                      await MiniappHost.instance.close(session.appId);
                      if (context.mounted) {
                        AppTheme.showToast('已关闭「$title」');
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Text(
            '「后台运行」是进程内保活：页面不会重新加载，JS 定时器会继续跑，'
            '但它不是前台服务 —— 系统内存紧张时仍可能回收整个进程。'
            '需要长期驻留的能力（下载、播放）应该由小程序自己说明，而不是依赖框架兜底。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmCloseAll(BuildContext context, int count) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('关闭全部小程序？'),
        content: Text('将销毁 $count 个正在运行的小程序页面，未保存的页面状态会丢失。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('全部关闭'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await MiniappHost.instance.closeAll();
    if (context.mounted) AppTheme.showToast('已关闭全部小程序');
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.layers_clear_outlined, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('没有正在运行的小程序', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '小程序现在以独立窗口打开：它会出现在系统的「最近任务」里，'
              '从那里切回去就行，不占用宿主会话。\n\n'
              '这里只列宿主内嵌运行的会话（开发者选项里的本地包调试、自检等）。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 会话图标。
///
/// 语义与系统「最近任务」里的那张卡片一致：有图标就显示小程序自己的图标，
/// 没有才退回「前台 / 后台」的圆形指示 —— 一排顿号式的圆形按钮看不出
/// 是哪个应用，而这里本来就是让用户找「刚才那个小程序」的地方。
///
/// 图标路径是异步读的（[IconCacheService.pathOf] 读磁盘），但只在 initState
/// 里取一次：FutureBuilder 里现算 future 会在每次 rebuild 时重新发一次 IO。
class _SessionAvatar extends StatefulWidget {
  const _SessionAvatar({required this.session});

  final MiniappSession session;

  @override
  State<_SessionAvatar> createState() => _SessionAvatarState();
}

class _SessionAvatarState extends State<_SessionAvatar> {
  late final Future<String?> _iconPath = IconCacheService.instance.pathOf(
    widget.session.appId,
  );

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FutureBuilder<String?>(
      future: _iconPath,
      builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
        final String? path = snapshot.data;
        final Widget fallback = _badge(scheme);
        if (path == null) return fallback;
        // 文件可能已经被清掉（清理缓存 / 移除应用）：Image.file 的
        // errorBuilder 负责退回圆形指示，不留一个报错方块。
        return SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(path),
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                      _badge(scheme),
                ),
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: _dot(scheme),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 没有图标时的占位：沿用原来的「前台播放 / 后台暂停」语义
  Widget _badge(ColorScheme scheme) => CircleAvatar(
    radius: 20,
    backgroundColor: widget.session.isForeground
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest,
    child: Icon(
      widget.session.isForeground ? Icons.play_arrow : Icons.pause_outlined,
      color: widget.session.isForeground
          ? scheme.onPrimaryContainer
          : scheme.onSurfaceVariant,
      size: 20,
    ),
  );

  /// 图标右下角的小圆点：前台=主色实心，后台=描边色空心。
  /// 有图标之后就没法靠底色区分前后台了，这个点补上那层信息。
  Widget _dot(ColorScheme scheme) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: widget.session.isForeground ? scheme.primary : scheme.surface,
      shape: BoxShape.circle,
      border: Border.all(color: scheme.surface, width: 2),
    ),
  );
}

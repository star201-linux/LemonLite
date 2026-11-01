// lib/pages/applications/applications_page.dart
//
// 「应用管理」—— 底部导航的第二个入口，管理设备上出现过的全部应用。
//
// 为什么需要单独一页：
//   在这之前，「哪个小程序存在」这件事散在三处：权限管理器的注册表、
//   存储页的占用统计、以及两个 appfiles 目录。每一处都只能看到一部分，
//   于是「存储页里有个应用、权限管理器里没有」这种不一致迟早会出现。
//   应用管理把清单统一成一份，其余页面都从它派生。
//
// 这一页负责：
//   * 列出全部应用（名字 / 图标 / 占用 / 最近打开）
//   * 进入单个应用看它的权限与数据
//   * 移除应用（可选同时清除数据）
//
// 它与权限管理器的关系（需求里明确要求的联动）：
//   权限管理器的应用清单**跟随这里**。在这一页移除一个应用，
//   权限管理器里就不再出现它，它的权限记录也会一并清掉 ——
//   由 ApplicationRegistry.remove 负责，两个页面看到的是同一份真相。

import 'package:flutter/material.dart';

import '../../core/globals.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/services/application_registry.dart';
import '../../data/services/miniapp_storage_service.dart';
import '../../data/services/permission_service.dart';
import '../home/widgets/app_icon.dart';
import 'app_manage_detail_page.dart';

class ApplicationsPage extends StatefulWidget {
  const ApplicationsPage({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (BuildContext context) => const ApplicationsPage());

  @override
  State<ApplicationsPage> createState() => _ApplicationsPageState();
}

/// 一页要展示的东西：应用清单 + 每个应用的占用
class _ApplicationsSnapshot {
  const _ApplicationsSnapshot({required this.apps, required this.usage});

  final List<RegisteredApp> apps;

  /// appId → 占用
  final Map<String, MiniappStorageUsage> usage;

  int get totalBytes =>
      usage.values.fold<int>(0, (int sum, MiniappStorageUsage u) => sum + u.totalBytes);
}

class _ApplicationsPageState extends State<ApplicationsPage> {
  late Future<_ApplicationsSnapshot> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ApplicationsSnapshot> _load() async {
    final ApplicationRegistry registry = ApplicationRegistry.instance;

    // 目录扫描发现的孤儿 appId 先补进清单：用户手工放进 appfiles 的东西
    // 也占着磁盘，就该在这里看得见、清得掉。
    try {
      final List<String> orphans =
          await MiniappStorageService.instance.allFilesAppIds();
      await registry.adoptOrphans(orphans);
    } catch (e) {
      // 存储不可用不该让应用管理打不开
      lemonLog('Applications', '补充孤儿应用失败：$e');
    }

    final List<RegisteredApp> apps = registry.all;

    final Map<String, String> nameHints = <String, String>{};
    final Map<String, DateTime?> lastOpened = <String, DateTime?>{};
    for (final RegisteredApp app in apps) {
      nameHints[app.id] = app.displayName;
      lastOpened[app.id] = app.lastOpenedAt;
    }

    final List<MiniappStorageUsage> usages =
        await MiniappStorageService.instance.scanAll(
      nameHints: nameHints,
      lastOpened: lastOpened,
    );

    return _ApplicationsSnapshot(
      apps: apps,
      usage: <String, MiniappStorageUsage>{
        for (final MiniappStorageUsage u in usages) u.appId: u,
      },
    );
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用管理'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: FutureBuilder<_ApplicationsSnapshot>(
        future: _future,
        builder: (
          BuildContext context,
          AsyncSnapshot<_ApplicationsSnapshot> snapshot,
        ) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _ErrorBody(message: '${snapshot.error}', onRetry: _reload);
          }
          final _ApplicationsSnapshot data = snapshot.data!;
          if (data.apps.isEmpty) {
            return const _EmptyBody();
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              _SummaryCard(snapshot: data),
              for (final RegisteredApp app in data.apps)
                _ApplicationTile(
                  app: app,
                  usage: data.usage[app.id],
                  onChanged: _reload,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  '这里列出的是设备上出现过的全部应用。权限管理器里的应用清单跟随这一页 —— '
                  '在这里移除一个应用，它的权限记录也会一并清掉。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 顶部概览：应用数 / 总占用 / 权限概览
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.snapshot});

  final _ApplicationsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final PermissionService permissions = PermissionService.instance;

    int granted = 0;
    int denied = 0;
    for (final RegisteredApp app in snapshot.apps) {
      for (final MiniappPermission p in MiniappPermission.values) {
        final PermissionDecision d = permissions.decisionOf(app.id, p);
        if (d == PermissionDecision.granted) granted++;
        if (d == PermissionDecision.denied) denied++;
      }
    }

    return Padding(
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
                Icon(Icons.apps, color: scheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '共 ${snapshot.apps.length} 个应用',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '占用合计 ${formatBytes(snapshot.totalBytes)} · '
              '权限：已允许 $granted 项、已拒绝 $denied 项',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表里的一行应用
class _ApplicationTile extends StatelessWidget {
  const _ApplicationTile({
    required this.app,
    required this.usage,
    required this.onChanged,
  });

  final RegisteredApp app;
  final MiniappStorageUsage? usage;

  /// 从详情页返回后让父级刷新
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final PermissionService permissions = PermissionService.instance;
    final int granted = MiniappPermission.values
        .where(
          (MiniappPermission p) =>
              permissions.decisionOf(app.id, p) == PermissionDecision.granted,
        )
        .length;
    final int denied = MiniappPermission.values
        .where(
          (MiniappPermission p) =>
              permissions.decisionOf(app.id, p) == PermissionDecision.denied,
        )
        .length;

    final List<String> parts = <String>[app.id];
    if (usage != null) parts.add(usage!.summaryLabel);
    if (granted > 0) parts.add('已允许 $granted 项权限');
    if (denied > 0) parts.add('已拒绝 $denied 项');
    if (app.lastOpenedAt != null) {
      parts.add('最近 ${formatDateTimeLabel(app.lastOpenedAt)}');
    }

    return ListTile(
      leading: AppIcon(name: app.displayName, iconUrl: app.icon, size: 44),
      title: Text(app.displayName),
      subtitle: Text(
        parts.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context).push(
          AppManageDetailPage.route(appId: app.id, appName: app.displayName),
        );
        onChanged();
      },
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.apps_outlined, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('还没有任何应用', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '从主页打开一个小程序，它就会出现在这里，之后可以单独管理它的权限与数据。',
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

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 16),
            Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

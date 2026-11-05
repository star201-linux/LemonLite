// lib/pages/applications/applications_page.dart
//
// 「应用管理」—— 底部导航的第二个入口，管理设备上出现过的全部应用。
//
// 这一页的职责：
//   * 列出全部已装应用（图标 / 名字 / 占用 / 最近打开 / 是否可更新）
//   * 点某一个 → 进**应用详情页**（与主页点卡片看到的是同一页）；
//     权限、数据、移除这些管理动作收在详情页右上角的扳手里。
//   * 有更新时显示小红点（列表项 + 底部导航的「应用管理」）
//
// 为什么点进去改成详情页而不是权限页：
//   用户从「应用管理」进一个应用，最常想确认的是「我装的是哪一版、怎么打开」，
//   权限开关是低频动作。详情页 + 扳手把两件事分开，主页与应用管理也能共用一套页面。
//
// 图标的来源：
//   已安装小程序的图标会在安装 / 打开时缓存到本机（见 IconCacheService），
//   这一页优先读本地文件 —— 断网时也能显示，不用每次进页面都拉一遍网络图。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/globals.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/repositories/market_repository.dart';
import '../../data/services/application_registry.dart';
import '../../data/services/icon_cache_service.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/miniapp_storage_service.dart';
import '../../data/services/permission_service.dart';
import '../../data/services/update_service.dart';
import '../detail/app_detail_page.dart';
import '../home/widgets/app_icon.dart';

class ApplicationsPage extends StatefulWidget {
  const ApplicationsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const ApplicationsPage(),
  );

  @override
  State<ApplicationsPage> createState() => _ApplicationsPageState();
}

/// 一页要展示的东西：应用清单 + 每个应用的占用 + 本地图标
class _ApplicationsSnapshot {
  const _ApplicationsSnapshot({
    required this.apps,
    required this.usage,
    required this.icons,
  });

  final List<RegisteredApp> apps;

  /// appId → 占用
  final Map<String, MiniappStorageUsage> usage;

  /// appId → 本地图标路径（没缓存到就是 null）
  final Map<String, String?> icons;

  int get totalBytes => usage.values.fold<int>(
    0,
    (int sum, MiniappStorageUsage u) => sum + u.totalBytes,
  );
}

class _ApplicationsPageState extends State<ApplicationsPage> {
  late Future<_ApplicationsSnapshot> _future;

  /// 正在刷新（底部导航的小红点会随更新检查变化，手动刷新要能重查一次）
  bool _refreshing = false;

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
      final List<String> orphans = await MiniappStorageService.instance
          .allFilesAppIds();
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

    final List<MiniappStorageUsage> usages = await MiniappStorageService
        .instance
        .scanAll(nameHints: nameHints, lastOpened: lastOpened);

    // 图标：本地有就复用，没有就顺手下载一次（失败静默，界面退回首字占位图）
    final Map<String, String?> icons = await IconCacheService.instance
        .ensureAll(<String, String?>{
          for (final RegisteredApp app in apps) app.id: app.icon,
        });

    return _ApplicationsSnapshot(
      apps: apps,
      usage: <String, MiniappStorageUsage>{
        for (final MiniappStorageUsage u in usages) u.appId: u,
      },
      icons: icons,
    );
  }

  /// 刷新：顺带向服务端重查一次更新（不只重读磁盘）
  Future<void> _refresh() async {
    if (_refreshing) return;
    final MarketRepository repository = context.read<MarketRepository>();
    setState(() => _refreshing = true);
    await UpdateService.instance.checkAll(repository: repository, force: true);
    if (!mounted) return;
    final Future<_ApplicationsSnapshot> next = _load();
    setState(() {
      _future = next;
      _refreshing = false;
    });
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用管理'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新（含检查更新）',
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
      ),
      // 更新状态是全局单例：启动检查 / 打开某个小程序时的单查都会通知到这里
      body: ListenableBuilder(
        listenable: UpdateService.instance,
        builder: (BuildContext context, Widget? child) {
          return FutureBuilder<_ApplicationsSnapshot>(
            future: _future,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<_ApplicationsSnapshot> snapshot,
                ) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _ErrorBody(
                      message: '${snapshot.error}',
                      onRetry: _reload,
                    );
                  }
                  final _ApplicationsSnapshot data = snapshot.data!;
                  if (data.apps.isEmpty) {
                    return const _EmptyBody();
                  }
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: <Widget>[
                      _SummaryCard(
                        snapshot: data,
                        updateCount: UpdateService.instance.count,
                      ),
                      for (final RegisteredApp app in data.apps)
                        _ApplicationTile(
                          app: app,
                          usage: data.usage[app.id],
                          localIcon: data.icons[app.id],
                          update: UpdateService.instance.of(app.id),
                          onChanged: _reload,
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: Text(
                          '这里列出的是设备上出现过的全部应用。点进去是详情页；'
                          '详情页右上角的扳手里可以管理它的权限、数据，或移除它。'
                          '有小红点表示服务端发布了新版本。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  );
                },
          );
        },
      ),
    );
  }
}

/// 顶部概览：应用数 / 总占用 / 权限概览 / 可更新数
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.snapshot, this.updateCount = 0});

  final _ApplicationsSnapshot snapshot;
  final int updateCount;

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
                if (updateCount > 0)
                  Badge(
                    label: Text('$updateCount'),
                    child: Icon(
                      Icons.system_update_alt,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '占用合计 ${formatBytes(snapshot.totalBytes)} · '
              '权限：已允许 $granted 项、已拒绝 $denied 项'
              '${updateCount > 0 ? ' · $updateCount 个可更新' : ''}',
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
    required this.localIcon,
    required this.update,
    required this.onChanged,
  });

  final RegisteredApp app;
  final MiniappStorageUsage? usage;
  final String? localIcon;
  final PackageUpdate? update;

  /// 从详情页返回后让父级刷新
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
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
    if (update != null) parts.add('有新版本 ${update!.latestVersion}');
    if (usage != null) parts.add(usage!.summaryLabel);
    if (granted > 0) parts.add('已允许 $granted 项权限');
    if (denied > 0) parts.add('已拒绝 $denied 项');
    if (app.lastOpenedAt != null) {
      parts.add('最近 ${formatDateTimeLabel(app.lastOpenedAt)}');
    }

    return ListTile(
      // 小红点挂在图标右上角：一眼能看出「这一行有更新」
      leading: Badge(
        isLabelVisible: update != null,
        smallSize: 10,
        child: AppIcon(
          name: app.displayName,
          iconUrl: app.icon,
          localPath: localIcon,
          size: 44,
        ),
      ),
      title: Text(app.displayName),
      subtitle: Text(
        parts.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (update != null)
            Text(
              '可更新',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.error),
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () async {
        await Navigator.of(context).push(
          AppDetailPage.routeForRegisteredApp(
            appId: app.id,
            name: app.displayName,
            icon: app.icon,
          ),
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
            Text('还没有安装任何小程序', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '在主页打开一个小程序后，它会出现在这里，之后可以单独管理它的权限与数据。\n'
              '默认市场是空的，小程序由管理员在服务端添加。',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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

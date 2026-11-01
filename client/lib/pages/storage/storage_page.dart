// lib/pages/storage/storage_page.dart
//
// 设置 → 存储：占用统计与「单 App 数据管理」。
//
// 两类数据都要能看到、能单独清：
//   1. 键值存储（SharedPreferences）：`miniapp.storage.<appId>.<key>`
//   2. 共享目录：`Android/data/<包名>/files/appfiles/<appId>/`
//   3. 私有目录：`data/data/<包名>/files/appfiles/<appId>/`
//
// 为什么按 App 分而不是给一个「清空全部」了事：
//   小程序之间共享同一个宿主进程与同一个存储后端，如果没有按 App 的视图，
//   用户遇到「某个小程序出问题了想重置它」时唯一的手段就是把所有小程序的数据
//   一起删掉 —— 那是不可接受的代价。所以这里的最小操作粒度是**单个键**。
//
// 两个文件目录（共享 / 私有）分开统计、分开清：它们的可见性完全不同，
// 混成一个数字会让人不知道删掉的到底是「用户能拷走的那份」还是「只有宿主能读的那份」。
//
// 「清除数据」不会重置权限授权：授权是用户对该应用的信任决定，
// 清数据是数据面的事，两者混在一起会让「清完数据还得重新授权」变得莫名其妙。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../../core/globals.dart';
import '../../data/models/json_utils.dart';
import '../../data/services/application_registry.dart';
import '../../data/services/miniapp_storage_service.dart';
import '../../theme/app_theme.dart';
import '../home/home_controller.dart';

class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (BuildContext context) => const StoragePage());

  @override
  State<StoragePage> createState() => _StoragePageState();
}

/// 页面一次加载出来的快照
class _StorageSnapshot {
  const _StorageSnapshot({
    required this.usages,
    required this.rootPath,
    this.privateRootPath = '',
  });

  final List<MiniappStorageUsage> usages;

  /// 共享目录根（Android/data/<包名>/files/appfiles）
  final String rootPath;

  /// 私有目录根（data/data/<包名>/files/appfiles）
  final String privateRootPath;

  int get totalBytes =>
      usages.fold<int>(0, (int sum, MiniappStorageUsage u) => sum + u.totalBytes);

  int get storageBytes => usages.fold<int>(
    0,
    (int sum, MiniappStorageUsage u) => sum + u.storageBytes,
  );

  int get fileBytes =>
      usages.fold<int>(0, (int sum, MiniappStorageUsage u) => sum + u.fileBytes);

  int get privateBytes => usages.fold<int>(
    0,
    (int sum, MiniappStorageUsage u) => sum + u.privateBytes,
  );
}

class _StoragePageState extends State<StoragePage> {
  late Future<_StorageSnapshot> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_StorageSnapshot> _load() async {
    final Map<String, String> nameHints = <String, String>{};
    final Map<String, DateTime?> lastOpened = <String, DateTime?>{};

    // 市场里的名字最好看，优先用它
    try {
      final HomeController home = context.read<HomeController>();
      for (final app in home.apps) {
        nameHints.putIfAbsent(app.id, () => app.name);
      }
    } catch (_) {
      // 没有 Provider（测试场景）就退化成用注册表里的名字
    }
    // 应用清单跟随「应用管理」：两处看到的应用必须一致
    for (final RegisteredApp app in ApplicationRegistry.instance.all) {
      nameHints.putIfAbsent(app.id, () => app.displayName);
      lastOpened[app.id] = app.lastOpenedAt;
    }

    final MiniappStorageService service = MiniappStorageService.instance;
    final List<MiniappStorageUsage> usages = await service.scanAll(
      nameHints: nameHints,
      lastOpened: lastOpened,
    );
    String rootPath = '';
    String privatePath = '';
    try {
      rootPath = (await service.appFilesRoot()).path;
      privatePath = (await service.appPrivateRoot()).path;
    } catch (_) {
      rootPath = '（不可用）';
    }
    return _StorageSnapshot(
      usages: usages,
      rootPath: rootPath,
      privateRootPath: privatePath,
    );
  }

  Future<void> _reload() async {
    final Future<_StorageSnapshot> next = _load();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('存储')),
      body: FutureBuilder<_StorageSnapshot>(
        future: _future,
        builder:
            (BuildContext context, AsyncSnapshot<_StorageSnapshot> snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.sd_card_alert_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(height: 16),
                        Text('统计失败：${snapshot.error}'),
                        const SizedBox(height: 16),
                        FilledButton.tonalIcon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return _buildBody(context, snapshot.data!);
            },
      ),
    );
  }

  Widget _buildBody(BuildContext context, _StorageSnapshot data) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          _summaryCard(context, data),

          if (data.usages.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Column(
                children: <Widget>[
                  Icon(
                    Icons.inbox_outlined,
                    size: 48,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '还没有应用产生数据',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '应用写入 storage 或文件后，这里会按 App 显示占用。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '单个应用的数据',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                ),
              ),
            ),
            for (final MiniappStorageUsage usage in data.usages)
              Card.outlined(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: const Icon(Icons.widgets_outlined),
                  title: Text(usage.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        usage.appId,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(usage.summaryLabel),
                    ],
                  ),
                  isThreeLine: true,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        usage.totalLabel,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext ctx) => MiniappDataPage(
                          appId: usage.appId,
                          appName: usage.name,
                        ),
                      ),
                    );
                    if (mounted) await _reload();
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: OutlinedButton.icon(
                onPressed: () => _confirmClearAll(data),
                icon: Icon(Icons.delete_sweep_outlined, color: scheme.error),
                label: Text(
                  '清理全部应用数据',
                  style: TextStyle(color: scheme.error),
                ),
              ),
            ),
          ],

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              '共享目录：${data.rootPath}/<应用 id>'
              '（即 Android/data/${AppInfo.packageName}/files/appfiles/<应用 id>）\n'
              '私有目录：${data.privateRootPath}/<应用 id>'
              '（即 data/data/${AppInfo.packageName}/files/appfiles/<应用 id>）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context, _StorageSnapshot data) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
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
                Icon(Icons.pie_chart_outline, color: scheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '应用共占用 ${formatBytes(data.totalBytes)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '键值 ${formatBytes(data.storageBytes)} · '
              '共享 ${formatBytes(data.fileBytes)} · '
              '私有 ${formatBytes(data.privateBytes)} · '
              '${data.usages.length} 个应用',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearAll(_StorageSnapshot data) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('清理全部应用数据？'),
        content: Text(
          '将删除 ${data.usages.length} 个应用的键值存储与两个文件目录'
          '（共 ${formatBytes(data.totalBytes)}）。'
          '权限授权不会被重置。此操作不可撤销。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final MiniappStorageService service = MiniappStorageService.instance;
    for (final MiniappStorageUsage usage in data.usages) {
      await service.clearAllData(usage.appId);
    }
    if (!mounted) return;
    AppTheme.showToast('已清理全部应用数据');
    await _reload();
  }
}

/// 单个应用的数据详情：键值逐条可删，两个文件目录可分别清空。
class MiniappDataPage extends StatefulWidget {
  const MiniappDataPage({super.key, required this.appId, required this.appName});

  final String appId;
  final String appName;

  static Route<void> route({required String appId, required String appName}) =>
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            MiniappDataPage(appId: appId, appName: appName),
      );

  @override
  State<MiniappDataPage> createState() => _MiniappDataPageState();
}

class _MiniappDataPageState extends State<MiniappDataPage> {
  late Future<MiniappStorageUsage> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<MiniappStorageUsage> _load() =>
      MiniappStorageService.instance.usageOf(widget.appId, name: widget.appName);

  Future<void> _reload() async {
    final Future<MiniappStorageUsage> next = _load();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.appName)),
      body: FutureBuilder<MiniappStorageUsage>(
        future: _future,
        builder:
            (BuildContext context, AsyncSnapshot<MiniappStorageUsage> snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('读取失败：${snapshot.error}'));
              }
              return _buildBody(context, snapshot.data!);
            },
      ),
    );
  }

  Widget _buildBody(BuildContext context, MiniappStorageUsage usage) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<MiniappStorageEntry> entries =
        MiniappStorageService.instance.storageEntries(widget.appId);

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        // ---------------- 概览 ----------------
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SelectableText(
                    widget.appId,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _Metric(
                          label: '键值',
                          value: formatBytes(usage.storageBytes),
                          hint: '${entries.length} 项',
                        ),
                      ),
                      Expanded(
                        child: _Metric(
                          label: '共享',
                          value: formatBytes(usage.fileBytes),
                          hint: '${usage.fileCount} 个',
                        ),
                      ),
                      Expanded(
                        child: _Metric(
                          label: '私有',
                          value: formatBytes(usage.privateBytes),
                          hint: '${usage.privateCount} 个',
                        ),
                      ),
                      Expanded(
                        child: _Metric(
                          label: '合计',
                          value: formatBytes(usage.totalBytes),
                          hint: '占用',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        // ---------------- 文件目录（两个作用域） ----------------
        // 共享目录在 Android/data 下，用户能在文件管理器里看到；
        // 私有目录在 data/data 下，只有宿主读得到。分开列出、分开清，
        // 是因为它们的可见性与用途完全不同，混在一起会让人不知道删掉了什么。
        for (final FileScope scope in FileScope.values)
          _section(
            context,
            '${scope.label}（${formatBytes(usage.bytesOf(scope))}）',
            <Widget>[
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(scope.label),
                subtitle: SelectableText(
                  usage.pathOf(scope).isEmpty
                      ? '（不可用）'
                      : usage.pathOf(scope),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  tooltip: '复制路径',
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: usage.pathOf(scope).isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: usage.pathOf(scope)),
                          );
                          if (context.mounted) AppTheme.showToast('已复制路径');
                        },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '${scope.description} 共 ${usage.countOf(scope)} 个文件。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(Icons.folder_delete_outlined, color: scheme.error),
                title: Text(
                  '清空${scope.label}',
                  style: TextStyle(color: scheme.error),
                ),
                subtitle: Text('删除 appfiles/${widget.appId}/ 下的全部文件'),
                onTap: usage.countOf(scope) == 0
                    ? null
                    : () async {
                        await MiniappStorageService.instance.clearFiles(
                          widget.appId,
                          scope: scope,
                        );
                        if (!context.mounted) return;
                        AppTheme.showToast('已清空${scope.label}');
                        await _reload();
                      },
              ),
            ],
          ),

        // ---------------- 键值存储 ----------------
        _section(context, '键值存储（${entries.length} 项）', <Widget>[
          if (entries.isEmpty)
            const ListTile(
              leading: Icon(Icons.inbox_outlined),
              title: Text('没有键值数据'),
              subtitle: Text('应用调用 setStorage 后会出现在这里'),
            )
          else ...<Widget>[
            for (final MiniappStorageEntry entry in entries)
              ListTile(
                dense: true,
                leading: const Icon(Icons.key_outlined, size: 20),
                title: Text(entry.key),
                subtitle: Text(formatBytes(entry.bytes)),
                trailing: IconButton(
                  tooltip: '删除这个键',
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  onPressed: () async {
                    await MiniappStorageService.instance.removeStorageEntry(
                      entry.rawKey,
                    );
                    if (!context.mounted) return;
                    AppTheme.showToast('已删除 ${entry.key}');
                    await _reload();
                  },
                ),
              ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: Icon(Icons.backspace_outlined, color: scheme.error),
              title: Text('清空键值存储', style: TextStyle(color: scheme.error)),
              onTap: () async {
                await MiniappStorageService.instance.clearStorage(widget.appId);
                if (!context.mounted) return;
                AppTheme.showToast('已清空键值存储');
                await _reload();
              },
            ),
          ],
        ]),

        // ---------------- 危险操作 ----------------
        _section(context, '危险操作', <Widget>[
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: Text('清除全部数据', style: TextStyle(color: scheme.error)),
            subtitle: const Text('键值 + 共享目录 + 私有目录 + 权限申请记录（不动授权设置）'),
            onTap: () => _clearAll(usage),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: Icon(Icons.person_remove_outlined, color: scheme.error),
            title: Text('移除这个应用', style: TextStyle(color: scheme.error)),
            subtitle: const Text('从应用清单移除，权限管理与存储列表里不再显示'),
            onTap: _forget,
          ),
        ]),
      ],
    );
  }

  Future<void> _clearAll(MiniappStorageUsage usage) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('清除全部数据？'),
        content: Text(
          '将删除「${usage.name}」的键值存储（${formatBytes(usage.storageBytes)}）、'
          '共享目录（${formatBytes(usage.fileBytes)}）与私有目录'
          '（${formatBytes(usage.privateBytes)}），以及权限申请记录。'
          '它的权限授权设置会保留。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await MiniappStorageService.instance.clearAllData(widget.appId);
    if (!mounted) return;
    AppTheme.showToast('已清除「${usage.name}」的数据');
    await _reload();
  }

  /// 移除应用。
  ///
  /// 与「应用管理 → 移除应用」是同一件事（都走 ApplicationRegistry.remove），
  /// 所以两处的结果必然一致：应用从清单消失，权限记录一并清掉，
  /// 权限管理器里也就不会再看到它。
  Future<void> _forget() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('移除这个应用？'),
        content: const Text(
          '会先清除它的数据，再从应用清单移除，权限记录一并清掉。'
          '下次打开它时会重新出现。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await MiniappStorageService.instance.clearAllData(widget.appId);
    await ApplicationRegistry.instance.remove(widget.appId);
    if (!mounted) return;
    AppTheme.showToast('已移除「${widget.appName}」');
    Navigator.of(context).pop();
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.hint});

  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
        Text(
          hint,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

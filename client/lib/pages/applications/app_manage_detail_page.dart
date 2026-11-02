// lib/pages/applications/app_manage_detail_page.dart
//
// 「应用管理」里单个应用的详情页：权限 + 数据。
//
// 权限那一块是**嵌入**的：直接把 PermissionControllerPage 的单应用视图
// 复用过来（而不是再写一份权限开关）。这样「应用管理 → 某个应用 → 权限」
// 与「权限管理器 → 某个应用」看到的是同一个界面、同一套语义 ——
// 两处各写一份必然会出现某一边漏了新状态。
//
// 数据那一块复用 MiniappDataPage（存储页的单应用视图），同理。

import 'package:flutter/material.dart';

import '../../data/services/application_registry.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/miniapp_storage_service.dart';
import '../../theme/app_theme.dart';
import '../home/widgets/app_icon.dart';
import '../miniapp/miniapp_host.dart';
import '../permissions/permission_controller_page.dart';
import '../storage/storage_page.dart';

class AppManageDetailPage extends StatefulWidget {
  const AppManageDetailPage({
    super.key,
    required this.appId,
    required this.appName,
  });

  final String appId;
  final String appName;

  static Route<void> route({required String appId, required String appName}) =>
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            AppManageDetailPage(appId: appId, appName: appName),
      );

  @override
  State<AppManageDetailPage> createState() => _AppManageDetailPageState();
}

class _AppManageDetailPageState extends State<AppManageDetailPage> {
  late Future<MiniappStorageUsage> _usageFuture;

  @override
  void initState() {
    super.initState();
    _usageFuture = MiniappStorageService.instance.usageOf(
      widget.appId,
      name: widget.appName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final RegisteredApp? app = ApplicationRegistry.instance.byId(widget.appId);
    final String name = app?.displayName ?? widget.appName;

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          _header(context, app, name),
          _section(context, '权限', <Widget>[
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('权限管理'),
              subtitle: const Text('摄像头、麦克风、手机存储'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                PermissionControllerPage.route(
                  appId: widget.appId,
                  appName: name,
                ),
              ),
            ),
          ]),
          _section(context, '数据', <Widget>[
            ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: const Text('数据与存储'),
              subtitle: const Text('键值、共享目录与私有目录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                  MiniappDataPage.route(appId: widget.appId, appName: name),
                );
                // 在数据页里清过东西，回来后占用必须重新算一次，
                // 否则头部会一直显示进去之前的数字
                if (!mounted) return;
                setState(() {
                  _usageFuture = MiniappStorageService.instance.usageOf(
                    widget.appId,
                    name: widget.appName,
                  );
                });
              },
            ),
          ]),
          _section(context, '移除', <Widget>[
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                '移除应用',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              subtitle: const Text('从应用清单与权限管理里移除；数据可选一并清除'),
              onTap: _confirmRemove,
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              '移除只影响本机的应用清单与权限记录。小程序本身是远程页面，'
              '下次从主页再次打开时它会重新出现在这里。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, RegisteredApp? app, String name) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: <Widget>[
          AppIcon(name: name, iconUrl: app?.icon, size: 64),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                SelectableText(
                  widget.appId,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                FutureBuilder<MiniappStorageUsage>(
                  future: _usageFuture,
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<MiniappStorageUsage> snapshot,
                  ) {
                    final MiniappStorageUsage? usage = snapshot.data;
                    return Text(
                      usage == null
                          ? '统计中…'
                          : '占用 ${usage.totalLabel} · ${usage.summaryLabel}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove() async {
    bool clearData = false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setInner) => AlertDialog(
          title: const Text('移除这个应用？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '它会从应用清单与权限管理器里消失，权限记录一并清掉，'
                '**下载到本机的小程序文件也会被删除**（下次点「打开」会重新下载）。',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: clearData,
                onChanged: (bool? value) =>
                    setInner(() => clearData = value ?? false),
                title: const Text('同时清除它的数据'),
                subtitle: const Text('键值存储与两个文件目录都会被删掉，不可恢复'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              child: const Text('移除'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    // 顺序很重要：
    //   1. 先把这个小程序的后台会话关掉 —— 它的 WebView 已经加载了
    //      file:// 的页面，文件被删掉后再继续跑只会得到一堆「资源丢失」。
    //   2. 再删包目录（这才是「移除」应有的含义：不占空间了）。
    //   3. 数据是可选项（用户可能只是不想留文件，但想保留记录）。
    await MiniappHost.instance.close(widget.appId);
    await MiniappPackageService.instance.remove(widget.appId);
    if (clearData) {
      await MiniappStorageService.instance.clearAllData(widget.appId);
    }
    await ApplicationRegistry.instance.remove(widget.appId);
    if (!mounted) return;
    AppTheme.showToast('已移除「${widget.appName}」，本机文件已删除');
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

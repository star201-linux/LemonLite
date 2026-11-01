// lib/pages/permissions/permission_controller_page.dart
//
// 权限管理器（设置 → 权限管理，也从小程序悬浮菜单、应用管理进入）。
//
// 两种进入方式共用一个页面：
//   * 不传 appId：全局视图 —— 先给「权限使用情况」（哪些权限被哪些应用申请过），
//     再给应用列表，点进去逐项决定；
//   * 传 appId：单应用视图 —— 直接就是这个应用的权限决定。
//
// **应用清单跟随「应用管理」**：这里的应用来自 ApplicationRegistry，
// 与应用管理页是同一份真相。在应用管理里移除一个应用，这里就不再出现它。
//
// 每个权限是**三态**：询问 / 允许 / 拒绝（PermissionDecision）。
// 之所以不用开关：开关只有两态，表达不了"还没问过"，而"还没问过"恰恰是
// 默认状态 —— 用开关会把它误显示成"已拒绝"或"已允许"，两种都是撒谎。
//
// 关于「仅本次生效」：弹窗里那个复选框默认选中，此时的选择**不落盘**，
// 所以这里显示的仍然是「询问」。这不是 bug —— 它如实反映了
// 「这个权限还没有一个长期决定」。用户在弹窗里取消勾选后，这里才会变成允许/拒绝。
//
// 页面里所有状态都来自 PermissionService.scan() 的**快照**：
// 每次改动都重新扫一遍。这样界面上显示的授权与真实生效的授权不可能不一致。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/native_bridge.dart';
import '../../data/models/json_utils.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/services/miniapp_storage_service.dart';
import '../../data/services/permission_service.dart';
import '../../theme/app_theme.dart';
import '../home/home_controller.dart';
import 'widgets/permission_chips.dart';

class PermissionControllerPage extends StatefulWidget {
  const PermissionControllerPage({super.key, this.appId, this.appName});

  /// 传了就进入「单个应用」视图
  final String? appId;

  /// 单应用视图的展示名（从悬浮菜单进来时能拿到，省得等扫描）
  final String? appName;

  static Route<void> route({String? appId, String? appName}) =>
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            PermissionControllerPage(appId: appId, appName: appName),
      );

  @override
  State<PermissionControllerPage> createState() =>
      _PermissionControllerPageState();
}

class _PermissionControllerPageState extends State<PermissionControllerPage> {
  late Future<PermissionScanReport> _future;

  bool get _scoped => widget.appId != null && widget.appId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _future = _scan();
  }

  /// 扫一遍。
  ///
  /// appId 来源：应用管理（主来源，PermissionService.scan 内部会取）、
  /// 宿主注册表、storage 里出现过的 id，以及这里补上的两个文件目录名 ——
  /// 只放了文件、没写过键值的小程序也在其中。
  Future<PermissionScanReport> _scan() async {
    List<String> extraIds = const <String>[];
    try {
      extraIds = await MiniappStorageService.instance.allFilesAppIds();
    } catch (e) {
      // 外部存储不可用不该让权限页面打不开
      extraIds = const <String>[];
    }

    final Map<String, String> nameHints = <String, String>{};
    final HomeController? home = _homeOrNull();
    if (home != null) {
      // 只取「已加载」的那些：服务端分页时客户端的列表是不完整的，
      // 但这不影响权限页 —— 名字只是展示用，取不到就退化成 appId。
      for (final app in home.apps) {
        nameHints[app.id] = app.name;
      }
    }
    return PermissionService.instance.scan(
      nameHints: nameHints,
      extraIds: extraIds,
    );
  }

  HomeController? _homeOrNull() {
    try {
      return context.read<HomeController>();
    } catch (_) {
      // 没挂 Provider 的场景（例如 widget 测试）不该崩
      return null;
    }
  }

  void _reload() => setState(() => _future = _scan());

  @override
  Widget build(BuildContext context) {
    final String title = _scoped
        ? (widget.appName?.trim().isNotEmpty ?? false
              ? widget.appName!.trim()
              : '权限管理')
        : '权限管理';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<PermissionScanReport>(
        future: _future,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<PermissionScanReport> snapshot,
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
              final PermissionScanReport report = snapshot.data!;
              return _scoped
                  ? _buildAppView(context, report, widget.appId!)
                  : _buildGlobalView(context, report);
            },
      ),
    );
  }

  // ============================================================ 全局视图

  Widget _buildGlobalView(BuildContext context, PermissionScanReport report) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    if (report.isEmpty) {
      return _EmptyBody(
        icon: Icons.shield_outlined,
        title: '还没有任何应用',
        message: '从主页打开一个小程序，它就会出现在这里，之后可以逐项管理它的权限。'
            '应用清单与「应用管理」是同一份。',
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        _ScanSummaryCard(report: report),
        _section(
          context,
          '权限使用情况',
          '按权限看：哪些应用申请过、被拒绝过几次',
          <Widget>[
            for (final MapEntry<PermissionGroup, List<MiniappPermission>> entry
                in MiniappPermission.grouped().entries)
              ...entry.value.map(
                (MiniappPermission p) => _ScanPermissionTile(
                  permission: p,
                  report: report,
                  onTap: () => _showUsageDialog(context, report, p),
                ),
              ),
          ],
        ),
        _section(
          context,
          '应用',
          '与「应用管理」同一份清单；点进去逐个设置权限',
          <Widget>[
            for (final KnownMiniapp app in report.miniapps)
              ListTile(
                leading: const Icon(Icons.widgets_outlined),
                title: Text(app.displayName),
                subtitle: Text(
                  _appSubtitle(report, app),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    PermissionControllerPage.route(
                      appId: app.id,
                      appName: app.displayName,
                    ),
                  );
                  if (mounted) _reload();
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            '权限由宿主在 WebView 层拦截：网页请求摄像头 / 麦克风时（getUserMedia），'
            '宿主会先弹窗问你，同意之后浏览器才会真的去开设备。'
            '每个权限的默认状态是「询问」—— 应用第一次用到它时会弹窗问你，'
            '弹窗里的「仅本次生效」默认勾选，所以只有你主动取消勾选，决定才会被记住并显示在这一页。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  String _appSubtitle(PermissionScanReport report, KnownMiniapp app) {
    final int denied = report.deniedOf(app.id).length;
    final int undecided = report.undecidedOf(app.id).length;
    final int used = MiniappPermission.values
        .where((MiniappPermission p) => report.usageOf(app.id, p).used)
        .length;
    final List<String> parts = <String>[app.id];
    parts.add(used == 0 ? '未申请过权限' : '申请过 $used 项权限');
    if (undecided > 0) parts.add('$undecided 项待询问');
    if (denied > 0) parts.add('已拒绝 $denied 项');
    final MiniappUsage last = _lastUsage(report, app.id);
    if (last.lastAt != null) parts.add('最近 ${formatDateTimeLabel(last.lastAt)}');
    return parts.join(' · ');
  }

  MiniappUsage _lastUsage(PermissionScanReport report, String appId) {
    MiniappUsage latest = MiniappUsage.empty;
    for (final MiniappPermission p in MiniappPermission.values) {
      final MiniappUsage u = report.usageOf(appId, p);
      if (u.lastAt != null &&
          (latest.lastAt == null || u.lastAt!.isAfter(latest.lastAt!))) {
        latest = u;
      }
    }
    return latest;
  }

  /// 点「权限使用情况」里的某一条：列出申请过它的应用与次数
  Future<void> _showUsageDialog(
    BuildContext context,
    PermissionScanReport report,
    MiniappPermission permission,
  ) async {
    final List<Widget> rows = <Widget>[];
    for (final KnownMiniapp app in report.miniapps) {
      final MiniappUsage usage = report.usageOf(app.id, permission);
      if (!usage.used) continue;
      final PermissionDecision decision = report.decisionOf(app.id, permission);
      rows.add(
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            switch (decision) {
              PermissionDecision.granted => Icons.check_circle_outline,
              PermissionDecision.denied => Icons.block_outlined,
              PermissionDecision.ask => Icons.help_outline,
            },
            color: decision == PermissionDecision.denied
                ? Theme.of(context).colorScheme.error
                : null,
          ),
          title: Text(app.displayName),
          subtitle: Text(
            '成功 ${usage.count} 次'
            '${usage.deniedCount > 0 ? ' · 被拒绝 ${usage.deniedCount} 次' : ''}'
            '${usage.lastAt == null ? '' : ' · 最近 ${formatDateTimeLabel(usage.lastAt)}'}',
          ),
        ),
      );
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(permission.label),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  permission.description,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty)
                  const Text('没有任何小程序用过这个能力')
                else
                  ...rows,
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ======================================================== 单小程序视图

  Widget _buildAppView(
    BuildContext context,
    PermissionScanReport report,
    String appId,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final KnownMiniapp? app = report.appById(appId);
    final int deniedCount = report.deniedOf(appId).length;
    final int undecidedCount = report.undecidedOf(appId).length;
    final int usedCount = MiniappPermission.values
        .where((MiniappPermission p) => report.usageOf(appId, p).used)
        .length;
    final int deniedCalls = MiniappPermission.values.fold<int>(
      0,
      (int sum, MiniappPermission p) =>
          sum + report.usageOf(appId, p).deniedCount,
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        // ---------------- 概览 ----------------
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.widgets_outlined, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          app?.displayName ?? appId,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    appId,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _StatChip(
                        icon: Icons.help_outline,
                        text: undecidedCount == 0
                            ? '没有待询问的权限'
                            : '$undecidedCount 项待询问',
                      ),
                      _StatChip(
                        icon: Icons.rule,
                        text: deniedCount == 0 ? '没有已拒绝的权限' : '已拒绝 $deniedCount 项',
                        danger: deniedCount > 0,
                      ),
                      _StatChip(
                        icon: Icons.bolt_outlined,
                        text: usedCount == 0 ? '未申请过权限' : '申请过 $usedCount 项',
                      ),
                      if (deniedCalls > 0)
                        _StatChip(
                          icon: Icons.block_outlined,
                          text: '拦截 $deniedCalls 次',
                          danger: true,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        // ---------------- 批量操作 ----------------
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: () => _setAll(appId, PermissionDecision.granted),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('全部允许'),
              ),
              OutlinedButton.icon(
                onPressed: () => _confirmAll(appId, PermissionDecision.denied),
                icon: const Icon(Icons.block_outlined, size: 18),
                label: const Text('全部拒绝'),
              ),
              TextButton.icon(
                onPressed: () => _reset(appId),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('全部改为询问'),
              ),
            ],
          ),
        ),

        // ---------------- 权限开关（按分组） ----------------
        for (final MapEntry<PermissionGroup, List<MiniappPermission>> entry
            in MiniappPermission.grouped().entries)
          _section(
            context,
            entry.key.label,
            null,
            <Widget>[
              for (final MiniappPermission p in entry.value)
                _PermissionDecisionTile(
                  permission: p,
                  decision: report.decisionOf(appId, p),
                  usage: report.usageOf(appId, p),
                  onChanged: (PermissionDecision value) async {
                    await PermissionService.instance.setDecision(appId, p, value);
                    if (mounted) _reload();
                  },
                ),
            ],
          ),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            '「询问」= 下次调用时弹窗（默认状态）；「允许 / 拒绝」= 已经替你记住，不再打断。'
            '弹窗里的「仅本次生效」默认勾选，那种选择不会显示在这里 —— 因为它本就没被记住。'
            '被拒绝时网页会收到浏览器的 NotAllowedError，设备不会被打开。'
            '「清除数据」不会重置这里的决定 —— 授权是你对这个应用的信任决定。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Future<void> _setAll(String appId, PermissionDecision decision) async {
    await PermissionService.instance.setAllDecisions(appId, decision);
    if (mounted) _reload();
  }

  Future<void> _confirmAll(String appId, PermissionDecision decision) async {
    final bool allowed = decision == PermissionDecision.granted;
    final bool? ok = await _confirm(
      title: allowed ? '允许全部权限？' : '拒绝全部权限？',
      message: allowed
          ? '该应用将可以使用摄像头、麦克风、管理所有文件，之后不再弹窗询问。'
          : '该应用将无法使用摄像头、麦克风，也无法管理所有文件。'
                '它可能因此无法正常工作。',
      confirmLabel: allowed ? '允许' : '拒绝',
    );
    if (ok == true) await _setAll(appId, decision);
  }

  Future<void> _reset(String appId) async {
    final bool? ok = await _confirm(
      title: '全部改为「询问」？',
      message: '删除该应用的全部决定：下次它用到哪个权限，就为哪个弹窗询问。'
          '申请记录不受影响。',
      confirmLabel: '改为询问',
    );
    if (ok != true) return;
    await PermissionService.instance.resetApp(appId);
    if (mounted) _reload();
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) => showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );

  // ================================================================ 组件

  Widget _section(
    BuildContext context,
    String title,
    String? subtitle,
    List<Widget> children,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
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

/// 全局视图顶部的「扫描概览」
class _ScanSummaryCard extends StatelessWidget {
  const _ScanSummaryCard({required this.report});

  final PermissionScanReport report;

  @override
  Widget build(BuildContext context) {
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
                Icon(Icons.security_outlined, color: scheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '共 ${report.totalApps} 个应用',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '其中 ${report.appsUsingSensitive} 个申请过权限 · '
              '权限被调用 ${report.totalCalls} 次'
              '${report.deniedCalls > 0 ? ' · 被拦截 ${report.deniedCalls} 次' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '权限决定：待询问 ${report.undecidedCount} 项 · 已拒绝 ${report.deniedCount} 项'
              '（每个应用每项权限各算一项）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final bool? ok = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext ctx) => AlertDialog(
                        title: const Text('拒绝全部应用的权限？'),
                        content: Text(
                          '将对全部 ${report.totalApps} 个应用把摄像头、麦克风、'
                          '管理所有文件设为「拒绝」。',
                        ),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('拒绝'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await PermissionService.instance.setSensitiveDecisionForAll(
                      report.miniapps.map((KnownMiniapp a) => a.id),
                      PermissionDecision.denied,
                    );
                    if (context.mounted) {
                      AppTheme.showToast('已拒绝全部应用的权限');
                    }
                  },
                  icon: const Icon(Icons.shield_outlined, size: 18),
                  label: const Text('一键拒绝全部权限'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 「权限使用情况」里的一行：这个权限被多少个应用申请过
class _ScanPermissionTile extends StatelessWidget {
  const _ScanPermissionTile({
    required this.permission,
    required this.report,
    required this.onTap,
  });

  final MiniappPermission permission;
  final PermissionScanReport report;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final List<KnownMiniapp> users = report.miniapps
        .where((KnownMiniapp a) => report.usageOf(a.id, permission).used)
        .toList(growable: false);
    final int deniedCalls = users.fold<int>(
      0,
      (int sum, KnownMiniapp a) =>
          sum + report.usageOf(a.id, permission).deniedCount,
    );
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(permission.icon),
      title: Row(
        children: <Widget>[
          Flexible(child: Text(permission.label)),
          const SizedBox(width: 8),
          PermissionRiskChip(risk: permission.risk, compact: true),
        ],
      ),
      subtitle: Text(
        users.isEmpty
            ? '没有被申请过'
            : '${users.length} 个应用申请过'
                  '${deniedCalls > 0 ? ' · 拦截 $deniedCalls 次' : ''}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: users.isEmpty ? scheme.onSurfaceVariant : null,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// 单应用视图里的一项权限：三态选择 + 申请记录。
///
/// 用 SegmentedButton 而不是 Switch：开关只有两态，会把"还没问过"错画成
/// "已允许"或"已拒绝"，而这一版里"还没问过"是默认状态，必须能一眼看出来。
class _PermissionDecisionTile extends StatelessWidget {
  const _PermissionDecisionTile({
    required this.permission,
    required this.decision,
    required this.usage,
    required this.onChanged,
  });

  final MiniappPermission permission;
  final PermissionDecision decision;
  final MiniappUsage usage;
  final ValueChanged<PermissionDecision> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> notes = <String>[permission.description];
    if (usage.count > 0) notes.add('已调用 ${usage.count} 次');
    if (usage.deniedCount > 0) notes.add('被拒绝 ${usage.deniedCount} 次');
    if (usage.lastAt != null) {
      notes.add('最近 ${formatDateTimeLabel(usage.lastAt)}');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(permission.icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  permission.label,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              const SizedBox(width: 8),
              PermissionRiskChip(risk: permission.risk, compact: true),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            notes.join(' · '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<PermissionDecision>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: <ButtonSegment<PermissionDecision>>[
                for (final PermissionDecision d in PermissionDecision.values)
                  ButtonSegment<PermissionDecision>(
                    value: d,
                    label: Text(d.label),
                  ),
              ],
              selected: <PermissionDecision>{decision},
              onSelectionChanged: (Set<PermissionDecision> selection) =>
                  onChanged(selection.first),
            ),
          ),
          // 「管理所有文件」在系统侧还有一层授权：应用内允许只是第一层，
          // 没有系统侧的「所有文件访问权限」照样读不到沙箱外的文件。
          // 所以这里直接给一个跳转入口，省得用户自己去设置里翻。
          if (permission.needsSystemSettings) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => NativeBridge.openAppSettings(),
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('打开系统设置授权'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 概览里的小统计胶囊
class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.text, this.danger = false});

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = danger ? scheme.errorContainer : scheme.surfaceContainerHighest;
    final Color foreground = danger ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 6),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
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
            Text('扫描失败', style: Theme.of(context).textTheme.titleMedium),
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

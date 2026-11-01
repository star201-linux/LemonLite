// lib/pages/detail/app_detail_page.dart
//
// 应用详情页。
//
// 0.6 起唯一动作是「打开」：确保**安装包已下载到本机**，再用 file:// 打开
// （见 pages/miniapp/miniapp_installer.dart）。没有「远程网页」这条路了。
//
// 页面要展示安装状态（未安装 / 已装 v1.0.0 / 有新版本），
// 所以它是 StatefulWidget —— 状态来自磁盘，进入页面时异步读一次。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/app_item.dart';
import '../../data/models/category.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/services/miniapp_package_service.dart';
import '../home/home_controller.dart';
import '../home/widgets/app_icon.dart';
import '../miniapp/miniapp_host.dart';
import '../miniapp/miniapp_installer.dart';
import '../permissions/permission_prompt.dart';
import '../permissions/widgets/permission_chips.dart';

class AppDetailPage extends StatefulWidget {
  const AppDetailPage({super.key, required this.app});

  final AppItem app;

  /// 统一的跳转入口，避免调用处重复写 MaterialPageRoute
  static Route<void> route(AppItem app) => MaterialPageRoute<void>(
    builder: (BuildContext context) => AppDetailPage(app: app),
  );

  @override
  State<AppDetailPage> createState() => _AppDetailPageState();
}

class _AppDetailPageState extends State<AppDetailPage> {
  /// 本机已安装的包（null = 没装）
  InstalledPackage? _installed;

  /// 是否正在读磁盘（首帧前）
  bool _loadingState = true;

  AppItem get app => widget.app;

  @override
  void initState() {
    super.initState();
    _loadInstalled();
  }

  Future<void> _loadInstalled() async {
    final InstalledPackage? pkg =
        await MiniappPackageService.instance.installed(app.id);
    if (!mounted) return;
    setState(() {
      _installed = pkg;
      _loadingState = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('应用详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: <Widget>[
          // ---------------- 头部：图标 + 名称 + 作者 ----------------
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 与列表卡片同一个 Hero tag：点进来时图标从这里落位
              AppIcon(
                name: app.name,
                iconUrl: app.icon,
                size: 76,
                heroTag: 'app-icon:${app.id}',
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      app.name,
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      app.author,
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        _InfoChip(
                          icon: Icons.label_outline,
                          text: _categoryName(context),
                        ),
                        _InfoChip(icon: Icons.tag, text: 'v${app.version}'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ---------------- 基础信息 ----------------
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: <Widget>[
                  _InfoRow(label: '版本', value: app.version),
                  _InfoRow(label: '分类', value: _categoryName(context)),
                  _InfoRow(label: '体积', value: app.sizeLabel),
                  _InfoRow(label: '作者', value: app.author),
                  _InfoRow(
                    label: '更新时间',
                    value: app.updatedAtLabel,
                    last: true,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ---------------- 简介 ----------------
          Text('应用简介', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            app.description,
            style: textTheme.bodyLarge?.copyWith(height: 1.6),
          ),

          // ---------------- 声明的权限 ----------------
          // index.json 的 permissions 字段在这里露出：用户点「打开」之前就能知道
          // 这个小程序会碰哪些能力，而不是等它开始弹窗。
          const SizedBox(height: 20),
          Text('申请的权限', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          _PermissionSummary(app: app),

          // ---------------- 标签 ----------------
          if (app.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            Text('标签', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: app.tags
                  .map((String tag) => Chip(label: Text(tag)))
                  .toList(growable: false),
            ),
          ],

          // ---------------- 截图（可选） ----------------
          if (app.screenshots.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            Text('应用介绍图', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: 208,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: app.screenshots.length,
                separatorBuilder: (BuildContext c, int i) =>
                    const SizedBox(width: 8),
                itemBuilder: (BuildContext c, int i) => ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    app.screenshots[i],
                    width: 150,
                    // 截图按实际显示宽度解码：横向列表里滑过去十几张，
                    // 不限制的话每张都按原图（可能是 1080p）进内存
                    cacheWidth: (150 * MediaQuery.devicePixelRatioOf(context))
                        .clamp(1.0, 4096.0)
                        .round(),
                    semanticLabel: '${app.name} 应用介绍图 ${i + 1}',
                    fit: BoxFit.cover,
                    // 截图挂了不能影响整页
                    errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                        Container(
                          width: 150,
                          color: scheme.surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                  ),
                ),
              ),
            ),
          ],

          // ---------------- 入口地址（开发者视角） ----------------
          const SizedBox(height: 20),
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.inventory_2_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text('安装信息', style: textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _installInfo(context),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 第一阶段的诚实说明：不假装能安装
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.info_outline,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  app.canOpen
                      ? '小程序以安装包形式提供：点「打开」时会先下载到本机，'
                          '之后打开不需要联网。服务端发布新版本时会在主页提示升级。'
                      : '这个条目还没有上架安装包，暂时无法打开。',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),

      // ---------------- 底部动作条 ----------------
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: <Widget>[
            // 安装：第一阶段禁用（明确禁用比点了没反应更好）
            Expanded(
              child: OutlinedButton.icon(
                onPressed: null,
                icon: const Icon(Icons.download_outlined),
                label: const Text('安装（第二阶段）'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: app.canOpen ? () => _openMiniapp(context) : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('打开'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分类 id → 分类名（从已加载的市场数据里查，查不到就显示原始 id）
  String _categoryName(BuildContext context) {
    // 用 chipCategories 而不是「分类列表」原样：它是首页 chip 的数据源，
    // 已经带上了「全部」而且只保留有内容的分类 —— 详情页要展示的
    // 正是「用户能看懂的那个名字」。
    for (final AppCategory category in context.watch<HomeController>().chipCategories) {
      if (category.id == app.category) return category.name;
    }
    return app.category;
  }

  /// 「安装信息」区块：版本、体积、本机状态。
  ///
  /// 必须把「装没装、装的是哪一版」说清楚 —— 这是 0.6 之后用户最需要知道
  /// 的一件事（旧版本里它只是个远程 URL，没有「装」这个概念）。
  Widget _installInfo(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    if (_loadingState) {
      return Text('正在读取安装状态…',
          style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant));
    }

    final InstalledPackage? pkg = _installed;
    // 三种状态：没装 / 已装且是最新 / 已装但有新版
    final bool newest = pkg != null &&
        (app.version.isEmpty || pkg.version == app.version);

    final String state;
    if (pkg == null) {
      state = app.canOpen ? '未安装（打开时会自动下载 ${app.packageSizeLabel}）' : '暂无安装包';
    } else if (newest) {
      state = '已安装 v${pkg.version}';
    } else {
      state = '已安装 v${pkg.version}，有新版本 v${app.version} 可更新';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _InfoRow(label: '版本', value: app.version.isEmpty ? '—' : app.version),
        _InfoRow(label: '安装包', value: app.canOpen ? app.packageSizeLabel : '未上架'),
        _InfoRow(label: '本机状态', value: state),
        if (pkg != null && !newest) ...<Widget>[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () async {
                final bool ok = await MiniappInstaller.ensureInstalled(
                  context,
                  app: app,
                  showProgress: true,
                );
                if (ok) await _loadInstalled();
              },
              icon: const Icon(Icons.system_update_alt, size: 18),
              label: Text('更新到 v${app.version}'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openMiniapp(BuildContext context) async {
    // 先按服务端声明的权限把还没问过的项一次性问清楚，再打开小程序。
    // 顺序很重要：弹窗要盖在**详情页**上（此时它还在最上层），
    // 而 open() 会把路由收回外壳层，之后再弹就会隔着覆盖层，交互会很怪。
    await PermissionPromptService.instance.requestDeclared(
      appId: app.id,
      appName: app.name,
      declared: app.declaredPermissions,
    );
    if (!context.mounted) return;

    // 没装 / 版本对不上 → 下载；装好了 → 直接开。
    final bool ok = await MiniappInstaller.ensureInstalled(
      context,
      app: app,
      showProgress: true,
    );
    if (!ok || !context.mounted) return;

    await MiniappHost.instance.open(
      appId: app.id,
      title: app.name,
      iconUrl: app.icon,
      declaredPermissions: app.declaredPermissions,
      // 已经装好的本地包：会话直接用 file:// 打开，不再走远程 url
      installedPackage: _installed,
    );
  }
}

/// 详情页的权限摘要：列出 index.json 里声明的受控权限。
///
/// 四种情况都要有明确说法，不能留白：
///   * 声明了 → 逐条列出（带风险等级）
///   * 没声明 → 提示"用到时会逐个弹窗询问"
///   * 声明了已退役的旧权限 → 说明它现在不需要授权（老数据里很常见，不是错误）
///   * id 真正写错了 → 明确指出，方便市场数据维护者发现
class _PermissionSummary extends StatelessWidget {
  const _PermissionSummary({required this.app});

  final AppItem app;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<MiniappPermission> declared = app.declaredPermissions;
    final List<String> retired = app.retiredPermissionIds;
    final List<String> unknown = app.unknownPermissionIds;

    if (declared.isEmpty && unknown.isEmpty && retired.isEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.help_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '这条市场数据没有声明权限。小程序第一次用到某个权限时会单独弹窗询问，'
              '你同意之后它才能用。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MiniappPermission p in declared)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(p.icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(p.label, style: theme.textTheme.bodyMedium),
                          ),
                          const SizedBox(width: 8),
                          PermissionRiskChip(risk: p.risk, compact: true),
                        ],
                      ),
                      Text(
                        p.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (declared.isNotEmpty)
          Text(
            '打开时会请你一次性确认这些权限。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        // 已退役的旧权限：说清楚"不需要授权了"，而不是让它看起来像个错误
        if (retired.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: declared.isEmpty ? 0 : 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '声明里的 ${retired.join("、")} 现在已不需要授权'
                    '（Android 本来也不禁止应用调整这些），仍然可以正常使用。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (unknown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.warning_amber_outlined, size: 16, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '市场数据里有无法识别的权限 id：${unknown.join("、")}'
                    '（会被忽略；多半是 index.json 写错了）',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 「标签: 值」行
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.last = false});

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 76,
                child: Text(
                  label,
                  style: textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: Text(value, style: textTheme.bodyMedium)),
            ],
          ),
        ),
        if (!last) Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }
}

/// 头部的小信息胶囊
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

// lib/pages/home/home_page.dart
//
// 应用市场主页：搜索框 + 分类 chips + 应用卡片列表 + 下拉刷新 + 四态视图。
//
// 滚动结构用 CustomScrollView：搜索框挂在 SliverAppBar.bottom 上，
// 这样它会一直「钉」在顶部（市场页最常见的交互），而分类 chips 会随内容滚走，
// 给列表让出更多空间。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/app_item.dart';
import '../../data/repositories/market_repository.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/update_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart';
import '../miniapp/miniapp_installer.dart';
import '../background/background_apps_page.dart';
import '../detail/app_detail_page.dart';
import '../miniapp/miniapp_host.dart';
import 'home_controller.dart';
import 'search_page.dart';
import 'widgets/app_card.dart';
import 'widgets/category_chips.dart';
import 'widgets/state_views.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _searchController = TextEditingController();

  /// 是否正在批量更新
  bool _updating = false;

  /// 用户点过「稍后再说」的那一批更新的指纹。
  /// 更新列表变了（新的版本号）就让提示条重新出现。
  String? _dismissedSignature;

  @override
  void initState() {
    super.initState();
    // 更新检查放在 AppShell 启动时做（全局状态，应用管理也要用），
    // 主页只负责展示。这里订阅结果的变化。
    UpdateService.instance.addListener(_onUpdatesChanged);
    // 首帧之后再触发加载：在 build/initState 期间调用 notifyListeners
    // 会碰到「build 期间 markNeedsBuild」的报错。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<HomeController>().ensureLoaded();
    });
  }

  void _onUpdatesChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 一批更新的指纹：appId + 新版本号。用来判断「稍后再说」还有效吗。
  String _signature(List<PackageUpdate> updates) => updates
      .map((PackageUpdate u) => '${u.appId}:${u.latestVersion}')
      .join(',');

  /// 全部更新
  Future<void> _updateAll() async {
    if (_updating) return;
    final List<PackageUpdate> targets = UpdateService.instance.updates;
    if (targets.isEmpty) return;
    final MarketRepository repository = context.read<MarketRepository>();

    setState(() => _updating = true);
    int ok = 0;
    for (final PackageUpdate u in targets) {
      if (!mounted) break;
      final bool success = await MiniappInstaller.forceInstall(
        context,
        appId: u.appId,
        appName: u.name,
        version: u.latestVersion,
        packageUrl: u.packageUrl,
        sha256: u.sha256,
        entry: u.entry,
        iconUrl: u.icon,
      );
      if (!success) continue;
      ok++;
      // 装好了就立刻从待更新列表里拿掉，应用管理的小红点随之消失
      UpdateService.instance.forget(u.appId);
      // 它可能正在后台跑着旧版本：文件已经换了，旧会话继续跑只会不一致
      if (MiniappHost.instance.isRunning(u.appId)) {
        await MiniappHost.instance.close(u.appId);
      }
    }
    if (!mounted) return;
    setState(() => _updating = false);
    AppTheme.showToast(
      ok == targets.length
          ? '已更新 $ok 个小程序'
          : '更新完成 $ok / ${targets.length} 个，其余失败',
      isError: ok != targets.length,
    );
    // 再向服务端核对一次（可能刚好又发了一版）
    await UpdateService.instance.checkAll(repository: repository, force: true);
  }

  @override
  void dispose() {
    UpdateService.instance.removeListener(_onUpdatesChanged);
    _searchController.dispose();
    super.dispose();
  }

  /// 下拉刷新：市场列表 + 已装小程序的更新状态一起刷。
  Future<void> _refreshAll() async {
    final HomeController controller = context.read<HomeController>();
    final MarketRepository repository = context.read<MarketRepository>();
    await controller.load();
    await UpdateService.instance.checkAll(repository: repository, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final HomeController controller = context.watch<HomeController>();
    final SettingsService settings = context.watch<SettingsService>();
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 待更新列表来自全局单例；用户点过「稍后再说」的同一批不重复弹提示条，
    // 但应用管理里的小红点仍然保留（信息不能被「关掉」）。
    final List<PackageUpdate> allUpdates = UpdateService.instance.updates;
    final List<PackageUpdate> updates =
        _dismissedSignature == _signature(allUpdates)
        ? const <PackageUpdate>[]
        : allUpdates;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: CustomScrollView(
          // 内容不足一屏时也要能下拉，否则刷不出来
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            // MD3 Expressive 的大标题 AppBar：展开时是 display 级标题，
            // 收起后只留一行 + 固定的搜索框。
            SliverAppBar.large(
              pinned: true,
              backgroundColor: scheme.surface,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              title: const Text('应用市场'),
              actions: <Widget>[
                // 后台应用：正在跑的小程序（含退到后台的）都在那里。
                ListenableBuilder(
                  listenable: MiniappHost.instance,
                  builder: (BuildContext c, Widget? child) {
                    final int running = MiniappHost.instance.runningCount;
                    return IconButton(
                      tooltip: running == 0 ? '后台应用' : '后台应用（$running 个运行中）',
                      onPressed: () => Navigator.of(
                        context,
                      ).push(BackgroundAppsPage.route()),
                      icon: Badge(
                        isLabelVisible: running > 0,
                        label: Text('$running'),
                        child: const Icon(Icons.layers_rounded),
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: controller.isLoading ? null : controller.load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                const SizedBox(width: 8),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(72),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                  // 只读的假搜索框：点一下进搜索页。
                  //
                  // 为什么不在主页边输入边过滤：搜索是服务端筛的
                  // （不会把全部应用拉到本地），标签 chip 也要服务端返回计数。
                  child: GestureDetector(
                    onTap: () => Navigator.of(
                      context,
                    ).push(SearchPage.route(initialQuery: controller.query)),
                    child: AbsorbPointer(
                      child: SearchBar(
                        controller: _searchController,
                        hintText: '搜索小程序、作者或标签',
                        leading: const Icon(Icons.search_rounded),
                        elevation: const WidgetStatePropertyAll<double>(0),
                        backgroundColor: WidgetStatePropertyAll<Color>(
                          scheme.surfaceContainerHigh,
                        ),
                        padding: const WidgetStatePropertyAll<EdgeInsets>(
                          EdgeInsets.symmetric(horizontal: 18),
                        ),
                        constraints: const BoxConstraints(minHeight: 56),
                        shape: WidgetStatePropertyAll<OutlinedBorder>(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // MD3E 的「大色块 + 大字号」开场卡片。
            SliverToBoxAdapter(
              child: _MarketHero(
                loadedCount: controller.loadedCount,
                updateCount: updates.length,
                loading: controller.isLoading,
              ),
            ),

            // 使用自定义服务器时给一条明确提示，避免用户「换了地址却不知道数据来自哪」
            if (settings.isCustomServer)
              SliverToBoxAdapter(
                child: _CustomServerBanner(url: settings.serverUrl),
              ),

            // 有包需要升级时给一条可操作提示。
            if (updates.isNotEmpty)
              SliverToBoxAdapter(
                child: StaggeredEntrance(
                  offset: 8,
                  child: _UpdateBanner(
                    updates: updates,
                    updating: _updating,
                    onUpdateAll: _updateAll,
                    onDismiss: () => setState(
                      () => _dismissedSignature = _signature(allUpdates),
                    ),
                  ),
                ),
              ),

            // 只有一个「全部」chip 时没必要占一行
            if (controller.chipCategories.length > 1)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: CategoryChips(
                    categories: controller.chipCategories,
                    selectedId: controller.categoryId,
                    countOf: controller.countFor,
                    onSelected: controller.selectCategory,
                  ),
                ),
              ),

            ..._buildContent(context, controller),
          ],
        ),
      ),
    );
  }

  /// 按状态返回内容 slivers。
  ///
  /// 「加载 / 空 / 错误」三者共用同一块 SliverFillRemaining，中间套
  /// StateTransition 做交叉淡入。为什么值得多这一层：
  /// 状态切换（转圈 → 错误、空 → 有数据）是这个页面**最频繁的重绘点**，
  /// 硬切会让用户觉得「闪了一下」，而淡入只是合成一层透明度。
  List<Widget> _buildContent(BuildContext context, HomeController controller) {
    switch (controller.status) {
      case HomeStatus.initial:
      case HomeStatus.loading:
        return <Widget>[
          _stateSliver('loading', const LoadingView(message: '正在加载应用市场…')),
        ];

      case HomeStatus.error:
        return <Widget>[
          _stateSliver(
            'error',
            ErrorView(
              title: '加载失败',
              message: controller.errorMessage ?? '未知错误',
              detail: controller.errorDetail,
              onRetry: controller.load,
            ),
          ),
        ];

      case HomeStatus.ready:
        if (!controller.hasData) {
          return <Widget>[
            _stateSliver(
              'empty-store',
              const EmptyView(
                icon: Icons.storefront_outlined,
                title: '市场里还没有应用',
                message: '服务端返回的应用列表是空的',
              ),
            ),
          ];
        }

        final List<AppItem> apps = controller.visibleApps;
        if (apps.isEmpty) {
          return <Widget>[
            _stateSliver(
              'empty-filter',
              EmptyView(
                icon: Icons.search_off,
                title: '没有匹配的应用',
                message: '换个关键词，或者切回「全部」分类试试',
                actionLabel: '清除筛选',
                onAction: () {
                  _searchController.clear();
                  controller.clearFilters();
                },
              ),
            ),
          ];
        }

        return <Widget>[
          SliverToBoxAdapter(
            child: _SectionHeader(
              count: apps.length,
              hasMore: controller.hasMore,
            ),
          ),
          SliverList.builder(
            itemCount: apps.length,
            itemBuilder: (BuildContext ctx, int i) => Padding(
              padding: EdgeInsets.fromLTRB(20, i == 0 ? 4 : 0, 20, 10),
              // 错峰入场：前几条依次浮现，后续的（滚出来的）直接出现。
              // index 取 `i % 8` —— 分页加载的第 20 条不该等半秒才出现。
              child: StaggeredEntrance(
                index: i % 8,
                child: AppCard(
                  app: apps[i],
                  onTap: () => _openDetail(ctx, apps[i]),
                ),
              ),
            ),
          ),
          // 滚到底部时自动取下一页。
          // 用 SliverToBoxAdapter 而不是在 ScrollController 里判位置 ——
          // 后者要额外管 dispose，而且「什么时候算到底」在
          // 不同设备上很难调准。
          SliverToBoxAdapter(
            child: _LoadMoreTrigger(
              hasMore: controller.hasMore,
              loading: controller.loadingMore,
              onTrigger: controller.loadMore,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Center(
                child: Text(
                  _footerLabel(controller, apps.length),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ];
    }
  }

  /// 把「一整屏状态视图」包成 sliver，并带上用于交叉淡入的 key
  Widget _stateSliver(String tag, Widget child) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: StateTransition(
        child: KeyedSubtree(key: ValueKey<String>(tag), child: child),
      ),
    );
  }

  void _openDetail(BuildContext context, AppItem app) {
    // 一下轻微的触觉反馈：列表项的「按下去」在视觉上只有一层水波纹，
    // 加一点震动能让「我确实点到了」这件事更确定（与搜索页保持一致）。
    HapticFeedback.selectionClick();
    Navigator.of(context).push(AppDetailPage.route(app));
  }

  /// 底部那行统计文案。
  ///
  /// 两种情况，都不能让用户猜「为什么没有更多了」：
  ///   * 还有更多 → 「已加载 N 个，继续下滑」
  ///   * 到底了   → 「共 N 个应用」
  ///
  /// 注意这里说「已加载」而不是「共」：服务端分页时客户端**不知道总数**，
  /// 谎报一个数字比不报更糟。
  String _footerLabel(HomeController controller, int visible) {
    if (controller.hasMore) {
      return '已加载 $visible 个，继续下滑加载更多';
    }
    return '共 $visible 个应用';
  }
}

/// 滚到底部时触发「加载下一页」。
///
/// 做法：这个 widget 出现在列表末尾，它一被 build 就说明用户已经滑到这里了。
/// 比起监听 ScrollController 的 offset，它对「列表高度变化 / 不同屏幕尺寸」
/// 都不敏感 —— 不需要维护任何阈值。
class _LoadMoreTrigger extends StatefulWidget {
  const _LoadMoreTrigger({
    required this.hasMore,
    required this.loading,
    required this.onTrigger,
  });

  final bool hasMore;
  final bool loading;
  final Future<void> Function() onTrigger;

  @override
  State<_LoadMoreTrigger> createState() => _LoadMoreTriggerState();
}

class _LoadMoreTriggerState extends State<_LoadMoreTrigger> {
  @override
  void initState() {
    super.initState();
    _fire();
  }

  @override
  void didUpdateWidget(covariant _LoadMoreTrigger old) {
    super.didUpdateWidget(old);
    // 上一页加载完之后，如果用户还停在底部，继续加载
    if (!old.loading && !widget.loading) _fire();
  }

  void _fire() {
    if (!widget.hasMore || widget.loading) return;
    // 放到帧末尾：build 期间调 setState（onTrigger 会 notifyListeners）会报错
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTrigger();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.hasMore) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// MD3E 开场卡片：大色块、大字号、装饰圆。
///
/// 它不是「广告位」，而是把当前市场的状态（加载了多少、有没有更新）
/// 用 Expressive 的方式说出来；刷新仍然在 AppBar 里。
class _MarketHero extends StatelessWidget {
  const _MarketHero({
    required this.loadedCount,
    required this.updateCount,
    required this.loading,
  });

  final int loadedCount;
  final int updateCount;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -34,
            top: -52,
            child: _DecorCircle(
              size: 150,
              color: scheme.primary.withValues(alpha: 0.16),
            ),
          ),
          Positioned(
            right: 36,
            bottom: -56,
            child: _DecorCircle(
              size: 110,
              color: scheme.tertiary.withValues(alpha: 0.14),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '发现小程序',
                      style: textTheme.headlineMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      loading ? '正在从服务端同步…' : '从服务端实时同步 · 已加载 $loadedCount 个',
                      style: textTheme.bodyMedium?.copyWith(
                        color: scheme.onPrimaryContainer.withValues(
                          alpha: 0.78,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        const _HeroPill(
                          icon: Icons.storefront_rounded,
                          label: '轻柠市场',
                        ),
                        if (updateCount > 0)
                          _HeroPill(
                            icon: Icons.system_update_alt_rounded,
                            label: '$updateCount 个可更新',
                            highlight: true,
                          )
                        else if (loadedCount > 0)
                          const _HeroPill(
                            icon: Icons.cloud_done_rounded,
                            label: '已是最新',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 34,
                  color: scheme.onPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DecorCircle extends StatelessWidget {
  const _DecorCircle({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({
    required this.icon,
    required this.label,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background = highlight
        ? scheme.primary
        : scheme.surface.withValues(alpha: 0.55);
    final Color foreground = highlight
        ? scheme.onPrimary
        : scheme.onPrimaryContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表区标题：数量用 tonal pill 标出来，右侧说明「还有没有更多」。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.count, required this.hasMore});

  final int count;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Row(
        children: <Widget>[
          Text(
            '全部应用',
            style: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count${hasMore ? '+' : ''}',
              style: textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          Text(
            hasMore ? '继续下滑加载' : '到底了',
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「当前使用自定义服务器」提示条
class _CustomServerBanner extends StatelessWidget {
  const _CustomServerBanner({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.dns_outlined,
              size: 18,
              color: scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '当前使用自定义服务器：$url',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「有 N 个小程序可更新」提示条。
///
/// 为什么做成 banner 而不是「自动静默升级」：
///   包可能有几十 MB，在移动网络下静默下载是**用户的钱**。
///   升级必须是一次显式的选择。
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({
    required this.updates,
    required this.updating,
    required this.onUpdateAll,
    required this.onDismiss,
  });

  final List<PackageUpdate> updates;
  final bool updating;
  final VoidCallback onUpdateAll;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int totalBytes = updates.fold<int>(
      0,
      (int sum, PackageUpdate u) => sum + u.bytes,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.system_update_alt_rounded,
              size: 20,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${updates.length} 个小程序可以更新',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    totalBytes > 0
                        ? '需要下载约 ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB'
                        : updates.first.versionLabel,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            if (updating)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              TextButton(onPressed: onUpdateAll, child: const Text('全部更新')),
            IconButton(
              tooltip: '稍后再说',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              color: scheme.onPrimaryContainer,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

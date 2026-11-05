// lib/pages/detail/app_detail_page.dart
//
// 应用详情页。
//
// 现在有两个入口：
//   1. 主页 / 搜索页点卡片 —— 纯详情页（看介绍、打开小程序）；
//   2. 应用管理点某个已装应用 —— 同一个详情页，但右上角多一颗**扳手**，
//      进「应用管理」的二级页（权限、数据、移除）。
//
// 为什么应用管理不直接跳到权限页了：
//   用户点进来最想看的通常是「这是个什么应用、装的是哪一版」，而不是权限开关。
//   权限/数据是**管理动作**，收在扳手后面；而详情页本身是用户熟悉的那个页面，
//   从主页和应用管理进来看到的是同一份东西。
//
// 底部动作条随状态变化：
//   * 没装 / 已装且最新 → 一枚「打开」（没装时写「下载并打开」）；
//   * 已装且有新版本   → 两枚：「更新」和「打开」。
//     「打开」打开的是**本机现在这一版**；想升级点「更新」。
//     这个区分很重要：以前只有一枚按钮，版本对不上就必须先下载，
//     用户明明只想用一下旧版也会被强制更新。
//
// 每次点「打开」都会向服务端问一次最新版本（UpdateService.checkOne）——
// 详情页可能已经开了很久，服务端在这期间发版是常态。发现更新时给三个选择：
// 取消 / 直接打开 / 更新并打开，不偷偷替用户做决定。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/globals.dart';
import '../../data/models/app_item.dart';
import '../../data/models/app_version.dart';
import '../../data/models/category.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/repositories/market_repository.dart';
import '../../data/services/application_registry.dart';
import '../../data/services/icon_cache_service.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/update_service.dart';
import '../../theme/app_theme.dart';
import '../applications/app_manage_detail_page.dart';
import '../home/home_controller.dart';
import '../home/widgets/app_icon.dart';
import '../miniapp/miniapp_host.dart';
import '../miniapp/miniapp_installer.dart';
import '../permissions/permission_prompt.dart';
import '../permissions/widgets/permission_chips.dart';

class AppDetailPage extends StatefulWidget {
  const AppDetailPage({super.key, required this.app, this.manageEntry = false});

  final AppItem app;

  /// 是否从「应用管理」进入。true 时右上角显示扳手（进入权限 / 数据 / 移除）。
  final bool manageEntry;

  /// 统一的跳转入口，避免调用处重复写 MaterialPageRoute
  static Route<void> route(AppItem app, {bool manageEntry = false}) =>
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            AppDetailPage(app: app, manageEntry: manageEntry),
      );

  /// 从「应用管理」按 appId 进入：先去服务端取完整市场数据；
  /// 拿不到（已下架 / 离线）就用本机信息构造一个最小详情页。
  static Route<void> routeForRegisteredApp({
    required String appId,
    required String name,
    String? icon,
  }) => MaterialPageRoute<void>(
    builder: (BuildContext context) =>
        _RegisteredAppDetailPage(appId: appId, name: name, icon: icon),
  );

  @override
  State<AppDetailPage> createState() => _AppDetailPageState();
}

/// 「打开时发现新版本」的三个选择（null = 取消）
enum _OpenChoice { open, update }

class _AppDetailPageState extends State<AppDetailPage> {
  /// 本机已安装的包（null = 没装）
  InstalledPackage? _installed;

  /// 本地缓存的图标路径
  String? _localIcon;

  /// 是否正在读磁盘（首帧前）
  bool _loadingState = true;

  /// 是否正在更新（两枚按钮时，更新期间两个都要禁用）
  bool _busy = false;

  AppItem get app => widget.app;

  /// 装了旧版：本地版本与服务端当前版本不一致。
  ///
  /// 先看全局更新状态（它可能刚被「打开前检查」刷新过，比详情数据新），
  /// 再退回详情数据里的版本。
  bool get _hasUpdate {
    final InstalledPackage? installed = _installed;
    if (installed == null) return false;
    final PackageUpdate? pending = UpdateService.instance.of(app.id);
    if (pending != null && pending.latestVersion.isNotEmpty) {
      return pending.latestVersion != installed.version;
    }
    return app.version.isNotEmpty && installed.version != app.version;
  }

  /// 能不能打开：有可下载的包，或者本机已经装好了。
  bool get _canOpen => _installed != null || app.canOpen;

  @override
  void initState() {
    super.initState();
    // 打开前检查 / 启动检查都会更新全局状态：底部按钮要跟着变
    UpdateService.instance.addListener(_onUpdatesChanged);
    _loadInstalled();
  }

  @override
  void dispose() {
    UpdateService.instance.removeListener(_onUpdatesChanged);
    super.dispose();
  }

  void _onUpdatesChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadInstalled() async {
    final InstalledPackage? pkg = await MiniappPackageService.instance
        .installed(app.id);
    String? icon = await IconCacheService.instance.pathOf(app.id);
    icon ??= await IconCacheService.instance.ensure(
      appId: app.id,
      url: app.icon,
    );
    if (!mounted) return;
    setState(() {
      _installed = pkg;
      _localIcon = icon;
      _loadingState = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('应用详情'),
        actions: <Widget>[
          if (widget.manageEntry)
            IconButton(
              tooltip: '应用详情与管理（权限、数据、移除）',
              icon: const Icon(Icons.build_outlined),
              onPressed: _openManage,
            ),
        ],
      ),
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
                localPath: _localIcon,
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
                          text: _primaryCategoryName(context),
                        ),
                        _InfoChip(icon: Icons.tag, text: 'v${app.version}'),
                        if (_hasUpdate)
                          _InfoChip(icon: Icons.system_update_alt, text: '可更新'),
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
                  _InfoRow(label: '分类', value: _categoryNames(context)),
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
          // 市场数据里的 permissions 字段在这里露出：用户点「打开」之前就能知道
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

          // ---------------- 安装信息 ----------------
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
                      ? '首次打开会自动下载到本机（之后离线也能打开）；'
                            '每次打开前都会向服务端确认一次版本。'
                      : '这个条目还没有上架安装包，暂时无法打开。'
                            '如果本机已经装过，仍然可以打开已装的版本。',
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
        child: _actions(context),
      ),
    );
  }

  /// 底部按钮：有更新时两枚（更新 / 打开），否则一枚（打开）。
  Widget _actions(BuildContext context) {
    if (_hasUpdate) {
      return Row(
        children: <Widget>[
          Expanded(
            child: SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _updateOnly,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update_alt),
                label: const Text('更新'),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _canOpen && !_busy ? _openMiniapp : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('打开'),
              ),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        onPressed: _canOpen && !_busy ? _openMiniapp : null,
        icon: Icon(_canOpen ? Icons.play_arrow : Icons.block),
        label: Text(_openButtonLabel),
      ),
    );
  }

  /// 「打开」按钮的文案：没装过就说清楚会先下载，装过就老老实实叫「打开」
  String get _openButtonLabel {
    if (!_canOpen) return '暂不可用';
    if (_installed == null) return '下载并打开';
    return '打开';
  }

  /// 进「应用管理」的二级页（权限 / 数据 / 移除）。
  Future<void> _openManage() async {
    await Navigator.of(
      context,
    ).push(AppManageDetailPage.route(appId: app.id, appName: app.name));
    if (!mounted) return;
    // 在管理页里移除了它：这个详情页已经没有意义了，一起退出
    if (!ApplicationRegistry.instance.contains(app.id)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  /// 只更新、不打开（底部「更新」按钮）。
  Future<void> _updateOnly() async {
    if (_busy) return;
    setState(() => _busy = true);

    // 用全局更新状态里的最新版本（可能比这个页面打开时拿到的 app.version 更新）；
    // 没有就退回详情数据里的版本。
    final PackageUpdate? pending = UpdateService.instance.of(app.id);
    final bool ok = pending == null
        ? await MiniappInstaller.ensureInstalled(
            context,
            app: app,
            showProgress: true,
          )
        : await MiniappInstaller.forceInstall(
            context,
            appId: app.id,
            appName: app.name,
            version: pending.latestVersion,
            packageUrl: pending.packageUrl,
            sha256: pending.sha256,
            entry: pending.entry,
            iconUrl: pending.icon,
          );
    if (!mounted) return;
    if (ok) {
      UpdateService.instance.forget(app.id);
      // 正在后台跑旧版本的话，关掉它：文件已经换新，旧 WebView 不该继续用旧页面
      if (MiniappHost.instance.isRunning(app.id)) {
        await MiniappHost.instance.close(app.id);
      }
      await _loadInstalled();
    }
    if (mounted) setState(() => _busy = false);
  }

  /// 打开小程序。**每次都会先问一次服务端版本**（见文件头）。
  Future<void> _openMiniapp() async {
    if (_busy) return;
    final MarketRepository repository = context.read<MarketRepository>();
    InstalledPackage? pkg = _installed;

    // 先按服务端声明的权限把还没问过的项一次性问清楚，再打开小程序。
    // 顺序很重要：弹窗要盖在**详情页**上（此时它还在最上层），
    // 而 open() 会把路由收回外壳层，之后再弹就会隔着覆盖层，交互会很怪。
    await PermissionPromptService.instance.requestDeclared(
      appId: app.id,
      appName: app.name,
      declared: app.declaredPermissions,
    );
    if (!mounted) return;

    // 每次打开都问一次最新版本（失败静默：离线时按本机已装的打开）
    final AppVersionInfo? latest = await UpdateService.instance.checkOne(
      app.id,
      repository: repository,
    );
    if (!mounted) return;

    if (pkg == null) {
      // ---- 没装：下载最新版再开 ----
      if (!app.canOpen) {
        AppTheme.showToast('「${app.name}」还没有上架安装包', isError: true);
        return;
      }
      // 刚查到的服务端版本比详情数据新时，按服务端这一版下载（否则会装到旧包，
      // 打开后又立刻提示更新）。
      final bool ok = (latest != null && latest.hasPackage)
          ? await MiniappInstaller.forceInstall(
              context,
              appId: app.id,
              appName: app.name,
              version: latest.version,
              packageUrl: latest.packageUrl,
              sha256: latest.sha256,
              entry: latest.entry,
              iconUrl: latest.icon,
            )
          : await MiniappInstaller.ensureInstalled(
              context,
              app: app,
              showProgress: true,
            );
      if (!ok || !mounted) return;
      pkg = await MiniappPackageService.instance.installed(app.id);
      if (pkg == null || !mounted) return;
      UpdateService.instance.forget(app.id);
    } else if (latest != null &&
        latest.hasPackage &&
        latest.version != pkg.version) {
      // ---- 装了旧版：让用户决定更新还是直接开 ----
      final _OpenChoice? choice = await _askUpdateOrOpen(latest, pkg);
      if (choice == null || !mounted) return;
      if (choice == _OpenChoice.update) {
        setState(() => _busy = true);
        final bool ok = await MiniappInstaller.forceInstall(
          context,
          appId: app.id,
          appName: app.name,
          version: latest.version,
          packageUrl: latest.packageUrl,
          sha256: latest.sha256,
          entry: latest.entry,
          iconUrl: latest.icon,
        );
        if (!mounted) return;
        setState(() => _busy = false);
        if (!ok) return;
        UpdateService.instance.forget(app.id);
        // 旧版本可能还在后台跑着，先关掉再打开新版本
        if (MiniappHost.instance.isRunning(app.id)) {
          await MiniappHost.instance.close(app.id);
        }
        pkg = await MiniappPackageService.instance.installed(app.id);
        if (pkg == null || !mounted) return;
      }
      // 选「直接打开」就继续用本机这一版
    }

    await MiniappHost.instance.open(
      appId: app.id,
      title: app.name,
      iconUrl: app.icon,
      declaredPermissions: app.declaredPermissions,
      // 已经装好的本地包：会话直接用 file:// 打开
      installedPackage: pkg,
    );
    if (mounted) _loadInstalled();
  }

  Future<_OpenChoice?> _askUpdateOrOpen(
    AppVersionInfo latest,
    InstalledPackage installed,
  ) {
    return showDialog<_OpenChoice>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text(
          '「${app.name}」本机是 v${installed.version}，服务端最新是 v${latest.version}。\n\n'
          '可以更新后打开，也可以直接用当前版本打开。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_OpenChoice.open),
            child: const Text('直接打开'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_OpenChoice.update),
            child: const Text('更新并打开'),
          ),
        ],
      ),
    );
  }

  /// 主分类名（头部 chip 只放一个，避免一行被塞满）。
  ///
  /// 名字优先用服务端返回的 `categories`（详情接口已经带回来了）；
  /// 老服务端不返回这个数组时，退回首页 chip 的分类名。
  String _primaryCategoryName(BuildContext context) {
    final String id = app.category;
    if (id.isEmpty) return '未分类';
    for (final AppCategory category in app.categories) {
      if (category.id == id) return category.name;
    }
    // 用 chipCategories 而不是「分类列表」原样：它是首页 chip 的数据源，
    // 已经带上了「全部」而且只保留有内容的分类。
    for (final AppCategory category
        in context.watch<HomeController>().chipCategories) {
      if (category.id == id) return category.name;
    }
    return id;
  }

  /// 全部分类名：服务端支持一个应用挂多个分类，这里如实展示。
  String _categoryNames(BuildContext context) {
    if (app.categories.isNotEmpty) {
      return app.categories.map((AppCategory c) => c.name).join(' · ');
    }
    return _primaryCategoryName(context);
  }

  /// 「安装信息」区块：版本、体积、本机状态。
  ///
  /// 必须把「装没装、装的是哪一版」说清楚 —— 这是用户最需要知道的一件事。
  Widget _installInfo(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    if (_loadingState) {
      return Text(
        '正在读取安装状态…',
        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    final InstalledPackage? pkg = _installed;
    // 三种状态：没装 / 已装且是最新 / 已装但有新版
    final bool newest =
        pkg != null && (app.version.isEmpty || pkg.version == app.version);

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
        _InfoRow(
          label: '安装包',
          value: app.canOpen ? app.packageSizeLabel : '未上架',
        ),
        _InfoRow(label: '本机状态', value: state),
      ],
    );
  }
}

/// 应用管理里点进来的「加载壳」：先取市场数据，再展示同一个详情页。
///
/// 为什么不在列表里直接 await 完再 push：
///   网络可能很慢（甚至超时 12 秒）。点一下之后干等着什么都不发生，
///   用户会以为没点中。先 push 一个带标题的转圈页，数据回来后就地替换内容。
class _RegisteredAppDetailPage extends StatefulWidget {
  const _RegisteredAppDetailPage({
    required this.appId,
    required this.name,
    this.icon,
  });

  final String appId;
  final String name;
  final String? icon;

  @override
  State<_RegisteredAppDetailPage> createState() =>
      _RegisteredAppDetailPageState();
}

class _RegisteredAppDetailPageState extends State<_RegisteredAppDetailPage> {
  AppItem? _app;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final MarketRepository repository = context.read<MarketRepository>();
    AppItem? item;
    try {
      item = await repository.fetchApp(widget.appId);
      // 顺手把市场里的最新名字 / 图标 / 分类回写到本机清单：
      // 管理员换了图标后，应用管理列表要能跟着变（图标缓存也按新 URL 重下）。
      // 回写失败不该让详情页退回本地兜底 —— 数据已经拿到了。
      try {
        await ApplicationRegistry.instance.record(
          appId: item.id,
          name: item.name,
          icon: item.icon,
          category: item.category,
        );
      } catch (e) {
        lemonLog('AppDetail', '回写应用清单失败：$e');
      }
    } catch (e) {
      // 下架 / 离线都走本地兜底：本机装过的东西仍然要能看、能开
      final InstalledPackage? pkg = await MiniappPackageService.instance
          .installed(widget.appId);
      final RegisteredApp? registered = ApplicationRegistry.instance.byId(
        widget.appId,
      );
      item = AppItem(
        id: widget.appId,
        name: registered?.displayName ?? widget.name,
        description:
            '这个应用已经不在市场里了。本机仍保留着它的安装包与数据，'
            '可以继续打开，也可以在右上角的「扳手」里清除。',
        category: registered?.category ?? '',
        version: pkg?.version ?? '',
        author: '',
        packageUrl: '',
        icon: widget.icon ?? registered?.icon,
      );
    }
    if (!mounted) return;
    setState(() {
      _app = item;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _app == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return AppDetailPage(app: _app!, manageEntry: true);
  }
}

/// 详情页的权限摘要：列出市场数据里声明的受控权限。
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
                            child: Text(
                              p.label,
                              style: theme.textTheme.bodyMedium,
                            ),
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
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
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
                Icon(
                  Icons.warning_amber_outlined,
                  size: 16,
                  color: scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '市场数据里有无法识别的权限 id：${unknown.join("、")}'
                    '（会被忽略；多半是市场数据写错了）',
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

// lib/pages/miniapp/miniapp_page.dart
//
// 小程序会话视图：一个 WebView + 一套 JSBridge + 主题 CSS 变量注入 +
// 右上角悬浮宿主菜单。
//
// 与阶段一最大的不同：它**不再是一个路由**。原因见 miniapp_host.dart 的文件头 ——
// 「后台运行」要求页面状态活得比路由久，所以小程序改为挂在 Navigator Overlay 上的
// 一个层（MiniappHost 负责插层/切前台），本文件只负责「一个会话长什么样」。
//
// 因此这里没有 PopScope：系统返回键由 MiniappHost.handleSystemBack() 统一接管，
// 会话视图通过 session.onSystemBack 把「先回退 WebView 历史」这件事交出去。
//
// 阶段一最关键的三件事仍然在这里串起来：
//   1. 注入顺序：先注入主题数据（window.__LEMONLITE_THEME__），再注入 JS SDK，
//      这样 SDK 初始化时立刻把 --md-* 写进 <html>，页面 <body> 渲染前主题就绪 —— 不会闪。
//   2. 注册 JSBridge：JsBridge.attach(controller, BridgeApi(...))。
//   3. 主题热更新：用户在设置页切主题时，用 evaluateJavascript 调 SDK 的 __applyTheme。
//
// 一个容易踩的坑（已规避）：InAppWebView 的 initial* 参数只在创建时生效。
// 如果每次 build 都传一个新对象，插件可能判定配置变化而重建 WebView，
// 导致小程序被重新加载、状态丢失。所以：
//   * initialSettings 做成 static final，保证 widget 恒等；
//   * WebView widget 只构建一次并缓存（_webViewWidget），主题变化只走 JS 热更新。

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../bridge/bridge_api.dart';
import '../../bridge/bundle_injector.dart';
import '../../bridge/geo_policy_js.dart';
import '../../bridge/injected_js.dart';
import '../../bridge/js_bridge.dart';
import '../../bridge/web_permission.dart';
import '../../core/autotest.dart';
import '../../core/globals.dart';
import '../../core/miniapp_asset_server.dart';
import '../../core/miniapp_web_origin.dart';
import '../../core/native_bridge.dart';
import '../../data/models/bundle_manifest.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/models/miniapp_session.dart';
import '../../data/repositories/bundle_repository.dart';
import '../../data/services/download_service.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../data/services/permission_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/md3e_interceptor.dart';
import '../../theme/md3e_styles.dart';
import '../../theme/loading.dart';
import '../../theme/theme_controller.dart';
import '../../theme/theme_injector.dart';
import '../home/widgets/state_views.dart';
import '../permissions/permission_controller_page.dart';
import '../permissions/permission_prompt.dart';
import '../background/background_apps_page.dart';
import 'miniapp_host.dart';

/// 会话视图。由 MiniappHost 的覆盖层为每个会话创建一个，key = appId。
class MiniappSessionView extends StatefulWidget {
  const MiniappSessionView({super.key, required this.session});

  final MiniappSession session;

  @override
  State<MiniappSessionView> createState() => _MiniappSessionViewState();
}

class _MiniappSessionViewState extends State<MiniappSessionView>
    with WidgetsBindingObserver {
  /// WebView 初始设置（与主题无关，做成常量保证 widget 恒等）
  static final InAppWebViewSettings _webViewSettings = InAppWebViewSettings(
    javaScriptEnabled: true,
    domStorageEnabled: true,
    databaseEnabled: true,
    // 小程序要弹窗走 JSBridge 的 showToast，不放开 window.open
    javaScriptCanOpenWindowsAutomatically: false,
    mediaPlaybackRequiresUserGesture: true,
    supportZoom: false,
    transparentBackground: false,
    verticalScrollBarEnabled: true,
    // 自己实现链接拦截（tel: / mailto: 等转交系统）
    useShouldOverrideUrlLoading: true,
    // 开启资源拦截：本地包的页面与子资源都从这里出（见 _serveLocalResource）。
    // 不开这个开关，shouldInterceptRequest 回调根本不会被调用。
    useShouldInterceptRequest: true,
    // 本地包**不再走 file://**（module script 在 file:// 下会被 CORS 拒，
    // 见 core/miniapp_web_origin.dart），所以这三个开关现在只是兜底：
    // 页面里若自己写了 file:// 资源，仍然只允许「读页面本身」，不允许顺着
    // 文件系统爬、也不允许绕过 CORS —— 本地包的内容依旧按不可信处理。
    allowFileAccess: true,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    allowsInlineMediaPlayback: true,
    // iframe 里也要能用摄像头/麦克风：小程序常把预览放进 iframe，
    // 不声明的话 Chromium 会直接拒绝，而且不给我们拦截的机会。
    iframeAllow: 'camera; microphone',
    iframeAllowFullscreen: true,
  );

  MiniappSession get _session => widget.session;

  /// 供 onWebViewCreated 回调使用（那里不宜再用 BuildContext 取 Provider）
  late ThemeController _themeController;

  /// 当前 WebView 对应的桥接实例（dispose 时要取消蓝牙事件订阅）
  BridgeApi? _bridge;

  InAppWebViewController? _controller;

  /// WebView widget 只构建一次并缓存（见文件头注释）
  Widget? _webViewWidget;

  /// 本地 HTML（assets 模式：从 asset 读出来，塞给 initialData）
  String? _localHtml;
  bool _loadingAsset = false;
  Object? _assetError;

  /// 加载进度 0~1
  double _progress = 0;

  /// 主文档加载错误
  String? _pageError;

  /// 上一次已经注入到页面的主题 JSON：相同就不重复注入
  String? _appliedThemeJson;

  /// 小程序是否主动调用过 setTitle（调用过就不再被页面 <title> 覆盖）
  bool _titleOverridden = false;

  /// 当前生效的模块内容（在 initState 时读好，WebView 只构建一次）
  List<BundlePayload> _payloads = const <BundlePayload>[];
  Map<String, BundleBridgeMethod> _moduleMethods =
      <String, BundleBridgeMethod>{};
  bool _bundleLoadFailed = false;

  @override
  void initState() {
    super.initState();
    // 把会话需要的回调挂上去：返回键、后台保活、重载
    _session.onSystemBack = _handleBack;
    _session.onResumeTimers = _resumeTimers;
    _session.onPauseTimers = _pauseTimers;
    _session.onReload = _reload;

    if (_session.localAsset != null) {
      _loadingAsset = true;
      _loadLocalAsset();
    }
    _loadBundles();

    // 定位策略依赖两件事：宿主是否在前台、这个小程序是不是当前前台会话。
    // 两者都会变，所以都要订阅。
    WidgetsBinding.instance.addObserver(this);
    MiniappHost.instance.addListener(_onGeoPolicyChanged);
    // 用户在权限页改了精度 / 后台时，正在运行的小程序要立刻按新策略走
    PermissionService.maybeInstance?.addListener(_onGeoPolicyChanged);
  }

  // ------------------------------------------------------------ 定位策略

  /// 当前生效的定位策略（精度 + 后台 + 此刻是否前台）。
  /// 建 WebView 时的初始快照。
  ///
  /// 这里**假定前台**：页面刚开始加载就说明它要被展示，此时 MiniappHost
  /// 可能还没把 _foregroundId 切过来；按后台处理会让刚打开的页面直接
  /// 拿不到定位，直到下一次生命周期回调才恢复。
  Map<String, dynamic> _initialGeoPolicy() {
    final LocationGrant grant =
        PermissionService.maybeInstance?.locationOf(_session.appId) ??
        LocationGrant.initial;
    return grant.toJs(foreground: true);
  }

  Map<String, dynamic> _geoPolicy() {
    final LocationGrant grant =
        PermissionService.maybeInstance?.locationOf(_session.appId) ??
        LocationGrant.initial;
    final AppLifecycleState state =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    final bool foreground =
        state == AppLifecycleState.resumed &&
        MiniappHost.instance.isForeground(_session.appId);
    return grant.toJs(foreground: foreground);
  }

  Future<void> _pushGeoPolicy() async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(
        source:
            'window.__lemonliteApplyGeo && '
            'window.__lemonliteApplyGeo(${jsonEncode(_geoPolicy())})',
      );
    } catch (e) {
      lemonLog('Miniapp', '下发定位策略失败：$e');
    }
  }

  void _onGeoPolicyChanged() {
    if (!mounted) return;
    unawaited(_pushGeoPolicy());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    unawaited(_pushGeoPolicy());
  }

  Future<void> _loadBundles() async {
    try {
      final BundleRepository repo = BundleRepository.instance;
      final Set<String> disabled = await repo.disabledIds();
      final List<BundleManifest> all = <BundleManifest>[];
      // 只有模块会注入页面；插件（plugin）是宿主能力，不参与注入 ——
      // 把它也读进来只会多出一份空 payload。
      for (final BundleType type in <BundleType>[BundleType.module]) {
        all.addAll(await repo.scan(type));
      }
      final String? url = _session.fileUri;
      final List<BundleManifest> active = all
          .where((BundleManifest m) => !disabled.contains(m.id))
          .where((BundleManifest m) => bundleMatchesUrl(m, url))
          .toList(growable: false);

      _payloads = await repo.readPayloads(active, url: _session.fileUri);
      _moduleMethods = await repo.activeModuleMethods();
      lemonLog(
        'Miniapp',
        '生效的模块：${_payloads.map((BundlePayload p) => p.label).join(", ")}',
      );
    } catch (e) {
      _bundleLoadFailed = true;
      lemonLog('Miniapp', '读取模块失败：$e');
    }
    if (!mounted) return;
    // 读失败不该拦住小程序本体，但要让用户看得见（多半是包被手工改坏了）
    if (_bundleLoadFailed) {
      AppTheme.showToast('部分模块未能加载', isError: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _themeController = context.read<ThemeController>();
    // 主题变化会走到这里（Theme 是 InheritedWidget），同步给已经在跑的页面
    _syncTheme(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    // 会话可能比视图活得久（后台运行），所以这里只解绑回调，不动会话本身
    WidgetsBinding.instance.removeObserver(this);
    MiniappHost.instance.removeListener(_onGeoPolicyChanged);
    PermissionService.maybeInstance?.removeListener(_onGeoPolicyChanged);
    _bridge?.dispose();
    _bridge = null;
    _session.onEvent = null;
    if (_session.onSystemBack == _handleBack) _session.onSystemBack = null;
    if (_session.onResumeTimers == _resumeTimers) {
      _session.onResumeTimers = null;
    }
    if (_session.onPauseTimers == _pauseTimers) _session.onPauseTimers = null;
    if (_session.onReload == _reload) _session.onReload = null;
    super.dispose();
  }

  /// 从 asset 读内置示例的 HTML。
  ///
  /// 结局只有两种：`_localHtml` 有内容，或 `_assetError` 有异常 ——
  /// 两者都会 setState，build 才能继续走。
  Future<void> _loadLocalAsset() async {
    try {
      final String html = await rootBundle.loadString(_session.localAsset!);
      if (!mounted) return;
      setState(() {
        _localHtml = html;
        _loadingAsset = false;
      });
      lemonLog('Miniapp', '内置 asset 已读取：${html.length} 字符');
    } catch (e) {
      lemonLogError('Miniapp', '读取内置 asset 失败：$e');
      if (!mounted) return;
      setState(() {
        _assetError = e;
        _loadingAsset = false;
      });
    }
  }

  // ------------------------------------------------------------ 主题注入

  /// 把当前 ColorScheme 同步进 WebView。
  /// force=true 用于页面刚加载完时「以最新主题覆盖一次」（UserScript 里的快照可能已过期）。
  void _syncTheme(ColorScheme scheme, {bool force = false}) {
    final Map<String, dynamic> payload = ThemeInjector.toThemePayload(
      scheme,
      themeModeLabel: _themeController.themeModeLabel,
      source: _themeController.sourceLabel,
    );
    final String json = jsonEncode(payload);
    if (!force && json == _appliedThemeJson) return;
    _appliedThemeJson = json;

    final InAppWebViewController? controller = _controller;
    if (controller == null) return; // 还没创建：document-start 的 UserScript 会带上同一份数据
    controller.evaluateJavascript(
      source: ThemeInjector.buildLiveUpdateScript(payload),
    );
  }

  static List<UserScript> _buildUserScripts(
    Map<String, dynamic> payload,
    List<BundlePayload> bundles,
    Map<String, dynamic> geoPolicy,
  ) {
    final List<UserScript> scripts = <UserScript>[
      UserScript(
        source: ThemeInjector.buildPayloadScript(payload),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      // 定位策略要**早于页面脚本**就位：页面可能一上来就 watchPosition。
      // 先给数据，再上 shim —— shim 初始化时读的就是这份快照。
      UserScript(
        source:
            'window.__LEMONLITE_GEO__ = ${jsonEncode(geoPolicy)};',
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      UserScript(
        source: GeoPolicyJs.source,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      UserScript(
        source: Md3eStyles.buildInjectScript(),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      // DOM 拦截：给「作者没管过」的原生控件打 MD3E 标记。
      // 拦截路径已经在文档里写过一次，这里靠 __LEMONLITE_MD3E_DOM__ 幂等；
      // 走 initialData 的内置页面（没有文件可拦截）则完全依赖这一条。
      UserScript(
        source: Md3eStyles.buildDomScript(),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      UserScript(
        source: LemonJsSdk.source,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
      UserScript(
        source: BundleInjector.buildRegistryScript(bundles),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ];

    for (final MapEntry<BundleRunAt, List<BundlePayload>> entry
        in BundleInjector.groupByRunAt(bundles).entries) {
      final String source = BundleInjector.buildScript(entry.value);
      if (source.isEmpty) continue;
      scripts.add(
        UserScript(
          source: source,
          injectionTime: BundleInjector.toInjectionTime(entry.key),
        ),
      );
    }
    return scripts;
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    // 既没有已装包也没有本地资源：给个明确的错误页，而不是白屏
    if (_session.webUri == null && _session.localAsset == null) {
      return _shell(
        child: const ErrorView(title: '无法打开', message: '这个小程序还没有安装到本机，也没有内置资源'),
      );
    }

    if (_session.localAsset != null && _loadingAsset) {
      return _shell(child: const LoadingView(message: '正在准备小程序…'));
    }

    if (_assetError != null) {
      return _shell(
        child: ErrorView(
          title: '小程序读取失败',
          message: '无法从 assets 载入 ${_session.localAsset}',
          detail: '$_assetError',
          onRetry: () {
            setState(() {
              _assetError = null;
              _loadingAsset = true;
            });
            _loadLocalAsset();
          },
        ),
      );
    }

    final ThemeController themeController = context.watch<ThemeController>();
    final Map<String, dynamic> payload = ThemeInjector.toThemePayload(
      Theme.of(context).colorScheme,
      themeModeLabel: themeController.themeModeLabel,
      source: themeController.sourceLabel,
    );

    return Scaffold(
      // 让 WebView 铺满整块屏幕（含状态栏下方与手势条区域），
      // 页面自己用 env(safe-area-inset-*) / 100vh 处理留白。
      // extendBody 让 body 延伸到手势条下面；
      // extendBodyBehindAppBar 在没有 appBar 时是空操作，去掉更诚实。
      extendBody: true,
      body: Stack(
        children: <Widget>[
          // 只构建一次；后续主题变化走 JS 热更新而不是重建 WebView
          _webViewWidget ??= _buildWebViewWidget(payload),
          if (_progress > 0 && _progress < 1)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              // 页面加载进度：细条贴在页面顶部，不抢内容
              child: M3ELinearProgressIndicator(
                value: _progress,
                height: 4,
                showStopIndicator: false,
              ),
            ),
          if (_pageError != null)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: ErrorView(
                title: '页面加载失败',
                message: _pageError!,
                detail: _session.entry,
                onRetry: _reload,
              ),
            ),
          Positioned(
            top: 0,
            right: 8,
            child: SafeArea(
              bottom: false,
              child: _FloatingMoreButton(onSelected: _onHeaderMenuSelected),
            ),
          ),
        ],
      ),
    );
  }

  Widget _shell({required Widget child}) => Scaffold(
    body: Stack(
      children: <Widget>[
        Positioned.fill(child: child),
        Positioned(
          top: 0,
          right: 8,
          child: SafeArea(
            bottom: false,
            child: _FloatingMoreButton(onSelected: _onHeaderMenuSelected),
          ),
        ),
      ],
    ),
  );

  /// 资源服务器：只在拿到 app/ 根目录后构造一次。
  ///
  /// 拦截回调是高频的，每次都 await path_provider 太浪费；
  /// 根目录在进程生命周期里也不会变。
  MiniappAssetServer? _assets;

  /// 把虚拟源上的请求交给资源服务器。
  ///
  /// 返回 null = 不是我们的请求（外链 / 其它 scheme），交给 WebView 默认处理。
  Future<WebResourceResponse?> _serveLocalResource(
    WebResourceRequest request,
    Map<String, dynamic> payload,
  ) async {
    final WebUri url = request.url;
    if (!MiniappWebOrigin.owns(url)) return null;

    MiniappAssetServer? server = _assets;
    if (server == null) {
      final InstalledPackage? pkg = _session.installedPackage;
      if (pkg == null) return null; // asset 模式不会有虚拟源请求
      try {
        final Directory root =
            await MiniappPackageService.instance.rootDirectory();
        server = _assets = MiniappAssetServer(root: root, appId: pkg.appId);
      } catch (e) {
        lemonLog('Miniapp', '读取 app 目录失败：$e');
        return MiniappAssetServer.notFound(url);
      }
    }

    return server.respond(
      url,
      // 页面先插 MD3E 样式再交给解析器（子资源不走这里）
      documentRenderer: (Uri u, File f) =>
          Md3eInterceptor.intercept(url: u, file: f, payload: payload),
    );
  }

  Widget _buildWebViewWidget(Map<String, dynamic> payload) {
    final String? assetHtml = _localHtml;
    final Uri? webUri = _session.webUri;

    lemonLog(
      'Miniapp',
      '构建 WebView：模式=${assetHtml != null
              ? "initialData(asset)"
              : webUri != null
              ? "localOrigin"
              : "无入口"}'
          ' · html=${assetHtml == null ? "null" : "${assetHtml.length} 字符"}'
          ' · webUri=$webUri'
          ' · scripts=${_buildUserScripts(payload, _payloads, _initialGeoPolicy()).length}',
    );

    return InAppWebView(
      // 本地包：虚拟 https 地址。**不要**用 initialFile（asset 语义，见上）。
      initialUrlRequest: webUri == null
          ? null
          : URLRequest(url: WebUri(webUri.toString())),
      // 内置 asset：HTML 字符串。baseUrl 给 https 以便相对资源按 web 解析。
      initialData: assetHtml == null
          ? null
          : InAppWebViewInitialData(
              data: assetHtml,
              baseUrl: WebUri('https://lemonlite.local/'),
              mimeType: 'text/html',
              encoding: 'utf-8',
            ),
      initialSettings: _webViewSettings,
      initialUserScripts: UnmodifiableListView<UserScript>(
        _buildUserScripts(payload, _payloads, _initialGeoPolicy()),
      ),
      shouldInterceptRequest:
          (InAppWebViewController controller, WebResourceRequest request) =>
              _serveLocalResource(request, payload),
      onWebViewCreated: (InAppWebViewController controller) {
        lemonLog('Miniapp', 'WebView 已创建');
        _onWebViewCreated(controller);
      },
      onPermissionRequest:
          (InAppWebViewController controller, PermissionRequest request) async {
            final WebPermissionAsk ask = WebPermissionAsk.from(request);

            if (ask.isUnmanaged) {
              return PermissionResponse(
                action: PermissionResponseAction.GRANT,
                resources: request.resources,
              );
            }

            final Set<MiniappPermission> granted = await PermissionPromptService
                .instance
                .ensureAll(
                  _session.appId,
                  ask.permissions,
                  appName: _session.title,
                );

            // 每个被请求的权限都记一笔（允许算调用、拒绝算被拦）。
            // 未在 metadata.json 里声明的权限靠这条记录才能出现在权限管理里。
            final PermissionService? permsUse = PermissionService.maybeInstance;
            if (permsUse != null) {
              for (final MiniappPermission p in ask.permissions) {
                unawaited(
                  permsUse.recordUse(
                    _session.appId,
                    p,
                    denied: !granted.contains(p),
                  ),
                );
              }
            }

            final Set<MiniappPermission> systemGranted = <MiniappPermission>{};
            for (final MiniappPermission permission in granted) {
              if (!permission.needsRuntimePermission) {
                systemGranted.add(permission);
                continue;
              }
              final bool ok = await NativeBridge.requestRuntimePermissions(
                permission.runtimePermissions,
              );
              if (ok) {
                systemGranted.add(permission);
              } else {
                await autotestLog(
                  '系统运行时权限被拒绝：${permission.runtimePermissions.join(",")}',
                );
              }
            }

            await autotestLog(
              'WebView 权限请求：${ask.permissions.map((MiniappPermission p) => p.id).join(",")}'
              ' → 应用内允许 ${granted.map((MiniappPermission p) => p.id).join(",")}'
              ' · 系统层允许 ${systemGranted.map((MiniappPermission p) => p.id).join(",")}',
            );

            return WebPermissionAsk.response(ask: ask, granted: systemGranted);
          },
      onGeolocationPermissionsShowPrompt:
          (InAppWebViewController controller, String origin) async {
            final PermissionAnswer answer = await PermissionPromptService.instance
                .ensure(
                  _session.appId,
                  MiniappPermission.location,
                  appName: _session.title,
                );
            final PermissionService? permsUse = PermissionService.maybeInstance;
            if (permsUse != null) {
              unawaited(
                permsUse.recordUse(
                  _session.appId,
                  MiniappPermission.location,
                  denied: !answer.allowed,
                ),
              );
            }
            if (!answer.allowed) {
              await autotestLog('定位请求被拒绝：$origin');
              return GeolocationPermissionShowPromptResponse(
                origin: origin,
                allow: false,
                retain: false,
              );
            }

            final PermissionService perms = PermissionService.instance;
            final LocationGrant stored = perms.locationOf(_session.appId);
            final LocationGrant grant = stored.copyWith(
              decision: PermissionDecision.granted,
              precision: answer.precision,
              background: answer.background,
            );

            // 系统层：精度决定 FINE / COARSE。FINE 隐含 COARSE，所以精确时
            // 只申请 FINE 一条（多申请一条 COARSE 在 Android 12+ 上是无效值）。
            final bool systemOk = await NativeBridge.requestRuntimePermissions(
              perms.locationRuntimePermissions(grant),
            );
            await autotestLog(
              '定位请求：$origin → 精度 ${grant.precision.id}'
              ' · 后台 ${grant.background} · 系统层 $systemOk',
            );

            await _pushGeoPolicy();

            return GeolocationPermissionShowPromptResponse(
              origin: origin,
              allow: systemOk,
              // retain=true 会让 WebView 记住这个 origin 的决定，
              // 后续同源请求不再回调我们 —— 那样用户在权限管理里改成「拒绝」
              // 就不会生效了。所以一律 false，每次都问我们的模型。
              retain: false,
            );
          },
      // ---------------------------------------------------------------- 下载
      //
      // 网页里点 `<a download>` / 触发下载时，WebView 自己**不会**下载任何东西
      // （Android WebView 没有内建下载器），必须在宿主这边接住。
      //
      // 这里把任务交给系统的 DownloadManager（见 DownloadService / DownloadBridge）：
      // 落盘在公共「下载」目录、下载过程活过宿主进程、下完有系统通知。
      // 宿主不申请「所有文件」权限 —— 写公共下载目录这件事由系统组件代劳。
      //
      // 返回 CANCEL 是**必须**的：我们不希望 WebView 再走它自己的默认路径
      // （那是一条什么都没发生的静默失败），无论我们这边成功还是失败，
      // 下载都已经在我们的记录里，失败了也在管理页能看到原因。
      onDownloadStarting:
          (
            InAppWebViewController controller,
            DownloadStartRequest request,
          ) async {
            await _handleDownloadStart(request);
            return DownloadStartResponse(
              handled: true,
              action: DownloadStartResponseAction.CANCEL,
            );
          },
      onProgressChanged: (InAppWebViewController controller, int progress) {
        if (!mounted) return;
        setState(() => _progress = progress / 100);
      },
      onLoadStart: (InAppWebViewController controller, WebUri? url) {
        lemonLog('Miniapp', '开始加载：$url');
        if (!mounted) return;
        setState(() => _pageError = null);
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        lemonLog('Miniapp', '加载完成：$url');
        // 主动问一次页面实际状态 —— 白屏时这几条能立刻分辨
        // 「页面没加载」和「加载了但内容为空」。
        await _probePageState(controller);
        if (!mounted) return;
        setState(() => _progress = 1);
        MiniappHost.instance.touch(_session.appId);
        // 页面加载完，用「当前最新」主题覆盖一次（UserScript 里的快照可能已过期）
        _syncTheme(Theme.of(context).colorScheme, force: true);
        // 定位策略同理：文档开始时的快照可能早于权限变更
        unawaited(_pushGeoPolicy());
      },
      onReceivedError:
          (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            // 只关心主文档；子资源（图标、截图）失败不该打断整个小程序
            if (request.isForMainFrame != true) return;
            lemonLogError(
              'Miniapp',
              '主文档加载失败：${request.url} · ${error.type} · ${error.description}',
            );
            if (!mounted) return;
            // description 在 flutter_inappwebview 6.x 里已经是非空 String
            setState(() => _pageError = error.description);
          },
      onReceivedHttpError:
          (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceResponse response,
          ) {
            if (request.isForMainFrame != true) return;
            lemonLogError(
              'Miniapp',
              '主文档 HTTP ${response.statusCode}：${request.url}',
            );
            if (!mounted) return;
            setState(() => _pageError = '服务器返回 HTTP ${response.statusCode}');
          },
      onTitleChanged: (InAppWebViewController controller, String? title) {
        // 小程序主动 setTitle 过就尊重它，否则跟随页面 <title>
        if (_titleOverridden) return;
        final String text = title?.trim() ?? '';
        if (text.isEmpty) return;
        _session.titleNotifier.value = text;
      },
      onConsoleMessage:
          (InAppWebViewController controller, ConsoleMessage message) {
            // 页面的 console.error / 未捕获异常都在这里 —— 白屏时
            // 十有八九能在这里看到真正的原因。
            //
            // 注意：ConsoleMessage 只有 message 与 messageLevel 两个字段
            //（没有 sourceId / lineNumber），所以这里拿不到行号。
            final String text =
                '${message.messageLevel.name} ${message.message}';
            if (message.messageLevel == ConsoleMessageLevel.ERROR) {
              lemonLogError('console', text);
            } else {
              lemonLog('console', text);
            }
          },
      shouldOverrideUrlLoading:
          (InAppWebViewController controller, NavigationAction action) async {
            final String? raw = action.request.url?.toString();
            final Uri? uri = raw == null ? null : Uri.tryParse(raw);
            if (uri == null) return NavigationActionPolicy.ALLOW;

            final String scheme = uri.scheme.toLowerCase();
            if (scheme == 'http' ||
                scheme == 'https' ||
                scheme == 'about' ||
                scheme == 'data' ||
                scheme == 'blob') {
              // 小程序内部导航一律放行（返回由 host 的返回键逻辑处理）
              return NavigationActionPolicy.ALLOW;
            }

            // tel: / mailto: / weixin: / intent: 等交给系统处理
            try {
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } else {
                AppTheme.showToast('没有可以处理 $scheme: 的应用', isError: true);
              }
            } catch (e) {
              AppTheme.showToast('打开外部应用失败：$e', isError: true);
            }
            return NavigationActionPolicy.CANCEL;
          },
    );
  }

  // ------------------------------------------------------------ 回调

  void _onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;

    // 桥接层不再接权限入口：权限的拦截点在 WebView 的 onPermissionRequest
    // （见上面的回调与 bridge/web_permission.dart），不在 JSBridge 这一层。
    final BridgeApi api = BridgeApi(
      appId: _session.appId,
      appName: _session.title,
      themeController: _themeController,
      // 蓝牙 notify / 连接状态 / 扫描结果等原生主动事件 → WebView 里的 JS SDK
      onEvent: (String appId, String type, Map<String, dynamic> data) {
        _session.onEvent?.call(type, data);
      },
      session: _session,
      // 蓝牙 / NFC 这类原生能力：桥接层调用前先走同一个权限弹窗。
      permissionPrompter:
          (String appId, MiniappPermission permission, {String? appName}) =>
              PermissionPromptService.instance.ensure(
                appId,
                permission,
                appName: appName ?? _session.title,
              ),
      onSetTitle: (String title) {
        _titleOverridden = true;
        _session.titleNotifier.value = title;
      },
      onNavigateBack: _navigateBack,
      onRunInBackground: () =>
          MiniappHost.instance.sendToBackground(_session.appId),
      onCloseMiniapp: () => MiniappHost.instance.close(_session.appId),
      moduleMethods: _moduleMethods,
    );

    _bridge = api;
    _session.onEvent = _dispatchEvent;
    JsBridge.attach(controller: controller, api: api);
    // 页面里的定位 shim 可能已经按初始快照跑起来了：这里用真实的前后台
    // 状态覆盖一次（初始快照按「前台」算，见 _initialGeoPolicy）。
    _pushGeoPolicy();
    lemonLog('Miniapp', '打开小程序 ${_session.appId}：${_session.entry}');
  }

  /// 把宿主事件安全地送进页面：
  ///   * 页面可能已经导航走 / WebView 还没创建：直接丢弃；
  ///   * type 与 data 都做 JSON 编码，不拼字符串（避免引号/换行破坏 JS）；
  ///   * SDK 还没装好时 `window.lemonlite` 不存在，表达式短路即可。
  void _dispatchEvent(String type, Map<String, dynamic> data) {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    final String script =
        'window.lemonlite && window.lemonlite.__dispatchEvent && '
        'window.lemonlite.__dispatchEvent('
        '${jsonEncode(type)}, ${jsonEncode(data)});';
    controller.evaluateJavascript(source: script);
  }

  Future<bool> _navigateBack(int delta) async {
    final InAppWebViewController? controller = _controller;
    if (controller != null && delta == 1 && await controller.canGoBack()) {
      await controller.goBack();
      return true;
    }
    await MiniappHost.instance.sendToBackground(_session.appId);
    AppTheme.showToast('「${_session.title}」已转入后台运行');
    return true;
  }

  /// 系统返回键（由 MiniappHost 转过来）。返回 false 表示「退无可退」，宿主再决定。
  Future<bool> _handleBack() async {
    final InAppWebViewController? controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return true;
    }
    return false;
  }

  /// 切回前台：恢复 JS 定时器
  Future<void> _resumeTimers() async {
    try {
      await _controller?.resumeTimers();
    } catch (e) {
      lemonLog('Miniapp', 'resumeTimers 失败：$e');
    }
  }

  /// 转到后台：挂起 JS 定时器
  ///
  /// 注意 Android 的 pauseTimers/resumeTimers 是**进程级**的
  ///（WebView 的静态方法），所以宿主只在「没有任何小程序在前台」时才调它，
  /// 见 miniapp_host.dart 的 sendToBackground。
  Future<void> _pauseTimers() async {
    try {
      await _controller?.pauseTimers();
    } catch (e) {
      lemonLog('Miniapp', 'pauseTimers 失败：$e');
    }
  }

  /// 网页触发的下载 → 系统下载器。
  ///
  /// 失败原因全部当场告诉用户（弹一个 toast）并写进运行日志：
  /// 下载是少数"用户明确期待一个结果"的操作，静默失败比报错更糟。
  Future<void> _handleDownloadStart(DownloadStartRequest request) async {
    final String url = request.url.toString();
    try {
      final DownloadTask task = await DownloadService.instance.enqueue(
        url: url,
        // suggestedFilename 来自 Content-Disposition / URL，WebView 已经帮我们猜过一轮；
        // 它为空时 DownloadService 会自己按 URL 与 MIME 推断。
        fileName: request.suggestedFilename,
        mimeType: request.mimeType,
      );
      await autotestLog('网页下载：$url → #${task.id} ${task.relativePath}');
      AppTheme.showToast('已开始下载：${task.fileName}');
    } on DownloadException catch (e) {
      await autotestLog('网页下载失败：$url · ${e.message}');
      lemonLogError('Miniapp', '下载失败：$url · ${e.message}');
      AppTheme.showToast(e.message, isError: true);
    } catch (e) {
      await autotestLog('网页下载失败：$url · $e');
      lemonLogError('Miniapp', '下载失败：$url · $e');
      AppTheme.showToast('下载失败：$e', isError: true);
    }
  }

  Future<void> _probePageState(InAppWebViewController controller) async {
    try {
      final Object? raw = await controller.evaluateJavascript(
        source: '''
(function () {
  try {
    var b = document.body;
    var r = b ? b.getBoundingClientRect() : null;
    return {
      url: location.href,
      title: document.title || '',
      readyState: document.readyState,
      hasBody: !!b,
      bodyChildren: b ? b.children.length : -1,
      bodyW: r ? Math.round(r.width) : -1,
      bodyH: r ? Math.round(r.height) : -1,
      bodyTextLen: b ? (b.innerText || '').length : -1,
      htmlLen: (document.documentElement.outerHTML || '').length,
      sdk: !!(window.lemonlite && window.lemonlite.__installed),
      sdkVer: (window.lemonlite && window.lemonlite.version) || '',
      themeVars: !!window.__LEMONLITE_THEME__
    };
  } catch (e) { return { error: String(e) }; }
})()
''',
      );
      lemonLog('Miniapp', '页面状态：$raw');
    } catch (e) {
      // 探测失败本身也是信息（说明 JS 都跑不了）
      lemonLogError('Miniapp', '页面状态探测失败：$e');
    }
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _pageError = null;
      _progress = 0;
    });
    await _controller?.reload();
  }

  Future<void> _onHeaderMenuSelected(_HostMenuAction action) async {
    switch (action) {
      case _HostMenuAction.home:
        // 「返回主页」= 把小程序的层收起来（不销毁会话）。
        // 与「关闭」的区别是：会话还在，从主页/后台应用能回来。
        // 与「后台运行」的区别是：它同时跳回主页 Tab，而不只是切走。
        await MiniappHost.instance.goHome();
      case _HostMenuAction.reload:
        await _reload();
        if (!mounted) return;
        AppTheme.showToast('已刷新');
      case _HostMenuAction.close:
        await MiniappHost.instance.close(_session.appId);
      case _HostMenuAction.background:
        await MiniappHost.instance.sendToBackground(_session.appId);
        if (!mounted) return;
        // 切换主题 / 弹 toast 都走宿主层（此时小程序已不在前台）
        AppTheme.showToast('「${_session.title}」已转入后台运行');
      case _HostMenuAction.permissions:
        if (!mounted) return;
        await Navigator.of(context).push(
          PermissionControllerPage.route(
            appId: _session.appId,
            appName: _session.title,
          ),
        );
      case _HostMenuAction.backgroundApps:
        if (!mounted) return;
        await Navigator.of(context).push(BackgroundAppsPage.route());
    }
  }
}

/// 悬浮菜单里的动作。
///
/// 只保留「宿主对小程序的会话操作」。
/// 「用浏览器打开 / 查看入口地址」已移除 —— 它们对普通用户没有意义
/// （入口地址是调试信息），而调试信息在开发者选项里能看到。
enum _HostMenuAction {
  home,
  reload,
  close,
  background,
  permissions,
  backgroundApps,
}

class _FloatingMoreButton extends StatelessWidget {
  const _FloatingMoreButton({required this.onSelected});

  final ValueChanged<_HostMenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Material(
      // 半透明：压在网页内容上也不至于把内容完全挡住
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.9),
      elevation: 3,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<_HostMenuAction>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        // 按钮在右上角，菜单默认往下方弹，正好在屏幕内
        offset: const Offset(0, 8),
        onSelected: onSelected,
        itemBuilder: (BuildContext c) {
          // 窗口模式（小程序作为独立任务打开）里没有「宿主主页」也没有
          // 「后台应用列表」：这个窗口本身就是一个独立应用，系统切换器
          // 就是它的后台。菜单里只留「刷新 / 关闭 / 权限」三件事，
          // 少掉的两个选项不是藏起来，而是这个模式下真的不存在。
          final bool window = MiniappHost.instance.windowMode;
          return <PopupMenuEntry<_HostMenuAction>>[
            if (!window)
              PopupMenuItem<_HostMenuAction>(
                value: _HostMenuAction.home,
                child: _menuRow(context, Icons.home_outlined, '返回主页'),
              ),
            PopupMenuItem<_HostMenuAction>(
              value: _HostMenuAction.reload,
              child: _menuRow(context, Icons.refresh, '刷新'),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<_HostMenuAction>(
              value: _HostMenuAction.close,
              child: _menuRow(
                context,
                Icons.close,
                window ? '关闭窗口' : '关闭',
                danger: true,
              ),
            ),
            if (!window)
              PopupMenuItem<_HostMenuAction>(
                value: _HostMenuAction.background,
                child: _menuRow(context, Icons.play_circle_outline, '后台运行'),
              ),
            const PopupMenuDivider(),
            PopupMenuItem<_HostMenuAction>(
              value: _HostMenuAction.permissions,
              child: _menuRow(context, Icons.verified_user_outlined, '权限管理'),
            ),
            if (!window)
              PopupMenuItem<_HostMenuAction>(
                value: _HostMenuAction.backgroundApps,
                child: _menuRow(context, Icons.layers_outlined, '后台应用'),
              ),
          ];
        },
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            Icons.more_horiz,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _menuRow(
    BuildContext context,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color? color = danger ? scheme.error : null;
    return Row(
      children: <Widget>[
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: color == null ? null : TextStyle(color: color)),
      ],
    );
  }
}

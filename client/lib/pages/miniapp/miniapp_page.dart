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

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../bridge/bridge_api.dart';
import '../../bridge/bundle_injector.dart';
import '../../bridge/injected_js.dart';
import '../../bridge/js_bridge.dart';
import '../../bridge/web_permission.dart';
import '../../core/autotest.dart';
import '../../core/globals.dart';
import '../../core/native_bridge.dart';
import '../../data/models/bundle_manifest.dart';
import '../../data/models/miniapp_permission.dart';
import '../../data/models/miniapp_session.dart';
import '../../data/repositories/bundle_repository.dart';
import '../../data/services/download_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../../theme/theme_injector.dart';
import '../home/widgets/state_views.dart';
import '../permissions/permission_controller_page.dart';
import '../permissions/permission_prompt.dart';
import '../background/background_apps_page.dart';
import 'miniapp_host.dart';

/// 内置示例小程序的资源路径（pubspec.yaml 已声明 `assets/miniapp-demo/`）
const String kDemoMiniappAsset = 'assets/miniapp-demo/index.html';

/// 会话视图。由 MiniappHost 的覆盖层为每个会话创建一个，key = appId。
class MiniappSessionView extends StatefulWidget {
  const MiniappSessionView({super.key, required this.session});

  final MiniappSession session;

  @override
  State<MiniappSessionView> createState() => _MiniappSessionViewState();
}

class _MiniappSessionViewState extends State<MiniappSessionView> {
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
    // 本地包（file://）必须允许文件访问，否则 WebView 直接拒绝加载。
    // 注意这三个开关的**区别**，别只开错的那个：
    //   allowFileAccess               → 允许 WebView 加载 file:// 的**页面本身**
    //   allowFileAccessFromFileURLs   → 允许 file:// 页面里的 JS 去读别的 file://
    //   allowUniversalAccessFromFileURLs → 允许 file:// 页面发任意跨域请求
    // 只开第一个：页面能加载，但页面里的脚本**不能**顺着文件系统爬出去，
    // 也不能绕过 CORS 读别处 —— 这对一个「从网络下载来的 HTML」是必须的。
    allowFileAccess: true,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    // getUserMedia 要在页面内联播放（不跳系统播放器），否则摄像头预览出不来。
    // 这两项与 onPermissionRequest 配合使用：前者决定「能不能内联播放」，
    // 后者决定「采集设备给不给」——缺一个摄像头都用不了。
    allowsInlineMediaPlayback: true,
    // iframe 里也要能用摄像头/麦克风：小程序常把预览放进 iframe，
    // 不声明的话 Chromium 会直接拒绝，而且不给我们拦截的机会。
    iframeAllow: 'camera; microphone',
    iframeAllowFullscreen: true,
  );

  MiniappSession get _session => widget.session;

  /// 供 onWebViewCreated 回调使用（那里不宜再用 BuildContext 取 Provider）
  late ThemeController _themeController;

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

  /// 当前生效的模块 / 扩展内容（在 initState 时读好，WebView 只构建一次）
  List<BundlePayload> _payloads = const <BundlePayload>[];
  Map<String, BundleBridgeMethod> _moduleMethods = <String, BundleBridgeMethod>{};
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
  }

  /// 读取已启用的模块 / 扩展。
  ///
  /// 放在 initState 而不是 build 里：WebView widget 只构建一次，
  /// 注入脚本必须在那一次构建时就齐备，所以必须提前拿到内容。
  Future<void> _loadBundles() async {
    try {
      final BundleRepository repo = BundleRepository.instance;
      final Set<String> disabled = await repo.disabledIds();
      final List<BundleManifest> all = <BundleManifest>[];
      // 只读会注入页面的两类；插件（plugin）是宿主能力，不参与注入 ——
      // 把它也读进来只会多出一份空 payload。
      for (final BundleType type in <BundleType>[
        BundleType.extension,
        BundleType.module,
      ]) {
        all.addAll(await repo.scan(type));
      }
      // matches 为 "*" 的包对所有小程序生效；带具体模式的按当前入口地址过滤。
      // 本地包这里是 file:// 地址 —— 扩展的 matches 模式通常写 http(s)，
      // 所以本地包默认只吃 "*" 的扩展（这是合理的行为：本地包不该按域名匹配）。
      final String? url = _session.fileUri;
      final List<BundleManifest> active = all
          .where((BundleManifest m) => !disabled.contains(m.id))
          .where((BundleManifest m) => bundleMatchesUrl(m, url))
          .toList(growable: false);

      _payloads = await repo.readPayloads(active, url: _session.fileUri);
      _moduleMethods = await repo.activeModuleMethods();
      lemonLog(
        'Miniapp',
        '生效的模块/扩展：${_payloads.map((BundlePayload p) => p.label).join(", ")}',
      );
    } catch (e) {
      _bundleLoadFailed = true;
      lemonLog('Miniapp', '读取模块/扩展失败：$e');
    }
    if (!mounted) return;
    // 读失败不该拦住小程序本体，但要让用户看得见（多半是包被手工改坏了）
    if (_bundleLoadFailed) {
      AppTheme.showToast('部分模块/扩展未能加载', isError: true);
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
    if (_session.onSystemBack == _handleBack) _session.onSystemBack = null;
    if (_session.onResumeTimers == _resumeTimers) _session.onResumeTimers = null;
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

  /// 注入顺序：[主题数据] → [JS SDK] → [模块/扩展] → [包清单]
  ///
  /// 扩展排在 SDK 之后，才能一上来就用 window.lemonlite.*；
  /// 清单单独最早注入，方便小程序在任何时候读 window.__LEMONLITE_BUNDLES__。
  static List<UserScript> _buildUserScripts(
    Map<String, dynamic> payload,
    List<BundlePayload> bundles,
  ) {
    final List<UserScript> scripts = <UserScript>[
      UserScript(
        source: ThemeInjector.buildPayloadScript(payload),
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
    if (_session.fileUri == null && _session.localAsset == null) {
      return _shell(
        child: const ErrorView(
          title: '无法打开',
          message: '这个小程序还没有安装到本机，也没有内置资源',
        ),
      );
    }

    // ⚠ 内置 asset 必须先释放成文件再建 WebView。
    //
    // 为什么：`_webViewWidget ??= _buildWebViewWidget(payload)` 只在**第一次**
    // build 时执行。如果此时 _assetFileUri 还是 null（异步释放还没回来），
    // WebView 会以 url=null 创建，之后再 setState 也不会重建它 ——
    // 结果是页面上只剩那颗悬浮按钮，WebView 区域永远空白。
    //
    // 0.5 及之前这个问题被掩盖了：那时还有 initialUrlRequest（远程 url 不为
    // null）兜底，所以 WebView 至少会加载点什么。删掉远程入口之后它才暴露。
    if (_session.localAsset != null && _loadingAsset) {
      return _shell(child: const LoadingView(message: '正在准备示例小程序…'));
    }

    if (_assetError != null) {
      return _shell(
        child: ErrorView(
          title: '示例小程序读取失败',
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

    // 0.4 起**没有 AppBar**：小程序页面占满整块屏幕（含状态栏下方），
    // 宿主在这个页面上**只**有一颗悬浮「更多」按钮。
    //
    // 为什么连标题都不要：小程序自己会画顶部导航（标题、返回、操作），
    // 宿主再显示一遍就是重复信息，而且用户刚点进来，本来就知道
    // 自己打开的是什么。宿主需要的信息与操作全在那一颗按钮里。
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
              child: LinearProgressIndicator(value: _progress),
            ),
          if (_pageError != null)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: ErrorView(
                title: '页面加载失败',
                message: _pageError!,
                detail: _session.fileUri ?? _session.localAsset,
                onRetry: _reload,
              ),
            ),
          // 右上角悬浮「更多」按钮。
          //
          // 为什么这么小：它是宿主的入口，不是页面的元素 —— 34dp 圆形按钮
          // 只在需要时被注意到，不需要时几乎透明。
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

  /// 加载中 / 资源错误时的简单外壳。
  ///
  /// 同样保留那个悬浮按钮：否则加载完成的一瞬间按钮会「跳」出来。
  /// 标题不再显示在界面上 —— 小程序自己会画；加载期间页面上也没有
  /// 别的地方需要它（用户刚点进来的，知道自己在开什么）。
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

  Widget _buildWebViewWidget(Map<String, dynamic> payload) {
    //
    // 入口选择（互斥，按优先级）：
    //
    //   1. 内置 asset → initialData 塞 HTML 字符串
    //   2. 已安装的包 → initialUrlRequest + file:// 地址
    //
    // ⚠ 这两条路的取舍是**用真机日志换来的**（0.6.1 → 0.6.2 白屏排查）：
    //
    //   * `initialFile` **绝对不能用**：它走 `Util.getUrlAsset()`，
    //     是 **Flutter asset 路径**语义（拼 file:///android_asset/flutter_assets/…）。
    //     传文件系统绝对路径必然 404，且只在 logcat 留一行
    //     "asset file cannot be found"。
    //
    //   * **内置 asset 用 initialData** 是 0.5 及之前一直在线上跑的路径，
    //     是唯一被验证过可用的。0.6.2 曾把它改成「释放成临时文件 + file://」，
    //     结果同样白屏（日志显示原生侧连 WebView 都没创建）—— 已回退。
    //
    //   * **本地包用 initialUrlRequest + file://**。它有真实的 origin，
    //     相对资源能解析；而「包 + UserScript」的组合还没有真机验证，
    //     如果后续发现 UserScript 在 file:// 下不执行，备选方案是
    //     `shouldOverrideUrlLoading` + `loadDataWithBaseURL` 注入。
    //
    // 共同前提（见 build 里的 guard）：数据必须在建 WebView 之前就绪 ——
    // `_webViewWidget ??= ...` 只执行一次，晚到的数据永远不会被用上。
    final String? assetHtml = _localHtml;
    final String? fileUri = _session.fileUri;

    lemonLog(
      'Miniapp',
      '构建 WebView：模式=${assetHtml != null ? "initialData(asset)" : fileUri != null ? "fileUrl" : "无入口"}'
      ' · html=${assetHtml == null ? "null" : "${assetHtml.length} 字符"}'
      ' · fileUri=$fileUri'
      ' · scripts=${_buildUserScripts(payload, _payloads).length}',
    );

    return InAppWebView(
      // 本地包：file:// 地址。**不要**用 initialFile（asset 语义，见上）。
      initialUrlRequest:
          fileUri == null ? null : URLRequest(url: WebUri(fileUri)),
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
        _buildUserScripts(payload, _payloads),
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        lemonLog('Miniapp', 'WebView 已创建');
        _onWebViewCreated(controller);
      },
      // ---------------------------------------------------------------- 权限
      // 网页请求摄像头 / 麦克风（getUserMedia）时，Chromium 会先走这里。
      // 我们把它的资源列表翻译成框架权限，逐项问用户，再回一个响应 ——
      // 采集本身完全交给 Chromium，宿主不写任何原生采集代码。
      //
      // 这个回调必须返回一个响应，否则请求会一直挂着（页面表现为
      // getUserMedia 永远 pending，摄像头黑屏且没有报错）。
      onPermissionRequest: (InAppWebViewController controller, PermissionRequest request) async {
        final WebPermissionAsk ask = WebPermissionAsk.from(request);

        // 我们不管理的资源（AUTOPLAY / GEOLOCATION …）：直接放行，
        // 让 Chromium 用它的默认行为，而不是因为不认识就把页面功能掐掉。
        if (ask.isUnmanaged) {
          return PermissionResponse(
            action: PermissionResponseAction.GRANT,
            resources: request.resources,
          );
        }

        final Set<MiniappPermission> granted =
            await PermissionPromptService.instance.ensureAll(
          _session.appId,
          ask.permissions,
          appName: _session.title,
        );

        // 第二层：Android 运行时权限。
        //
        // 顺序至关重要 —— 必须**先**拿到系统权限，再回 ALLOW。
        // WebView 不会替宿主申请系统权限，而 Chromium 真正开设备时
        // Android 还会拦一道；如果先回了 ALLOW 再去申请，用户会看到
        // 「弹窗点了允许，摄像头却打不开且没有报错」。
        //
        // 只在用户已经同意之后才去申请：否则会先弹系统的框、再弹我们的框，
        // 顺序反了，用户会觉得莫名其妙。
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
      // ------------------------------------------------------- 定位（另一条路）
      //
      // Android WebView 把定位权限从 onPermissionRequest 里**独立**出来了：
      // 网页调 navigator.geolocation 时走的是这个回调，不是上面那个。
      // 两个都要接，否则定位会静默失败（页面一直 pending）。
      //
      // 精度策略：Android 12+ 允许用户只给「大致位置」。我们先把
      // geolocationFine / Coarse 两项都问（用户在弹窗里二选一），
      // 然后按**实际同意的那档**去申请系统权限 —— 只同意大致时
      // 只申请 COARSE，系统的定位服务自己会把坐标模糊掉。
      onGeolocationPermissionsShowPrompt:
          (
            InAppWebViewController controller,
            String origin,
          ) async {
        final List<MiniappPermission> ask = WebPermissionAsk.forGeolocation();

        final Set<MiniappPermission> granted =
            await PermissionPromptService.instance.ensureAll(
          _session.appId,
          ask,
          appName: _session.title,
        );

        // 用户至少要给「大致位置」才算数；只给了精细而没给粗略是矛盾的，
        // 但 Android 上 FINE 隐含 COARSE，所以这里把 FINE 也当作已授权 COARSE。
        final bool allow = granted.contains(MiniappPermission.geolocationCoarse) ||
            granted.contains(MiniappPermission.geolocationFine);
        if (!allow) {
          await autotestLog('定位请求被拒绝：$origin');
          return GeolocationPermissionShowPromptResponse(
            origin: origin,
            allow: false,
            retain: false,
          );
        }

        // 系统层：只申请用户实际同意的那一档。
        // FINE 会隐含 COARSE（Android 规则），所以给了 FINE 就不必再要 COARSE。
        final List<String> runtime = <String>[
          if (granted.contains(MiniappPermission.geolocationFine))
            'android.permission.ACCESS_FINE_LOCATION'
          else
            'android.permission.ACCESS_COARSE_LOCATION',
        ];
        final bool systemOk =
            await NativeBridge.requestRuntimePermissions(runtime);
        await autotestLog(
          '定位请求：$origin → 应用内 ${granted.map((MiniappPermission p) => p.id).join(",")}'
          ' · 系统层 $runtime = $systemOk',
        );

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
          (InAppWebViewController controller, DownloadStartRequest request) async {
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
            final String text = '${message.messageLevel.name} ${message.message}';
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
      themeController: _themeController,
      session: _session,
      onSetTitle: (String title) {
        _titleOverridden = true;
        _session.titleNotifier.value = title;
      },
      onNavigateBack: _navigateBack,
      onRunInBackground: () => MiniappHost.instance.sendToBackground(_session.appId),
      onCloseMiniapp: () => MiniappHost.instance.close(_session.appId),
      moduleMethods: _moduleMethods,
    );

    JsBridge.attach(controller: controller, api: api);
    lemonLog(
      'Miniapp',
      '打开小程序 ${_session.appId}：${_session.entry}',
    );
  }

  /// JSBridge 的 lemonlite.navigateBack()
  /// 语义：先按小程序内部历史返回，退无可退时**转后台运行**（而不是直接销毁）
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

  /// 加载完成后探一次页面实际状态，把结果写进日志。
  ///
  /// 为什么需要它：白屏有两种完全不同的原因，光看「有没有报错」分不出来 ——
  ///   * 页面根本没加载（URL 错 / 404）→ body 是空的
  ///   * 页面加载了但内容没渲染（脚本报错 / CSS 全白 / 高度 0）→
  ///     body 有子节点但可视高度是 0
  /// 所以这里直接问 WebView：文档标题、body 子节点数、body 尺寸、
  /// 以及 SDK 有没有装上。四条一起看，基本能定位。
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

  /// 悬浮条菜单的总入口：会话类动作与「查看信息」类动作都在这里分发。
  ///
  /// 会话类（关闭 / 后台 / 权限 / 后台应用）会让当前 widget 可能已被销毁，
  /// 所以每个 await 之前都要判断 mounted —— 之前那版直接把
  /// `_FloatingHostMenu` 的 onSelected 与 AppBar 的 onSelected 分成两套，
  /// 结果加菜单项时很容易漏掉一边。
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

/// 右下角的悬浮「更多」按钮。
///
/// 为什么只有一颗按钮、没有标题栏：
///   小程序自己通常已经画了顶部导航（标题、返回、操作）。宿主再压一条
///   标题栏就是两条，既浪费纵向空间又很怪；而只放一个图标按钮时，
///   页面上几乎没有「这是宿主画的」痕迹，需要时又随时够得着。
///
/// 为什么在右上角：这是宿主「回宿主界面」的入口，和系统返回、
/// 页面标题在同一个视觉区（顶部），用户找它不会去屏幕底下找。
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
        itemBuilder: (BuildContext c) => <PopupMenuEntry<_HostMenuAction>>[
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
            child: _menuRow(context, Icons.close, '关闭', danger: true),
          ),
          PopupMenuItem<_HostMenuAction>(
            value: _HostMenuAction.background,
            child: _menuRow(context, Icons.play_circle_outline, '后台运行'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<_HostMenuAction>(
            value: _HostMenuAction.permissions,
            child: _menuRow(context, Icons.verified_user_outlined, '权限管理'),
          ),
          PopupMenuItem<_HostMenuAction>(
            value: _HostMenuAction.backgroundApps,
            child: _menuRow(context, Icons.layers_outlined, '后台应用'),
          ),
        ],
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


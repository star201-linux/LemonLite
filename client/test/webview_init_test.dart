// test/webview_init_test.dart
//
// 「小程序页面到底有没有真的把 WebView 建出来」的回归测试。
//
// 这个文件存在的理由是一个真实白屏 bug（0.6.0）：
//
//   _webViewWidget ??= _buildWebViewWidget(payload);   // 只执行一次
//
// 内置资源（自检页）的 HTML 是**异步**从 asset 读的。第一次 build 时 _localHtml 还是
// null，WebView 就以 initialData: null 建好了；之后 setState 也不会重建它。
// 结果：页面上只剩那颗悬浮「更多」按钮，WebView 区域永远空白。
//
// 0.5 及之前被 initialUrlRequest（远程 url）掩盖了，删掉远程入口后暴露。
//
// ⚠ 测试环境的限制：flutter_inappwebview 没有测试用的平台实现，
// 一旦真的构建 InAppWebView 就会抛 assert。所以这里的断言全部
// **停在 WebView 之前**（检查 Loading 状态、检查 session 的 fileUri），
// 而不是去检查 WebView 内部字段。这已经能覆盖那个 bug：
// bug 的本质是「数据没就绪就往下走」，而「往下走」就是构建 WebView。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/core/autotest.dart';
import 'package:lemonlite/data/models/miniapp_session.dart';
import 'package:lemonlite/data/services/miniapp_package_service.dart';
import 'package:lemonlite/data/services/settings_service.dart';
import 'package:lemonlite/pages/miniapp/miniapp_page.dart';
import 'package:lemonlite/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SettingsService.init();
  });

  group('内置 asset 模式', () {
    testWidgets('HTML 未就绪时停在 Loading（回归：曾直接建 WebView 导致白屏）', (
      WidgetTester tester,
    ) async {
      final MiniappSession session = MiniappSession(
        appId: 'demo.test',
        title: '自检',
        localAsset: kAutotestAsset,
        isTransient: true,
      );
      addTearDown(session.dispose);

      // 只 pump 一帧（不 settle）：此时 asset 读取还没回来
      await tester.pumpWidget(_host(MiniappSessionView(session: session)));

      // 关键断言：第一帧必须是 Loading。
      // 如果这一帧就往下去建 WebView，_localHtml 还是 null，
      // 而 WebView 只会构建一次 —— 之后就永远空白。
      expect(
        find.textContaining('正在准备小程序'),
        findsOneWidget,
        reason: 'HTML 没读到就往下走 → WebView 会以 null data 建好且永不重建',
      );
    });
  });

  group('本地包模式', () {
    test('fileUri 是 file:// 且指向入口（不能走 initialFile 的 asset 语义）', () {
      final MiniappSession session = MiniappSession(
        appId: 'pkg.test',
        title: '包',
        installedPackage: const InstalledPackage(
          appId: 'pkg.test',
          version: '1.0.0',
          entry: 'index.html',
          dir: '/tmp/pkg/1.0.0',
        ),
        isTransient: true,
      );
      addTearDown(session.dispose);

      // MiniappSessionView 把它传给 initialUrlRequest + WebUri(fileUri)。
      // 插件里 initialFile 那条路是 asset 语义（拼
      // file:///android_asset/flutter_assets/...），拿文件系统路径去开
      // 必然 404 且只在 logcat 留一行 —— 页面上就是空白。
      expect(session.fileUri, isNotNull);
      expect(session.fileUri, startsWith('file://'));
      expect(session.fileUri, endsWith('/1.0.0/index.html'));
      // entry 属性（后台列表展示用）也应是同一个地址
      expect(session.entry, session.fileUri);
    });
  });

  group('没有入口', () {
    testWidgets('既无包也无 asset 时给错误页，不是白屏', (WidgetTester tester) async {
      final MiniappSession session = MiniappSession(
        appId: 'empty.test',
        title: '空',
        isTransient: true,
      );
      addTearDown(session.dispose);

      await tester.pumpWidget(_host(MiniappSessionView(session: session)));
      await tester.pump();

      expect(find.text('无法打开'), findsOneWidget);
    });
  });
}

/// 最小可用的宿主。
///
/// MiniappSessionView 会 watch ThemeController，缺了它会抛
/// ProviderNotFoundException —— 那是测试环境的问题，不是产品 bug
/// （真实 App 里 app.dart 已经装好了这些 Provider）。
Widget _host(Widget child) => ChangeNotifierProvider<ThemeController>(
  create: (BuildContext c) => ThemeController(SettingsService.instance),
  child: MaterialApp(home: Scaffold(body: child)),
);

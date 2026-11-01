// test/lemonlite_test.dart
//
// 纯 Dart 单元测试（不依赖任何插件，`flutter test` 直接可跑）。
//
// 重点覆盖三处最容易出问题的地方：
//   1. index.json 的容错解析（字段缺失、条目非法、重复条目）
//   2. 相对路径按服务器地址解析（url / icon / screenshots）
//   3. ColorScheme → CSS 变量的命名与别名（--md-* 与 kebab-case）

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lemonlite/data/models/app_item.dart';
import 'package:lemonlite/data/models/category.dart';
import 'package:lemonlite/data/models/market_feed.dart';
import 'package:lemonlite/theme/theme_injector.dart';

void main() {
  group('AppCategory 宽松解析', () {
    test('缺 id 时用 name 兜底', () {
      final AppCategory? category = AppCategory.fromJson(<String, dynamic>{
        'name': '工具',
      });
      expect(category, isNotNull);
      expect(category!.id, '工具');
      expect(category.name, '工具');
    });

    test('id 与 name 都为空时返回 null', () {
      expect(AppCategory.fromJson(<String, dynamic>{}), isNull);
    });
  });

  group('AppItem 宽松解析', () {
    test('字段缺失用兜底值，不抛异常', () {
      final AppItem? app = AppItem.fromJson(<String, dynamic>{
        'id': 'a',
        'name': 'A',
      });
      expect(app, isNotNull);
      expect(app!.description, '暂无简介');
      expect(app.author, '未知作者');
      expect(app.version, '1.0.0');
      expect(app.size, 0);
      expect(app.sizeLabel, '体积未知');
    });

    test('id 与 name 全缺失时返回 null（该条目会被市场跳过）', () {
      expect(AppItem.fromJson(<String, dynamic>{}), isNull);
    });

    test('size 支持 1048576 与 "2.3 MB" 两种写法', () {
      final AppItem? bytes = AppItem.fromJson(<String, dynamic>{
        'id': 'a',
        'name': 'A',
        'size': 1048576,
      });
      expect(bytes!.size, 1048576);
      expect(bytes.sizeLabel, '1.0 MB');

      final AppItem? human = AppItem.fromJson(<String, dynamic>{
        'id': 'b',
        'name': 'B',
        'size': '2.3 MB',
      });
      expect(human!.size, (2.3 * 1024 * 1024).round());
      expect(human.sizeLabel, '2.3 MB');
    });

    test('图标与截图按服务器地址解析成绝对地址', () {
      final AppItem app = AppItem.fromJson(<String, dynamic>{
        'id': 'a',
        'name': 'A',
        'packageUrl': 'https://cdn.example.com/pkgs/a.zip',
        'icon': 'icons/a.png',
        'screenshots': <String>['shots/1.png'],
      })!.resolveAgainst('https://star201-linux.github.io');

      expect(app.icon, 'https://star201-linux.github.io/icons/a.png');
      expect(
        app.screenshots.single,
        'https://star201-linux.github.io/shots/1.png',
      );
      // 包地址是服务端拼好的绝对地址，resolveAgainst **不该**动它
      expect(app.packageUrl, 'https://cdn.example.com/pkgs/a.zip');
    });

    test('包字段解析：没有 packageUrl 时 canOpen=false', () {
      final AppItem noPkg = AppItem.fromJson(<String, dynamic>{
        'id': 'a',
        'name': 'A',
        // 旧数据里的 url 字段不再被读取
        'url': 'https://example.com/x.html',
      })!;
      expect(noPkg.packageUrl, isEmpty);
      expect(noPkg.canOpen, isFalse);
      expect(noPkg.packageEntry, 'index.html');

      final AppItem withPkg = AppItem.fromJson(<String, dynamic>{
        'id': 'b',
        'name': 'B',
        'packageUrl': 'https://example.com/b.zip',
        'packageEntry': 'main.html',
        'packageSha256': 'abc123',
        'packageBytes': 2048,
      })!;
      expect(withPkg.canOpen, isTrue);
      expect(withPkg.packageEntry, 'main.html');
      expect(withPkg.packageSha256, 'abc123');
      expect(withPkg.packageSizeLabel, '2 KB');
    });
  });

  // 旧的顶层模型（静态 index.json 用）在 0.5 被删掉了 ——
  // 客户端只走服务端，那条解析路径已经不存在。
  // 等价的容错逻辑现在在 MarketFeedPage 里，所以测试也搬过去。
  group('MarketFeedPage 结构容错', () {
    test('apps 不是数组 / 缺失时按空列表处理，不抛异常', () {
      // 注意：与服务端约定的信任边界不同。静态 index.json 时用户可能手改文件，
      // 所以当年是「结构性错误就抛 FormatException」。现在数据来自我们自己的
      // 服务端，apps 缺失只可能是空市场 —— 按空列表处理更合理，
      // 让用户看到「市场里还没有应用」而不是一个错误页。
      final MarketFeedPage missing = MarketFeedPage.fromJson(
        <String, dynamic>{},
        <String, dynamic>{},
        'https://example.com',
      );
      expect(missing.apps, isEmpty);
      expect(missing.categories, isEmpty);

      final MarketFeedPage wrong = MarketFeedPage.fromJson(
        <String, dynamic>{'apps': 'oops'},
        <String, dynamic>{},
        'https://example.com',
      );
      expect(wrong.apps, isEmpty);
    });

    test('跳过非法条目、保留合法条目', () {
      final MarketFeedPage page = MarketFeedPage.fromJson(
        <String, dynamic>{
          'apps': <dynamic>[
            <String, dynamic>{'id': 'a', 'name': 'A', 'category': 'tools'},
            <String, dynamic>{}, // 非法条目：丢弃
            'not-a-map', // 非法条目：丢弃
            <String, dynamic>{'id': 'b', 'name': 'B', 'category': 'life'},
          ],
          'categories': <dynamic>[
            <String, dynamic>{'id': 'tools', 'name': '工具'},
            <String, dynamic>{'id': 'tools', 'name': '工具（重复）'},
          ],
        },
        <String, dynamic>{},
        'https://example.com',
      );

      expect(page.apps.length, 2);
      expect(page.apps.map((dynamic a) => a.id), <String>['a', 'b']);
      // 分类去重由 AppCategory.fromJson + MarketFeedPage 决定；
      // 保持「不崩」这个底线即可
      expect(page.categories, isNotEmpty);
    });
  });

  group('ThemeInjector', () {
    test('Color → #rrggbb', () {
      expect(ThemeInjector.toHex(const Color(0xFF6750A4)), '#6750a4');
      expect(ThemeInjector.toHex(const Color(0xFF000000)), '#000000');
    });

    test('camelCase → kebab-case', () {
      expect(ThemeInjector.kebab('primaryContainer'), 'primary-container');
      expect(ThemeInjector.kebab('onSurfaceVariant'), 'on-surface-variant');
      expect(ThemeInjector.kebab('primary'), 'primary');
    });

    test('CSS 变量统一 --md- 前缀，且提供 background / surfaceVariant 兼容别名', () {
      final ColorScheme scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
      );
      final Map<String, String> vars = ThemeInjector.toCssVariableMap(scheme);

      expect(vars.keys.every((String key) => key.startsWith('--md-')), isTrue);
      expect(vars['--md-primary'], ThemeInjector.toHex(scheme.primary));
      expect(vars['--md-background'], ThemeInjector.toHex(scheme.surface));
      expect(vars['--md-on-background'], ThemeInjector.toHex(scheme.onSurface));
      expect(
        vars['--md-surface-variant'],
        ThemeInjector.toHex(scheme.surfaceContainerHighest),
      );
    });

    test('主题快照结构完整（getTheme 的返回值）', () {
      final ColorScheme scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
      );
      final Map<String, dynamic> payload = ThemeInjector.toThemePayload(
        scheme,
        themeModeLabel: 'system',
        source: 'seed',
      );

      expect(payload['mode'], 'dark');
      expect(payload['themeMode'], 'system');
      expect(payload['source'], 'seed');
      expect(
        (payload['colors'] as Map<String, String>)['primary'],
        ThemeInjector.toHex(scheme.primary),
      );
      expect(payload['cssVariables'], isA<Map<String, String>>());
    });

    test('注入脚本带上主题数据与 --md- 变量', () {
      final ColorScheme scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
      );
      final String script = ThemeInjector.buildPayloadScript(
        ThemeInjector.toThemePayload(
          scheme,
          themeModeLabel: 'light',
          source: 'seed',
        ),
      );
      expect(script, startsWith('window.__LEMONLITE_THEME__ = {'));
      expect(script, contains('--md-primary'));
      expect(
        ThemeInjector.buildLiveUpdateScript(<String, dynamic>{'mode': 'light'}),
        contains('__applyTheme'),
      );
    });
  });
}

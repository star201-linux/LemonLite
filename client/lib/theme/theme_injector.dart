// lib/theme/theme_injector.dart
//
// 把 Flutter 的 ColorScheme「翻译」成注入到 WebView 的 CSS 变量与主题快照。
//
// 这是阶段一「主题继承」的关键：小程序页面里只要写
//     background: var(--md-surface); color: var(--md-on-surface);
// 就自动跟随用户当前的 MD3 主题；小程序若想自定义主题，
// 直接在自己的 <style> 里覆盖同名变量即可，框架不强制。
//
// 为了实现后半句，注入**不能**写 <html> 的行内 style（优先级高于任何选择器，
// 页面就再也覆盖不掉了，连自己的黑白切换都会失效）。注入只写一条
// `:root{...}` 样式表并插在 head 最前，页面样式表排在后面 → 同优先级下页面胜。
// 详见 injected_js.dart 的 applyTheme。
//
// 变量命名统一 `--md-*` 前缀，*全部* 由 ColorScheme 推导，Dart 侧不存在硬编码色值。
// 注意：真正「把变量写进页面」的动作在 bridge/injected_js.dart 的 JS SDK 里
// （`window.lemonlite.__applyTheme`），本文件只负责生成数据。

import 'dart:convert';

import 'package:flutter/material.dart';

class ThemeInjector {
  const ThemeInjector._();

  /// ColorScheme → 颜色角色表（camelCase key）。
  ///
  /// 兼容性别名：
  /// * M3 里 `background/onBackground` 已并入 `surface/onSurface`，
  ///   这里保留别名，让老小程序写 `var(--md-background)` 依然可用；
  /// * `surfaceVariant` 语义上等价于 `surfaceContainerHighest`，
  ///   用别名可以避免触发 Flutter 的弃用告警。
  static Map<String, Color> colorRoles(ColorScheme s) => <String, Color>{
        'primary': s.primary,
        'onPrimary': s.onPrimary,
        'primaryContainer': s.primaryContainer,
        'onPrimaryContainer': s.onPrimaryContainer,
        'secondary': s.secondary,
        'onSecondary': s.onSecondary,
        'secondaryContainer': s.secondaryContainer,
        'onSecondaryContainer': s.onSecondaryContainer,
        'tertiary': s.tertiary,
        'onTertiary': s.onTertiary,
        'tertiaryContainer': s.tertiaryContainer,
        'onTertiaryContainer': s.onTertiaryContainer,
        'error': s.error,
        'onError': s.onError,
        'errorContainer': s.errorContainer,
        'onErrorContainer': s.onErrorContainer,
        'surface': s.surface,
        'onSurface': s.onSurface,
        'surfaceDim': s.surfaceDim,
        'surfaceBright': s.surfaceBright,
        'surfaceContainerLowest': s.surfaceContainerLowest,
        'surfaceContainerLow': s.surfaceContainerLow,
        'surfaceContainer': s.surfaceContainer,
        'surfaceContainerHigh': s.surfaceContainerHigh,
        'surfaceContainerHighest': s.surfaceContainerHighest,
        'onSurfaceVariant': s.onSurfaceVariant,
        'surfaceVariant': s.surfaceContainerHighest,
        'background': s.surface,
        'onBackground': s.onSurface,
        'outline': s.outline,
        'outlineVariant': s.outlineVariant,
        'shadow': s.shadow,
        'scrim': s.scrim,
        'inverseSurface': s.inverseSurface,
        // 注意：Flutter 3.47 里这个 getter 叫 onInverseSurface（早期版本是 inverseOnSurface）
        'onInverseSurface': s.onInverseSurface,
        'inversePrimary': s.inversePrimary,
      };

  /// camelCase → kebab-case：`primaryContainer` → `primary-container`
  static String kebab(String camelCase) => camelCase.replaceAllMapped(
        RegExp('[A-Z]'),
        (Match m) => '-${m.group(0)!.toLowerCase()}',
      );

  /// Color → `#rrggbb`（丢掉 alpha）。给需要「纯色值」的地方用
  /// （`primaryColor` / `seedColor` / 原生任务卡图标）。
  static String toHex(Color color) {
    final int argb = color.toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  /// Color → CSS 颜色。**保留 alpha**。
  ///
  /// 为什么不能一律 `#rrggbb`：`ColorScheme.scrim` 是纯黑色，而网页里
  /// `--md-scrim` 的用法是 `background: var(--md-scrim)` 铺一层遮罩。
  /// 把 alpha 丢掉 = 遮罩变成纯黑不透明 —— 弹层一开，整页变黑，
  /// 看起来像「小程序崩了」。这类问题在小程序作者那边完全无法自查。
  static String toCss(Color color) {
    final int argb = color.toARGB32();
    final int a = (argb >> 24) & 0xFF;
    if (a == 0xFF) return toHex(color);
    final int r = (argb >> 16) & 0xFF;
    final int g = (argb >> 8) & 0xFF;
    final int b = argb & 0xFF;
    return 'rgba($r, $g, $b, ${(a / 255).toStringAsFixed(3)})';
  }

  /// 遮罩层的不透明度。
  ///
  /// M3 里 scrim 色值本身是纯黑，「多黑」由使用方决定；网页生态里
  /// 普遍写成 `rgba(0,0,0,.32)`（Material Web 的 barrier 就是这个值）。
  /// 这里直接把 `--md-scrim` 变成**带 alpha 的遮罩色**，让
  /// `background: var(--md-scrim)` 这种最自然的写法得到正确结果；
  /// 想要纯色的用 `--md-scrim-solid`。
  static const double scrimOpacity = 0.32;

  /// `{ '--md-primary': '#6750a4', ... }`
  static Map<String, String> toCssVariableMap(ColorScheme s) {
    final Map<String, String> result = <String, String>{};
    colorRoles(s).forEach((String role, Color color) {
      result['--md-${kebab(role)}'] = toCss(color);
    });
    final Color scrim = s.scrim.withValues(alpha: scrimOpacity);
    result['--md-scrim'] = toCss(scrim);
    result['--md-scrim-solid'] = toCss(s.scrim);
    return result;
  }

  /// 高度（阴影）令牌。
  ///
  /// 交给宿主提供的原因：暗色下**纯黑阴影就是一圈黑边**。小程序作者通常
  /// 在 `:root` 里写死 `0 2px 6px rgba(0,0,0,.25)`，切到暗色时那张卡片
  /// 周围会出现一圈比背景更黑的描边 —— 看起来像「只有部分卡片变黑了」。
  ///
  /// M3 的做法是：暗色下不用阴影表达高度，改用更亮的 surface 容器。
  /// 所以这里暗色直接给 `none`，让卡片靠 `--md-surface-container-*` 分层。
  static Map<String, String> elevationVariables(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return const <String, String>{
        '--md-elevation-0': 'none',
        '--md-elevation-1': 'none',
        '--md-elevation-2': 'none',
        '--md-elevation-3': 'none',
      };
    }
    return const <String, String>{
      '--md-elevation-0': 'none',
      '--md-elevation-1': '0 1px 2px rgba(0, 0, 0, 0.10), 0 1px 3px 1px rgba(0, 0, 0, 0.06)',
      '--md-elevation-2': '0 2px 6px rgba(0, 0, 0, 0.10), 0 1px 2px rgba(0, 0, 0, 0.08)',
      '--md-elevation-3': '0 4px 10px rgba(0, 0, 0, 0.10), 0 2px 4px rgba(0, 0, 0, 0.08)',
    };
  }

  /// 完整的 `:root { ... }` 文本。
  /// 用法：小程序作者可以把它贴进自己的样式表，作为「跟随主题」的静态兜底。
  static String buildCssText(ColorScheme s) {
    final StringBuffer buffer = StringBuffer('/* 由 LemonLite 由当前 MD3 主题生成 */\n:root {\n');
    toCssVariableMap(s).forEach((String name, String value) {
      buffer.writeln('  $name: $value;');
    });
    buffer.writeln('}');
    return buffer.toString();
  }

  /// 主题快照：既是 `lemonlite.getTheme()` 的返回值，也是注入脚本的载荷。
  ///
  /// 结构：
  /// ```json
  /// {
  ///   "mode": "dark",              // 实际生效的亮度
  ///   "themeMode": "system",       // 用户设置：system / light / dark
  ///   "source": "dynamic",         // dynamic（系统壁纸色） / seed（手动种子色）
  ///   "seedColor": "#6750a4",
  ///   "colors": { "primary": "#d0bcff", ... },          // 不带前缀，方便 JS 直接取
  ///   "cssVariables": { "--md-primary": "#d0bcff", ... } // 可直接 setProperty
  /// }
  /// ```
  static Map<String, dynamic> toThemePayload(
    ColorScheme s, {
    required String themeModeLabel,
    required String source,
  }) {
    final Map<String, String> colors = toCssVariableMap(s);
    final Map<String, String> vars = <String, String>{
      ...colors,
      // 非颜色令牌（阴影）也走同一份 cssVariables，页面侧只认一个来源
      ...elevationVariables(s.brightness),
    };
    final Map<String, String> colorOnly = <String, String>{};
    colors.forEach((String name, String value) {
      colorOnly[name.replaceFirst('--md-', '')] = value;
    });
    return <String, dynamic>{
      'mode': s.brightness == Brightness.dark ? 'dark' : 'light',
      'themeMode': themeModeLabel,
      'source': source,
      'seedColor': toHex(s.primary),
      'colors': colorOnly,
      'cssVariables': vars,
    };
  }

  /// document-start 注入的第一段脚本：**只放数据**，逻辑在 JS SDK 里。
  /// 先注入数据、再注入 SDK，SDK 初始化末尾会读取并应用这份数据。
  static String buildPayloadScript(Map<String, dynamic> payload) =>
      'window.__LEMONLITE_THEME__ = ${jsonEncode(payload)};';

  /// 主题热更新脚本：页面已经在运行时用户切了主题，用 evaluateJavascript 调用。
  static String buildLiveUpdateScript(Map<String, dynamic> payload) =>
      '(window.lemonlite && window.lemonlite.__applyTheme)'
      ' ? window.lemonlite.__applyTheme(${jsonEncode(payload)})'
      ' : void 0;';
}

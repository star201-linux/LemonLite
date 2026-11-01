// lib/theme/theme_injector.dart
//
// 把 Flutter 的 ColorScheme「翻译」成注入到 WebView 的 CSS 变量与主题快照。
//
// 这是阶段一「主题继承」的关键：小程序页面里只要写
//     background: var(--md-surface); color: var(--md-on-surface);
// 就自动跟随用户当前的 MD3 主题；小程序若想自定义主题，
// 直接在自己的 <style> 里覆盖同名变量即可，框架不强制。
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

  /// Color → `#rrggbb`（CSS 变量里不需要 alpha，M3 的颜色角色都是不透明色）
  static String toHex(Color color) {
    final int argb = color.toARGB32();
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }

  /// `{ '--md-primary': '#6750a4', ... }`
  static Map<String, String> toCssVariableMap(ColorScheme s) {
    final Map<String, String> result = <String, String>{};
    colorRoles(s).forEach((String role, Color color) {
      result['--md-${kebab(role)}'] = toHex(color);
    });
    return result;
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
    final Map<String, String> vars = toCssVariableMap(s);
    final Map<String, String> colors = <String, String>{};
    vars.forEach((String name, String value) {
      colors[name.replaceFirst('--md-', '')] = value;
    });
    return <String, dynamic>{
      'mode': s.brightness == Brightness.dark ? 'dark' : 'light',
      'themeMode': themeModeLabel,
      'source': source,
      'seedColor': toHex(s.primary),
      'colors': colors,
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

// lib/theme/theme_controller.dart
//
// 主题状态中心：主题模式 / 种子色 / 动态取色 / 当前生效的 ColorScheme。
//
// 与 SettingsService 的分工：
// * SettingsService —— 只负责「持久化」（读写 SharedPreferences）
// * ThemeController —— 负责「主题语义」：把三项偏好合成为最终 ColorScheme，
//   并提供给 WebView 注入用的一致快照（保证宿主与小程序的配色永远同源）

import 'package:flutter/material.dart';

import '../core/globals.dart';
import '../data/services/settings_service.dart';
import 'app_theme.dart';
import 'theme_injector.dart';

class ThemeController extends ChangeNotifier {
  ThemeController(this._settings) {
    // 设置一变（种子色/模式/动态取色开关），主题跟着变
    _settings.addListener(notifyListeners);
  }

  final SettingsService _settings;

  ColorScheme? _dynamicLight;
  ColorScheme? _dynamicDark;
  bool _dynamicAvailable = false;

  /// 当前是否真的拿到了系统壁纸色（Android 12+ 才有）
  bool get dynamicColorAvailable => _dynamicAvailable;

  bool get useDynamicColor => _settings.useDynamicColor;

  @override
  void dispose() {
    _settings.removeListener(notifyListeners);
    super.dispose();
  }

  // ------------------------------------------------------- 对外只读属性

  ThemeMode get themeMode => _settings.themeMode;

  Color get seedColor => _settings.seedColor;

  /// 传给小程序的 `themeMode` 字段：system / light / dark
  String get themeModeLabel => switch (themeMode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  /// 配色来源：dynamic（系统壁纸色）/ seed（手动种子色）
  String get sourceLabel =>
      (useDynamicColor && _dynamicAvailable) ? 'dynamic' : 'seed';

  // ------------------------------------------------------- 动态取色接入

  /// 由 App 根部的 `DynamicColorBuilder` 回调写入。
  ///
  /// 这里刻意**不**调用 notifyListeners：调用点位于 build 期间，
  /// 而 DynamicColorBuilder 自身重建时 MaterialApp 已经会用新配色重新构建，
  /// 再通知一次反而会触发「build 期间 setState」。
  void updateDynamicSchemes(ColorScheme? light, ColorScheme? dark) {
    _dynamicLight = light;
    _dynamicDark = dark;
    _dynamicAvailable = light != null || dark != null;
  }

  // ------------------------------------------------------- 生成主题

  /// 指定亮度下的最终配色
  ColorScheme schemeFor(Brightness brightness) => AppTheme.buildScheme(
        brightness: brightness,
        seed: seedColor,
        dynamicScheme: useDynamicColor
            ? (brightness == Brightness.dark ? _dynamicDark : _dynamicLight)
            : null,
      );

  ThemeData themeFor(Brightness brightness) => AppTheme.buildTheme(schemeFor(brightness));

  /// 当前真实生效的配色。
  /// 优先从 Widget 树里取（那里已经包含了动态取色的结果、以及系统亮暗的最终裁决），
  /// 拿不到 context 时再按设置自行推导。
  ColorScheme effectiveScheme() {
    final ColorScheme? fromTree = currentColorScheme;
    if (fromTree != null) return fromTree;
    return schemeFor(_fallbackBrightness());
  }

  /// 当前主题快照（getTheme 的返回值 / WebView 注入载荷）
  Map<String, dynamic> themeSnapshot() => ThemeInjector.toThemePayload(
        effectiveScheme(),
        themeModeLabel: themeModeLabel,
        source: sourceLabel,
      );

  Brightness _fallbackBrightness() {
    switch (themeMode) {
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  // ------------------------------------------------------- 写入偏好

  Future<void> setThemeMode(ThemeMode mode) => _settings.setThemeMode(mode);

  /// 手动选主色：会自动关闭动态取色，
  /// 否则用户点了色块却看不到变化（动态色优先级更高），那才是真的困惑。
  Future<void> setSeedColor(Color color) async {
    if (useDynamicColor && _dynamicAvailable) {
      await _settings.setUseDynamicColor(false);
    }
    await _settings.setSeedColor(color);
  }

  Future<void> setUseDynamicColor(bool value) => _settings.setUseDynamicColor(value);
}

// lib/pages/settings/settings_page.dart
//
// 设置页：
//   * 外观：主题模式（跟随系统 / 浅色 / 深色）、动态取色、手动主色
//   * 市场：当前服务器地址、上次同步时间
//   * 关于：版本号 —— **连点 8 次进入开发者模式**（验收标准第 4 条）
//
// 连点实现细节：
//   两次点击间隔超过 2 秒就重置计数，避免「一天点 8 次也能解锁」；
//   **整个过程完全静默**：不弹任何提示，界面上也不写解锁方式 ——
//   隐藏入口一旦自我说明就不是隐藏入口了（需要时看 README「开发者模式」一节）。
//   解锁后设置页才会多出「开发者选项」，这本身就是唯一的反馈。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/globals.dart';
import '../../data/models/bundle_manifest.dart';
import '../../data/models/json_utils.dart';
import '../../data/services/account_service.dart';
import '../../data/services/settings_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';
import '../home/home_controller.dart';
import '../account/account_page.dart';
import '../permissions/permission_controller_page.dart';
import '../storage/storage_page.dart';
import 'bundles_page.dart';
import 'developer_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 进入开发者模式需要的点击次数
  static const int _tapsToUnlock = 8;

  /// 两次点击的最大间隔，超过就重新计数
  static const Duration _tapResetWindow = Duration(seconds: 2);

  int _versionTapCount = 0;
  DateTime? _lastVersionTapAt;

  @override
  Widget build(BuildContext context) {
    final SettingsService settings = context.watch<SettingsService>();
    final ThemeController theme = context.watch<ThemeController>();
    final HomeController home = context.watch<HomeController>();
    final AccountService account = context.watch<AccountService>();
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          // ------------------------------ 外观 ------------------------------
          _section(context, '外观', <Widget>[
            _themeModeSelector(context, theme),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome_outlined),
              title: const Text('动态取色（Monet）'),
              subtitle: Text(
                theme.dynamicColorAvailable
                    ? '使用系统壁纸色生成整套 MD3 配色'
                    : '当前设备不支持（需要 Android 12+ 且系统提供壁纸色）',
              ),
              value: theme.useDynamicColor && theme.dynamicColorAvailable,
              onChanged: theme.dynamicColorAvailable
                  ? (bool value) => theme.setUseDynamicColor(value)
                  : null,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _seedColorPicker(context, theme),
          ]),

          // ------------------------------ 账号 ------------------------------
          // 未登录也显示这一行：它本身就是「去登录」的入口，
          // 藏起来会让用户以为这个 App 没有账号系统。
          _section(context, '账号', <Widget>[
            ListTile(
              leading: account.isLoggedIn
                  ? const Icon(Icons.account_circle)
                  : const Icon(Icons.account_circle_outlined),
              title: Text(account.isLoggedIn ? '账号管理' : '登录 / 注册'),
              subtitle: Text(
                account.isLoggedIn
                    ? '${account.profile?.username ?? ''} · ${account.profile?.email ?? ''}'
                    : '登录后可在设备间同步资料与头像；不登录也能正常使用',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(AccountPage.route()),
            ),
          ]),

          // ------------------------------ 权限 ------------------------------
          // 权限管理与「应用管理」共用同一份应用清单：这里进去看到的应用，
          // 就是底部「应用管理」里那些。要增删应用请去应用管理。
          _section(context, '权限', <Widget>[
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('权限管理'),
              subtitle: const Text('摄像头、麦克风、管理所有文件；按应用逐个设置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(PermissionControllerPage.route()),
            ),
          ]),

          // ------------------------------ 存储 ------------------------------
          _section(context, '存储', <Widget>[
            ListTile(
              leading: const Icon(Icons.sd_storage_outlined),
              title: const Text('存储占用'),
              subtitle: const Text('查看并管理单个应用的键值与文件数据'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context).push(StoragePage.route()),
            ),
          ]),

          // ------------------------------ 市场 ------------------------------
          // 「市场服务器」只在开发者模式下出现：它展示的是「数据从哪来」这种
          // 可配置项，对普通用户没有意义，留着就是个「这里好像能改点什么」的暗示。
          // 未解锁时这一整行不渲染，做到字面意义上的「看不出任何开发者相关的东西」。
          _section(context, '市场', <Widget>[
            if (settings.developerMode) ...<Widget>[
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('市场服务器'),
                subtitle: Text(settings.serverUrl),
                trailing: settings.isCustomServer
                    ? Chip(
                        label: const Text('自定义'),
                        labelStyle: Theme.of(context).textTheme.labelSmall,
                        visualDensity: VisualDensity.compact,
                        side: BorderSide(color: scheme.outlineVariant),
                      )
                    : null,
                onTap: () => _openDeveloperPage(context),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
            ],
            ListTile(
              leading: const Icon(Icons.sync_outlined),
              title: const Text('上次同步'),
              subtitle: Text(
                settings.lastSyncAt == null
                    ? '还没有成功同步过'
                    : '${formatDateTimeLabel(settings.lastSyncAt)}'
                          '${home.hasData ? ' · 已加载 ${home.loadedCount} 个应用' : ''}',
              ),
              trailing: IconButton(
                tooltip: '立即刷新',
                icon: const Icon(Icons.refresh),
                onPressed: home.isLoading ? null : home.load,
              ),
            ),
          ]),

          _section(context, '页面扩展', <Widget>[
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('页面扩展'),
              subtitle: const Text('从 ZIP 导入页面脚本与样式'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(BundlesPage.route(BundleType.extension)),
            ),
          ]),

          // ------------------------------ 关于 ------------------------------
          _section(context, '关于', <Widget>[
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text(kFrameworkName),
              subtitle: Text(
                '应用版本 ${AppInfo.versionLabel}\n'
                '框架版本 $kFrameworkVersion',
              ),
              isThreeLine: false,
              trailing: settings.developerMode
                  ? Icon(Icons.build_circle_outlined, color: scheme.primary)
                  : null,
              onTap: () => _onVersionTap(settings),
            ),
            // 示例小程序的测试入口收进了「开发者选项 → 小程序测试」二级菜单，
            // 设置页不再直接放会启动 WebView 的入口。
            if (settings.developerMode) ...<Widget>[
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.developer_mode_outlined),
                title: const Text('开发者选项'),
                subtitle: const Text('自定义服务器地址、重置、查看运行时信息'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openDeveloperPage(context),
              ),
            ],
          ]),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              '第一阶段只做 WebView 承载 + JSBridge：不做原生渲染，也不做小程序包下载安装。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 子组件

  /// 分组卡片
  Widget _section(BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget _themeModeSelector(BuildContext context, ThemeController theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('主题模式', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const <ButtonSegment<ThemeMode>>[
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.light,
                  label: Text('浅色'),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.dark,
                  label: Text('深色'),
                ),
              ],
              selected: <ThemeMode>{theme.themeMode},
              onSelectionChanged: (Set<ThemeMode> selection) {
                theme.setThemeMode(selection.first);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _seedColorPicker(BuildContext context, ThemeController theme) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool dynamicActive =
        theme.useDynamicColor && theme.dynamicColorAvailable;
    final int currentSeed = theme.seedColor.toARGB32();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('主题主色', style: textTheme.bodyLarge),
          const SizedBox(height: 4),
          Text(
            dynamicActive
                ? '当前主色来自系统壁纸，点选下面的色块会切换为手动主色'
                : '选一个种子色，ColorScheme.fromSeed 会推导出整套 MD3 配色',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: kPresetSeedColors
                .map((PresetSeedColor preset) {
                  final bool selected =
                      !dynamicActive && preset.color.toARGB32() == currentSeed;
                  return Tooltip(
                    message: '${preset.name} · ${_colorHex(preset.color)}',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => theme.setSeedColor(preset.color),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: preset.color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected
                                ? scheme.onSurface
                                : scheme.outlineVariant,
                            width: selected ? 3 : 1,
                          ),
                        ),
                        // 勾选使用黑白自适应，浅色种子也能看清。
                        child: selected
                            ? Icon(
                                Icons.check,
                                color:
                                    ThemeData.estimateBrightnessForColor(
                                          preset.color,
                                        ) ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black,
                                size: 20,
                              )
                            : null,
                      ),
                    ),
                  );
                })
                .toList(growable: false),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => _pickCustomSeedColor(context, theme),
            icon: const Icon(Icons.colorize_outlined),
            label: const Text('输入 HEX 自定义颜色'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 交互

  Future<void> _pickCustomSeedColor(
    BuildContext context,
    ThemeController theme,
  ) async {
    final Color? color = await showDialog<Color>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _SeedColorDialog(initialColor: theme.seedColor),
    );
    if (color != null) await theme.setSeedColor(color);
  }

  static String _colorHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  /// 版本号连点计数。
  ///
  /// 静默解锁：全程不弹任何提示，也不回显剩余次数。
  /// 唯一的可见结果就是第 8 次点击后设置页多出「开发者选项」入口。
  /// 之所以不做「再点 N 次」的提示，是因为隐藏入口一旦提示自己就会暴露给普通用户。
  void _onVersionTap(SettingsService settings) {
    // 已经是开发者模式就不用再数了
    if (settings.developerMode) return;

    final DateTime now = DateTime.now();
    if (_lastVersionTapAt != null &&
        now.difference(_lastVersionTapAt!) > _tapResetWindow) {
      _versionTapCount = 0;
    }
    _lastVersionTapAt = now;
    _versionTapCount++;

    if (_versionTapCount >= _tapsToUnlock) {
      _versionTapCount = 0;
      _lastVersionTapAt = null;
      settings.setDeveloperMode(true);
      return;
    }
  }

  void _openDeveloperPage(BuildContext context) {
    Navigator.of(context).push(DeveloperPage.route());
  }
}

/// 手动 HEX 取色对话框：无第三方依赖，避免颜色设置只限于预设色。
class _SeedColorDialog extends StatefulWidget {
  const _SeedColorDialog({required this.initialColor});

  final Color initialColor;

  @override
  State<_SeedColorDialog> createState() => _SeedColorDialogState();
}

class _SeedColorDialogState extends State<_SeedColorDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: _toHex(widget.initialColor),
  );
  late Color _selected = widget.initialColor;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static String _toHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  static Color? _parseHex(String value) {
    String digits = value.trim().replaceFirst(RegExp(r'^#'), '');
    if (RegExp(r'^[0-9a-fA-F]{3}$').hasMatch(digits)) {
      digits = digits.split('').map((String c) => '$c$c').join();
    }
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(digits)) return null;
    return Color(0xFF000000 | int.parse(digits, radix: 16));
  }

  void _onHexChanged(String value) {
    final Color? parsed = _parseHex(value);
    setState(() {
      _error = value.isEmpty || parsed != null
          ? null
          : '请输入 #RGB 或 #RRGGBB，例如 #6750A4';
      if (parsed != null) _selected = parsed;
    });
  }

  void _select(Color color) {
    setState(() {
      _selected = color;
      _controller.text = _toHex(color);
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color? parsed = _parseHex(_controller.text);
    return AlertDialog(
      title: const Text('自定义主题色'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('调色盘', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: kPresetSeedColors
                    .map((PresetSeedColor preset) {
                      final bool selected =
                          preset.color.toARGB32() == _selected.toARGB32();
                      return Tooltip(
                        message: preset.name,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => _select(preset.color),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: preset.color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected
                                    ? scheme.onSurface
                                    : scheme.outlineVariant,
                                width: selected ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                      );
                    })
                    .toList(growable: false),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _controller,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'HEX 色值',
                  hintText: '#6750A4',
                  errorText: _error,
                  prefixIcon: const Icon(Icons.tag),
                  border: const OutlineInputBorder(),
                ),
                onChanged: _onHexChanged,
              ),
              const SizedBox(height: 12),
              Container(
                height: 42,
                decoration: BoxDecoration(
                  color: parsed ?? _selected,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: scheme.outlineVariant),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                parsed == null ? _toHex(_selected) : _toHex(parsed),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: parsed == null
              ? null
              : () => Navigator.of(context).pop(parsed),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

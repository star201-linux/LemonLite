// lib/pages/settings/personalization_page.dart
//
// 个性化（二级页面）：主题模式、动态取色、主题主色。
//
// 为什么从设置页拆出来：设置页负责「有哪些地方可以改」，
// 而颜色是三项会互相影响的东西（模式 / 动态取色 / 种子色），
// 挤在一级页面里既占地方，又把「账号」「权限」这些更常用的入口往下压。
// 拆出来之后，设置页第一屏就是账号，颜色只在需要时点进去。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../theme/app_theme.dart';
import '../../theme/theme_controller.dart';

class PersonalizationPage extends StatelessWidget {
  const PersonalizationPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(
    builder: (BuildContext context) => const PersonalizationPage(),
  );

  @override
  Widget build(BuildContext context) {
    final ThemeController theme = context.watch<ThemeController>();

    return Scaffold(
      appBar: AppBar(title: const Text('个性化')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          _section(context, '主题', <Widget>[
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
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 子组件

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
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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

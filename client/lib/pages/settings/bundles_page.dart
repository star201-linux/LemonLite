
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../data/models/bundle_manifest.dart';
import '../../data/repositories/bundle_repository.dart';
import '../../data/services/plugin_service.dart';
import '../../theme/app_theme.dart';
import '../home/widgets/state_views.dart';
import '../../theme/loading.dart';

class BundlesPage extends StatefulWidget {
  const BundlesPage({super.key, required this.type});

  final BundleType type;

  static Route<void> route(BundleType type) => MaterialPageRoute<void>(
    builder: (BuildContext context) => BundlesPage(type: type),
  );

  @override
  State<BundlesPage> createState() => _BundlesPageState();
}

class _BundlesPageState extends State<BundlesPage> {
  List<BundleManifest> _items = const <BundleManifest>[];
  Set<String> _disabled = <String>{};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _isPlugin => widget.type == BundleType.plugin;

  /// 「安装」/「导入」两种语境下的动词，集中一处，文案不会各写各的
  String get _addVerb => _isPlugin ? '导入插件 ZIP' : '安装模块';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  // ------------------------------------------------------------ 数据

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final BundleRepository repo = BundleRepository.instance;
      _items = await repo.scan(widget.type);
      _disabled = await repo.disabledIds();
    } catch (e) {
      _error = '$e';
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  // ------------------------------------------------------------ 导入

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);

    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: _addVerb,
        // 不用 allowedExtensions 过滤：各厂商文件选择器对 zip 的 MIME 过滤不一致，
        // 反而选不到；这里放开选择、在下面按后缀校验，错误信息也更明确
        type: FileType.any,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppTheme.showToast('打开文件选择器失败：$e', isError: true);
      return;
    }

    if (picked == null) {
      if (mounted) setState(() => _busy = false);
      return; // 用户取消，不算错误
    }

    final Uint8List? bytes = await _readBytes(picked);
    if (bytes == null) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppTheme.showToast('读取文件失败：${picked.name}', isError: true);
      return;
    }

    // 先看包里是什么，确认后再落盘
    final BundleManifest? preview = await BundleRepository.peekManifest(
      bytes,
      picked.name,
    );
    if (!mounted) return;
    if (preview == null) {
      setState(() => _busy = false);
      await _showText(
        '这个包读不出来',
        _isPlugin
            ? '请导入插件 ZIP：需要包含 ${BundleManifest.manifestFileName}，'
                  '且 type = "plugin"、声明 platforms（支持的平台）。'
            : '请确认它是 LemonLite 模块包：一个 .zip（内含 '
                  '${BundleManifest.manifestFileName}）或单个 '
                  '${BundleManifest.manifestFileName}。',
      );
      return;
    }
    if (preview.type != widget.type) {
      setState(() => _busy = false);
      await _showText(
        '类型不对',
        '这是「${preview.type.label}」，当前页面管理的是「${widget.type.label}」。',
      );
      return;
    }

    final bool? ok = await _confirmInstall(preview);
    if (!mounted) return;
    if (ok != true) {
      setState(() => _busy = false);
      return;
    }

    try {
      final BundleImportResult result = await BundleRepository.instance
          .importBundle(bytes, picked.name);
      await _reload();
      if (!mounted) return;
      setState(() => _busy = false);
      AppTheme.showToast(
        result.replaced
            ? '${result.manifest.name} v${result.manifest.version} 已覆盖更新'
            : '${result.manifest.name} v${result.manifest.version} 安装完成',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final String detail = e is BundleException ? (e.detail ?? '') : '';
      await _showText(e is BundleException ? e.message : '导入失败', detail);
    }
  }

  Future<Uint8List?> _readBytes(PlatformFile file) async {
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  List<String> _jsFiles(BundleManifest manifest) => <String>{
    ...manifest.jsFiles,
    for (final BundleContentScript rule in manifest.contentScripts)
      ...rule.jsFiles,
  }.toList(growable: false);

  List<String> _cssFiles(BundleManifest manifest) => <String>{
    ...manifest.cssFiles,
    for (final BundleContentScript rule in manifest.contentScripts)
      ...rule.cssFiles,
  }.toList(growable: false);

  /// 安装前的确认卡：把 manifest 里真正会影响运行的东西摊开给用户看
  Future<bool?> _confirmInstall(BundleManifest manifest) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> jsFiles = _jsFiles(manifest);
    final List<String> cssFiles = _cssFiles(manifest);
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        icon: const Icon(Icons.inventory_2_outlined),
        title: Text('安装「${manifest.name}」？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _row('类型', manifest.type.label),
              _row('id', manifest.id),
              _row('版本', 'v${manifest.version}'),
              if (manifest.author.isNotEmpty) _row('作者', manifest.author),
              if (manifest.description.isNotEmpty)
                _row('说明', manifest.description),
              if (_isPlugin) ...<Widget>[
                _row(
                  '支持平台',
                  manifest.platforms.isEmpty
                      ? '全平台'
                      : manifest.platforms.join('、'),
                ),
                _row(
                  '声明能力',
                  manifest.capabilities.isEmpty
                      ? '无'
                      : manifest.capabilities.join('、'),
                ),
                _row('当前设备', PluginService.currentPlatformId),
              ] else ...<Widget>[
                _row(
                  manifest.contentScripts.isEmpty ? '生效页面' : '匹配规则',
                  manifest.contentScripts.isEmpty
                      ? manifest.matches.join('、')
                      : manifest.contentScripts
                            .map(
                              (BundleContentScript rule) =>
                                  rule.matches.join('、'),
                            )
                            .join('；'),
                ),
                if (jsFiles.isNotEmpty) _row('注入脚本', jsFiles.join('、')),
                if (cssFiles.isNotEmpty) _row('注入样式', cssFiles.join('、')),
                if (manifest.bridgeMethods.isNotEmpty)
                  _row(
                    '新增 API',
                    manifest.bridgeMethods
                        .map((BundleBridgeMethod m) => '${m.name}()')
                        .join('、'),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                _isPlugin
                    ? '插件不往页面注入任何代码：它给宿主增加一项能力，'
                          '所有小程序都能用；只在这台设备支持的平台上启用。'
                    : '模块的脚本会注入到匹配的小程序页面里运行。'
                          '它声明的 API 由宿主已有能力组合而成，'
                          '不会获得宿主之外的能力。请只导入可信文件。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );

  /// 统一的「只读信息弹窗」：导入失败、包详情都用它，避免堆两套几乎一样的对话框
  Future<void> _showText(String title, String? detail) => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      icon: const Icon(Icons.error_outline),
      title: Text(title),
      content: SingleChildScrollView(
        child: Text(detail == null || detail.isEmpty ? '没有更多细节了。' : detail),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  // ------------------------------------------------------------ 启停 / 删除

  Future<void> _toggle(BundleManifest manifest, bool enabled) async {
    await BundleRepository.instance.setDisabled(manifest.id, !enabled);
    await _reload();
    if (!mounted) return;
    AppTheme.showToast(
      enabled ? '${manifest.name} 已启用，重新打开小程序后生效' : '${manifest.name} 已停用',
    );
  }

  Future<void> _remove(BundleManifest manifest) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        icon: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text('删除「${manifest.name}」？'),
        content: const Text('会连同包内的脚本一起删除，小程序下次打开就不再有它。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await BundleRepository.instance.remove(manifest);
    await _reload();
    if (!mounted) return;
    AppTheme.showToast('已删除 ${manifest.name}');
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(_isPlugin ? '插件' : '模块')),
      body: _loading
          ? const LoadingView()
          : (_error != null
                ? ErrorView(title: '读取失败', message: _error!, onRetry: _reload)
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 40),
                      children: <Widget>[
                        _intro(scheme, textTheme),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _import,
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: M3ELoadingIndicator(),
                                  )
                                : const Icon(Icons.add),
                            label: Text(_addVerb),
                          ),
                        ),
                        if (_items.isEmpty)
                          EmptyView(
                            icon: _isPlugin
                                ? Icons.hub_outlined
                                : Icons.extension_outlined,
                            title: _isPlugin ? '还没有安装插件' : '还没有安装模块',
                            message: _isPlugin
                                ? '插件给宿主增加能力，不往页面注入代码。'
                                      '导入包含 lemonlite.json 的插件 ZIP 即可。'
                                : '模块会向匹配的小程序注入脚本，并可用宿主能力'
                                      '组合出新的 API。导入包含 lemonlite.json 的 ZIP。',
                            actionLabel: _addVerb,
                            onAction: _import,
                          )
                        else
                          ..._items.map(
                            (BundleManifest m) => _tile(m, scheme, textTheme),
                          ),
                      ],
                    ),
                  )),
    );
  }

  Widget _intro(ColorScheme scheme, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              _isPlugin ? Icons.hub_outlined : Icons.extension_outlined,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _isPlugin ? '插件（给宿主加能力）' : '模块（mod 式）',
                    style: textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isPlugin
                        ? '插件不注入页面代码，而是给宿主增加一项能力。'
                              'manifest 里用 platforms 声明支持的平台；'
                              '宿主只在这台设备匹配时启用它。'
                        : '一个 zip 包，内含 lemonlite.json 与脚本。可向匹配的小程序'
                              '注入脚本，并通过 manifest.bridge 声明新的 API —— '
                              '那些 API 由宿主已有能力组合实现。',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 详情弹窗的正文。两种包字段不同，集中在这里生成。
  String _detailText(BundleManifest manifest) {
    final List<String> lines = <String>[
      'id: ${manifest.id}',
      '版本: ${manifest.version}',
      '作者: ${manifest.author.isEmpty ? '未填写' : manifest.author}',
      '说明: ${manifest.description.isEmpty ? '未填写' : manifest.description}',
    ];
    if (_isPlugin) {
      lines.addAll(<String>[
        '支持平台: ${manifest.platforms.isEmpty ? '全平台' : manifest.platforms.join('、')}',
        '当前设备: ${PluginService.currentPlatformId}'
            '${PluginService.platformMatches(manifest) ? '（支持）' : '（不支持，已跳过）'}',
        '声明能力: ${manifest.capabilities.isEmpty ? '无' : manifest.capabilities.join('、')}',
        '注入页面: 无（插件不注入代码）',
      ]);
    } else {
      lines.addAll(<String>[
        '生效页面: ${manifest.matches.join('、')}',
        '注入时机: ${manifest.runAt.label}',
        '脚本: ${_jsFiles(manifest).isEmpty ? '无' : _jsFiles(manifest).join('、')}',
        '样式: ${_cssFiles(manifest).isEmpty ? '无' : _cssFiles(manifest).join('、')}',
        '新增 API: ${manifest.bridgeMethods.isEmpty ? '无' : manifest.bridgeMethods.map((BundleBridgeMethod m) => '${m.name}() → ${m.action}').join('、')}',
      ]);
    }
    return lines.join('\n');
  }

  Widget _tile(
    BundleManifest manifest,
    ColorScheme scheme,
    TextTheme textTheme,
  ) {
    final bool enabled = !_disabled.contains(manifest.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
            ListTile(
              leading: Icon(
                _isPlugin ? Icons.hub_outlined : Icons.extension_outlined,
              ),
              title: Text(manifest.name),
              subtitle: Text(
                '${manifest.summary}\nid: ${manifest.id}',
                style: textTheme.bodySmall,
              ),
              isThreeLine: true,
              trailing: Switch(
                value: enabled,
                onChanged: (bool v) => _toggle(manifest, v),
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Row(
                children: <Widget>[
                  TextButton.icon(
                    onPressed: () => _showText(
                      '${manifest.type.label}详情',
                      _detailText(manifest),
                    ),
                    icon: const Icon(Icons.info_outline),
                    label: const Text('详情'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _remove(manifest),
                    icon: Icon(Icons.delete_outline, color: scheme.error),
                    label: Text('删除', style: TextStyle(color: scheme.error)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

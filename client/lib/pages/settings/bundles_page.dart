// lib/pages/settings/bundles_page.dart
//
// 模块管理仍收在开发者选项；页面扩展与插件从普通设置页即可导入与管理。
//
// 三种类型共用这一页，因为它们的**操作流程完全一样**：选文件 → 校验 → 确认 → 装上 → 可启停。
// 差别只在 manifest 的 type 字段、文案，以及插件多出来的「平台 / 能力」信息，
// 所以用 type 参数区分而不是写三页。
//
// 插件页还有一个**随包附带**的来源：WebAssembly 运行时。
// 它不在宿主代码里，而是一个独立插件包（assets/plugins/lemonlite-wasm），
// 装不装由用户决定 —— 所以这里给一张「可安装」的卡片，而不是启动时偷偷装上。
//
// 为什么导入后还要再弹一次确认：
//   这类包等价于「往每个小程序页面里插一段代码」，属于安全敏感操作。
//   用户在文件选择器里看到的是文件名，看不到包里的 id / 作者 / 声明了哪些 API。
//   所以先把 manifest 读出来给用户看清楚再落盘 —— 装了之后至少知道自己装了什么。

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../data/models/bundle_manifest.dart';
import '../../data/repositories/bundle_repository.dart';
import '../../data/services/plugin_service.dart';
import '../../theme/app_theme.dart';
import '../home/widgets/state_views.dart';

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

  bool get _isModule => widget.type == BundleType.module;
  bool get _isPlugin => widget.type == BundleType.plugin;

  /// 随包附带的 WebAssembly 插件是否已经装过（null = 还没查）
  bool? _bundledWasmInstalled;

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
      if (_isPlugin) {
        _bundledWasmInstalled = await PluginService.instance.isInstalled(
          PluginService.bundledWasmPluginId,
        );
      }
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

    final String verb = _isPlugin
        ? '导入插件 ZIP'
        : _isModule
        ? '安装模块'
        : '导入扩展 ZIP';
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: verb,
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
            ? '请导入插件 ZIP：需要包含 lemonlite.json，且 type = "plugin"、'
                  '声明 capabilities（能力）与可选的 wasm 模块。'
            : _isModule
            ? '请确认它是 LemonLite 模块包：一个 .zip（内含 ${BundleManifest.manifestFileName}）或单个 ${BundleManifest.manifestFileName}。'
            : '请导入 ZIP 文件：需要包含 lemonlite.json 扩展清单。',
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
            : '${result.manifest.name} v${result.manifest.version} '
                  '${_isModule || _isPlugin ? '安装' : '已加入'}完成',
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
        title: Text('${_isModule || _isPlugin ? '安装' : '加入'}「${manifest.name}」？'),
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
              if (_isPlugin) ...<Widget>[
                _row(
                  '支持平台',
                  manifest.platforms.isEmpty ? '全平台' : manifest.platforms.join('、'),
                ),
                _row('能力', manifest.capabilities.join('、')),
                if (manifest.wasmModules.isNotEmpty)
                  _row(
                    'wasm 模块',
                    manifest.wasmModules.map((PluginWasmModule m) => m.name).join('、'),
                  ),
                _row('当前设备', PluginService.currentPlatformId),
              ],
              if (jsFiles.isNotEmpty) _row('注入脚本', jsFiles.join('、')),
              if (cssFiles.isNotEmpty) _row('注入样式', cssFiles.join('、')),
              if (manifest.bridgeMethods.isNotEmpty)
                _row(
                  '新增 API',
                  manifest.bridgeMethods
                      .map((BundleBridgeMethod m) => '${m.name}()')
                      .join('、'),
                ),
              const SizedBox(height: 12),
              Text(
                _isPlugin
                    ? '插件不往页面注入任何代码：它给宿主增加一项能力（如 wasm），'
                          '所有小程序都能用；只能在这台设备支持的平台上启用。'
                    : _isModule
                    ? '模块的脚本会注入到匹配的小程序页面里运行。'
                          '它声明的 API 由宿主已有能力组合而成，不会获得宿主之外的能力。'
                    : manifest.contentScripts.isNotEmpty
                    ? '只注入页面脚本与样式（JS / CSS 与匹配规则）。'
                          '脚本将在 LemonLite 小程序 WebView 内执行，请只导入可信文件。'
                    : '扩展的脚本与样式会注入到匹配的小程序页面里运行，'
                          '不会改变宿主的任何行为。',
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
            child: Text(_isModule || _isPlugin ? '安装' : '加入'),
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
      appBar: AppBar(
        title: Text(_isPlugin ? '插件' : _isModule ? '模块' : '页面扩展'),
      ),
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
                        if (_isPlugin) _bundledCard(scheme, textTheme),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _import,
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.add),
                            label: Text(_isPlugin
                                ? '导入插件 ZIP'
                                : _isModule
                                ? '安装模块'
                                : '导入扩展 ZIP'),
                          ),
                        ),
                        if (_items.isEmpty)
                          EmptyView(
                            icon: _isPlugin
                                ? Icons.hub_outlined
                                : _isModule
                                ? Icons.extension_outlined
                                : Icons.widgets_outlined,
                            title: _isPlugin
                                ? '还没有安装插件'
                                : _isModule
                                ? '还没有安装模块'
                                : '还没有页面扩展',
                            message: _isPlugin
                                ? '插件给宿主增加能力（例如 WebAssembly 运行时）。'
                                      '可以导入 ZIP，或直接安装上面随包附带的那个。'
                                : _isModule
                                ? '模块只能在这里安装：它会向小程序注入脚本，并可用宿主能力组合出新的 API。'
                                : '导入包含 lemonlite.json 的扩展 ZIP，给匹配的小程序页面注入脚本与样式。',
                            actionLabel: _isPlugin
                                ? '导入插件 ZIP'
                                : _isModule
                                ? '安装模块'
                                : '导入扩展 ZIP',
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

  /// 随包附带的 WebAssembly 插件包。
  ///
  /// 刻意**不自动安装**：插件是「给宿主加能力」的东西，用户应该知道
  /// 自己装了它、也随时能卸掉。没装时这里显示"可安装"，装完之后卡片消失。
  Widget _bundledCard(ColorScheme scheme, TextTheme textTheme) {
    if (_bundledWasmInstalled != false) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: const Icon(Icons.inventory_2_outlined),
          title: const Text('随包附带：WebAssembly 运行时'),
          subtitle: const Text(
            'v1.0.0 · 能力 wasm · 全平台\n'
            '装上之后 lemonlite.wasm.* 才能用；之后也可以随时卸载',
          ),
          isThreeLine: true,
          trailing: FilledButton.tonal(
            onPressed: _busy ? null : _installBundledWasm,
            child: const Text('安装'),
          ),
        ),
      ),
    );
  }

  /// 安装随包附带的插件包（和导入 ZIP 走同一套落盘/校验）。
  Future<void> _installBundledWasm() async {
    setState(() => _busy = true);
    try {
      final bool installed = await PluginService.instance.installBundledWasm();
      await _reload();
      if (!mounted) return;
      AppTheme.showToast(installed ? 'WebAssembly 运行时已安装' : '已经安装过了');
    } on PluginUnavailableException catch (e) {
      if (!mounted) return;
      await _showText('安装失败', e.message);
    } catch (e) {
      if (!mounted) return;
      await _showText('安装失败', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              _isModule ? Icons.extension_outlined : Icons.widgets_outlined,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _isPlugin
                        ? '插件（宿主能力 / 多平台）'
                        : _isModule
                        ? '模块（mod 式）'
                        : '扩展（浏览器插件式）',
                    style: textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isPlugin
                        ? '插件不注入页面代码，而是给宿主增加一项能力（如 wasm）。'
                              'manifest 里用 platforms 声明支持的平台、用 capabilities 声明能力；'
                              '宿主只在这台设备匹配时启用它。'
                        : _isModule
                        ? '一个 zip 包，内含 lemonlite.json 与脚本。可向匹配的小程序注入脚本，'
                              '并通过 manifest.bridge 声明新的 API —— 那些 API 由宿主已有能力组合实现。'
                        : '导入扩展 ZIP（lemonlite.json + 脚本 / 样式），'
                              '只运行匹配规则内的页面 JS / CSS。',
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

  /// 详情弹窗的正文。三种包字段完全不同，集中在这里生成，
  /// 免得 _tile 里拼一个越来越长的字符串。
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
        '能力: ${manifest.capabilities.join('、')}',
        'wasm 模块: ${manifest.wasmModules.isEmpty ? '无' : manifest.wasmModules.map((PluginWasmModule m) => m.name).join('、')}',
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
                _isPlugin
                    ? Icons.hub_outlined
                    : _isModule
                    ? Icons.extension_outlined
                    : Icons.widgets_outlined,
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

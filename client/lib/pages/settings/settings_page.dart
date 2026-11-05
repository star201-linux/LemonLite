// lib/pages/settings/settings_page.dart
//
// 设置页：
//   * 账号（第一位）：登录 / 注册 / 账号管理
//   * 个性化（二级页面）：主题模式、动态取色、主题主色
//   * 权限 / 存储 / 市场 / 页面扩展
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
import '../home/home_controller.dart';
import '../account/account_page.dart';
import '../download/download_page.dart';
import '../permissions/permission_controller_page.dart';
import '../storage/storage_page.dart';
import 'bundles_page.dart';
import 'developer_page.dart';
import 'personalization_page.dart';

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
    final HomeController home = context.watch<HomeController>();
    final AccountService account = context.watch<AccountService>();
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
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

          // ------------------------------ 个性化 ------------------------------
          // 颜色那三项（模式 / 动态取色 / 种子色）都进了二级页面：
          // 一级页面只留一个入口，账号才能待在第一个。
          _section(context, '个性化', <Widget>[
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('外观与主题'),
              subtitle: const Text('主题模式、动态取色与主题主色'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context).push(PersonalizationPage.route()),
            ),
          ]),

          // ------------------------------ 权限 ------------------------------
          // 权限管理与「应用管理」共用同一份应用清单：这里进去看到的应用，
          // 就是底部「应用管理」里那些。要增删应用请去应用管理。
          _section(context, '权限', <Widget>[
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('权限管理'),
              subtitle: const Text('摄像头、麦克风、手机存储；按应用逐个设置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(PermissionControllerPage.route()),
            ),
          ]),

          // ------------------------------ 存储 ------------------------------
          _section(context, '存储', <Widget>[
            // 下载管理排在存储占用前面：它是「有事可做」的页面，
            // 而存储占用多数时候只是看一眼。
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('下载管理'),
              subtitle: const Text('下载目录、进度与记录；网页下载交给系统下载器'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context).push(DownloadPage.route()),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
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

          _section(context, '扩展与插件', <Widget>[
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('页面扩展'),
              subtitle: const Text('从 ZIP 导入页面脚本与样式'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(BundlesPage.route(BundleType.extension)),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // 插件是「宿主能力」，和扩展/模块（注入页面）不是一回事，
            // 所以单开一行而不是塞进扩展页里当第三个标签。
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('插件'),
              subtitle: const Text('给宿主增加能力（如 WebAssembly），可安装 / 停用 / 卸载'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(
                context,
              ).push(BundlesPage.route(BundleType.plugin)),
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
            // 小程序测试入口收进了「开发者选项 → 小程序测试」二级菜单，
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

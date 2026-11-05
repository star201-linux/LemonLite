// lib/pages/miniapp/miniapp_installer.dart
//
// 「确保某个小程序已装到本机」的协调器：查本地版本 → 视情况下载 → 提示进度。
//
// 把它单独抽出来，是因为这个流程要在**三处**复用：
//   1. 详情页点「打开」
//   2. 升级检查里点「全部更新」
//   3. 主页点卡片直接打开（跳过详情页）
// 三处各写一遍必然出现「有一处忘了校验 sha256」这种问题。
//
// 两个入口：
//   ensureInstalled()  确保可用（装了就直接返回 true，不下载）
//   forceInstall()     强制装指定版本（升级用）

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/globals.dart';
import '../../data/models/app_item.dart';
import '../../data/services/icon_cache_service.dart';
import '../../data/services/miniapp_package_service.dart';
import '../../theme/app_theme.dart';

class MiniappInstaller {
  const MiniappInstaller._();

  /// 确保 [app] 已装好；没装或版本不一致时下载安装。
  ///
  /// 返回 true 表示「现在可以打开了」。
  /// [showProgress] 为 true 时显示进度对话框；false 时只在失败时弹 toast
  /// （升级检查的批量更新用它，因为外面已经有进度界面了）。
  static Future<bool> ensureInstalled(
    BuildContext context, {
    required AppItem app,
    bool showProgress = true,
    void Function(PackageProgress)? onProgress,
  }) async {
    final MiniappPackageService service = MiniappPackageService.instance;

    // ---- 已装且版本一致：直接放行 ----
    final InstalledPackage? existing = await service.installed(app.id);
    if (existing != null &&
        (app.version.isEmpty || existing.version == app.version)) {
      lemonLog('Installer', '${app.id} 已装 v${existing.version}，直接打开');
      return true;
    }

    if (!app.canOpen) {
      if (context.mounted) {
        AppTheme.showToast('「${app.name}」还没有上架安装包', isError: true);
      }
      return false;
    }

    // ---- 需要下载 ----
    final bool upgrading = existing != null;

    // 进度对话框：用一个 ValueNotifier 驱动，避免每帧 setState 重建整棵树
    final ValueNotifier<PackageProgress?> progress =
        ValueNotifier<PackageProgress?>(null);

    // 存 NavigatorState 而不是 BuildContext。
    //
    // 为什么：这个值要在多个 await 之后使用，而 lint
    //（use_build_context_synchronously）会正确地把「await 之后用 context」
    // 判为危险 —— 页面可能在下载期间被销毁。NavigatorState 没有这个问题：
    // 它有自己的 mounted 语义，而且 pop 一个已经不在栈上的对话框是无害的。
    NavigatorState? dialogNavigator;
    if (showProgress && context.mounted) {
      final NavigatorState navigator = Navigator.of(context);
      dialogNavigator = navigator;
      // 不 await：对话框要一直显示到下载完成
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          // 用 navigator 的 context 建对话框，这样它挂在这个 Navigator 下
          builder: (BuildContext ctx) => _InstallDialog(
            appName: app.name,
            upgrading: upgrading,
            fromVersion: existing?.version ?? '',
            toVersion: app.version,
            progress: progress,
          ),
        ),
      );
    }

    try {
      final InstalledPackage installed = await service.install(
        appId: app.id,
        version: app.version.isEmpty ? '0' : app.version,
        packageUrl: app.packageUrl,
        sha256: app.packageSha256,
        entry: app.packageEntry,
        onProgress: (PackageProgress p) {
          progress.value = p;
          onProgress?.call(p);
        },
      );

      // 装完清掉旧版本目录（升级场景）
      if (upgrading) {
        final int removed = await service.pruneOldVersions(app.id);
        if (removed > 0) {
          lemonLog('Installer', '${app.id} 清理了 $removed 个旧版本目录');
        }
      }

      // 图标缓存：装好之后这个小程序就是「本机已安装」了，应用管理里要能
      // 不联网也显示它。缓存失败不影响安装结果（ensure 内部已吞异常）。
      await IconCacheService.instance.ensure(appId: app.id, url: app.icon);

      _closeDialog(dialogNavigator);
      // AppTheme.showToast 走全局 ScaffoldMessenger key，**不用**这个 context。
      // 所以这里不存在「跨 async gap 用 context」的问题 —— 直接弹。
      AppTheme.showToast(
        upgrading
            ? '「${app.name}」已更新到 ${installed.version}'
            : '「${app.name}」已安装',
      );
      return true;
    } on PackageException catch (e) {
      _closeDialog(dialogNavigator);
      AppTheme.showToast(
        e.message,
        isError: true,
        duration: const Duration(seconds: 4),
      );
      return false;
    } catch (e) {
      _closeDialog(dialogNavigator);
      AppTheme.showToast('安装失败：$e', isError: true);
      return false;
    } finally {
      progress.dispose();
    }
  }

  /// 强制安装某个版本（升级检查用：它已经知道要装哪一版）
  static Future<bool> forceInstall(
    BuildContext context, {
    required String appId,
    required String appName,
    required String version,
    required String packageUrl,
    required String sha256,
    required String entry,
    String? iconUrl,
    void Function(PackageProgress)? onProgress,
  }) async {
    final MiniappPackageService service = MiniappPackageService.instance;
    try {
      await service.install(
        appId: appId,
        version: version,
        packageUrl: packageUrl,
        sha256: sha256,
        entry: entry,
        onProgress: onProgress,
      );
      await service.pruneOldVersions(appId);
      await IconCacheService.instance.ensure(appId: appId, url: iconUrl);
      return true;
    } on PackageException catch (e) {
      if (context.mounted) {
        AppTheme.showToast('「$appName」更新失败：${e.message}', isError: true);
      }
      return false;
    } catch (e) {
      if (context.mounted) {
        AppTheme.showToast('「$appName」更新失败：$e', isError: true);
      }
      return false;
    }
  }

  /// 关掉进度对话框。
  ///
  /// 参数是 NavigatorState 而不是 BuildContext —— 这样就不存在
  /// 「await 之后还在用 context」的问题（见 ensureInstalled 里的说明）。
  /// 对话框是 barrierDismissible: false 的，下载结束前一定还在栈上，
  /// 所以能 pop 就直接 pop；不能 pop（已经被别处关掉）就什么都不做。
  static void _closeDialog(NavigatorState? navigator) {
    if (navigator == null) return;
    if (!navigator.mounted) return;
    if (!navigator.canPop()) return;
    navigator.pop();
  }
}

/// 下载进度对话框
class _InstallDialog extends StatelessWidget {
  const _InstallDialog({
    required this.appName,
    required this.upgrading,
    required this.fromVersion,
    required this.toVersion,
    required this.progress,
  });

  final String appName;
  final bool upgrading;
  final String fromVersion;
  final String toVersion;
  final ValueNotifier<PackageProgress?> progress;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(upgrading ? '正在更新' : '正在安装'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(appName, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            upgrading ? '$fromVersion → $toVersion' : '版本 $toVersion',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<PackageProgress?>(
            valueListenable: progress,
            builder: (BuildContext ctx, PackageProgress? p, Widget? child) {
              final double? fraction = p?.fraction;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 服务端没给 Content-Length 时用不确定进度条（而不是假装 0%）
                  if (fraction != null)
                    LinearProgressIndicator(value: fraction)
                  else
                    const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    p == null ? '准备中…' : p.label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// lib/data/services/installed_app_info.dart
//
// 「这台设备上装了什么」的展示信息 —— **只从包自己身上读**。
//
// 为什么要单独一层：
//   应用市场（首页 / 搜索 / 详情）里的名字、图标、简介来自服务端 API，
//   那是「上架信息」；而「应用管理」里列的是本机装的东西，应当以包里
//   的 metadata.json 为准 —— 作者改了包里的名字、换了包内图标，
//   应用管理就该跟着变，不需要等市场数据刷新，断网也一样。
//
// 两个来源的优先级：
//   1. 包内 metadata.json（name / version / description / author / icon / permissions）
//   2. 应用清单（ApplicationRegistry）里留的名字与图标地址（老包没有 metadata.json）
//   3. appId 本身（什么都没有时的最后兜底）
//
// 图标：
//   * 包内声明了 `icon` 且文件真的在 → 用这个本地文件（`AppIcon.localPath`）；
//   * 否则退回清单里缓存的市场图标地址（断网时 AppIcon 会退回首字占位）。
//   * `..` 之类越界的声明一律忽略 —— 图标路径来自包，不能让它指到包外面。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/miniapp_metadata.dart';
import 'application_registry.dart';
import 'miniapp_package_service.dart';

@immutable
class InstalledAppInfo {
  const InstalledAppInfo({
    required this.appId,
    required this.name,
    required this.version,
    this.description = '',
    this.author = '',
    this.iconPath,
    this.iconUrl,
    this.permissionIds = const <String>[],
    this.package,
  });

  final String appId;
  final String name;
  final String version;
  final String description;
  final String author;

  /// 包内图标的绝对路径（存在才有值）
  final String? iconPath;

  /// 清单里缓存的市场图标地址（包内没有图标时的兜底）
  final String? iconUrl;

  /// 包里声明的权限 id（原始字符串）
  final List<String> permissionIds;

  /// 已安装的包；null = 只登记过、本机没有可用包
  final InstalledPackage? package;

  bool get installed => package != null;

  /// 包里有可读的 metadata.json（应用管理里用它区分「按 JSON 显示」还是兜底）
  bool get fromMetadata => package?.metadata != null;

  /// 展示用版本串
  String get versionLabel => version.trim().isEmpty ? '版本未知' : 'v$version';
}

/// 读一个应用在本机的信息。
Future<InstalledAppInfo> loadInstalledAppInfo(
  String appId, {
  RegisteredApp? fallback,
}) async {
  final RegisteredApp? registered =
      fallback ?? ApplicationRegistry.instance.byId(appId);
  InstalledPackage? pkg;
  try {
    pkg = await MiniappPackageService.instance.installed(appId);
  } catch (e) {
    // 存储不可用不该让应用管理打不开
    pkg = null;
  }

  final MiniappMetadata? meta = pkg?.metadata;
  final String name = (meta?.name ?? '').trim().isNotEmpty
      ? meta!.name
      : (registered?.displayName ?? appId);

  return InstalledAppInfo(
    appId: appId,
    name: name,
    version: meta?.version ?? pkg?.version ?? '',
    description: meta?.description ?? '',
    author: meta?.author ?? '',
    iconPath: _iconPathOf(pkg),
    iconUrl: registered?.icon,
    permissionIds: meta?.permissionIds ?? registered?.permissionIds ?? const <String>[],
    package: pkg,
  );
}

/// 批量读（应用管理列表用）。没有包的条目也会返回（兜底展示）。
Future<Map<String, InstalledAppInfo>> loadInstalledAppInfos(
  Iterable<String> appIds,
) async {
  final Map<String, InstalledAppInfo> result = <String, InstalledAppInfo>{};
  for (final String id in appIds) {
    if (id.trim().isEmpty) continue;
    result[id] = await loadInstalledAppInfo(id);
  }
  return result;
}

/// 包内图标 → 绝对路径。声明缺失、路径越界、文件不存在都返回 null。
String? _iconPathOf(InstalledPackage? pkg) {
  final MiniappMetadata? meta = pkg?.metadata;
  if (pkg == null || meta == null) return null;
  final String declared = meta.icon.trim();
  if (declared.isEmpty) return null;

  final String normalized = p.posix.normalize(declared.replaceAll('\\', '/'));
  if (normalized == '..' || normalized.startsWith('../')) return null;

  final String path = p.join(pkg.dir, normalized);
  if (!p.isWithin(pkg.dir, path)) return null;
  return File(path).existsSync() ? path : null;
}

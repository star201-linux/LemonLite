// lib/data/models/app_version.dart
//
// 服务端「单个应用的最新版本」接口（GET /api/market/<appId>/version）的模型。
//
// 为什么单独一个模型而不是复用 AppItem：
//   这个接口是**打开小程序前的一次轻量检查** —— 它不返回简介、截图、分类、
//   权限声明这些东西，只返回「现在最新是哪一版、包在哪」。用 AppItem 解析
//   会让一堆字段永远是空值，调用方还得自己判断「这个 AppItem 是不是完整的」。
//
// 与 PackageUpdate 的区别：
//   PackageUpdate 是「我装了旧版，服务端说该更新了」的结论；
//   AppVersionInfo 是「服务端现在这一版是什么」的事实。每次打开小程序都会问一次，
//   哪怕本地没装（这时还没有「更新」可言，只有「要下载哪一版」）。

import 'json_utils.dart';

class AppVersionInfo {
  const AppVersionInfo({
    required this.appId,
    required this.name,
    required this.version,
    required this.icon,
    required this.hasPackage,
    required this.packageUrl,
    required this.entry,
    required this.sha256,
    required this.bytes,
    this.updatedAt,
  });

  final String appId;
  final String name;

  /// 服务端当前上架的版本号
  final String version;

  /// 图标绝对地址（服务端已解析；可能为空）
  final String icon;

  /// 是否真的有可下载的包（没有包时 [packageUrl] 为空）
  final bool hasPackage;

  final String packageUrl;
  final String entry;
  final String sha256;
  final int bytes;
  final DateTime? updatedAt;

  /// 宽松解析。id 与版本都读不到时返回 null（这种响应没有意义）。
  static AppVersionInfo? fromJson(Map<String, dynamic> json) {
    final String appId = asString(json['id']);
    final String version = asString(json['version']);
    if (appId.isEmpty || version.isEmpty) return null;
    return AppVersionInfo(
      appId: appId,
      name: asString(json['name'], fallback: appId),
      version: version,
      icon: asString(json['icon']),
      hasPackage: json['hasPackage'] == true,
      packageUrl: asString(json['packageUrl']),
      entry: asString(json['packageEntry'], fallback: 'index.html'),
      sha256: asString(json['packageSha256']),
      bytes: asInt(json['packageBytes']),
      updatedAt: asDateTime(json['updatedAt']),
    );
  }

  @override
  String toString() => 'AppVersionInfo($appId, v$version)';
}

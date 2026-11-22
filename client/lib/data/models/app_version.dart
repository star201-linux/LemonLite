
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

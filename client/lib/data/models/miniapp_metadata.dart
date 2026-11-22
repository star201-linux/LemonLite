
import 'json_utils.dart';
import 'miniapp_permission.dart';

class MiniappMetadata {
  const MiniappMetadata({
    required this.id,
    required this.name,
    required this.version,
    required this.entry,
    this.description = '',
    this.author = '',
    this.icon = '',
    this.permissionIds = const <String>[],
    this.minFrameworkVersion = '',
  });

  /// 包内文件名（约定）
  static const String fileName = 'metadata.json';

  final String id;
  final String name;
  final String version;

  /// 入口文件的包内相对路径
  final String entry;
  final String description;
  final String author;

  /// 包内图标相对路径（可选；宿主会优先用市场图标，没有才用它）
  final String icon;

  /// 声明申请的权限 id（原始字符串，未知 id 也保留）
  final List<String> permissionIds;

  /// 要求的最低宿主框架版本；空 = 不限
  final String minFrameworkVersion;

  /// 能识别成受控权限的那些声明
  List<MiniappPermission> get declaredPermissions => permissionIds
      .map(MiniappPermission.byId)
      .whereType<MiniappPermission>()
      .toList(growable: false);

  /// 写了但宿主不认识的 id（拼错或用了新版本才有的权限）
  List<String> get unknownPermissionIds => permissionIds
      .where((String id) => MiniappPermission.byId(id) == null)
      .toList(growable: false);

  /// 这个包要求的框架版本是否高于当前宿主
  bool get needsNewerFramework =>
      minFrameworkVersion.trim().isNotEmpty &&
      compareVersions(minFrameworkVersion, currentFramework) > 0;

  /// 由调用方注入当前框架版本，避免模型层 import core/globals（模型要能单测）
  static String currentFramework = '0.0.0';

  static MiniappMetadata? parse(Map<String, dynamic> json) {
    final String id = asString(json['id']).trim();
    final String name = asString(json['name']).trim();
    final String version = asString(json['version']).trim();
    if (id.isEmpty || name.isEmpty) return null;

    final String entry = asString(json['entry']).trim();
    return MiniappMetadata(
      id: id,
      name: name,
      version: version,
      entry: entry.isEmpty ? 'index.html' : entry,
      description: asString(json['description']).trim(),
      author: asString(json['author']).trim(),
      icon: asString(json['icon']).trim(),
      permissionIds: asStringList(json['permissions'])
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false),
      minFrameworkVersion: asString(json['minFrameworkVersion']).trim(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'version': version,
    'entry': entry,
    if (description.isNotEmpty) 'description': description,
    if (author.isNotEmpty) 'author': author,
    if (icon.isNotEmpty) 'icon': icon,
    if (permissionIds.isNotEmpty) 'permissions': permissionIds,
    if (minFrameworkVersion.isNotEmpty)
      'minFrameworkVersion': minFrameworkVersion,
  };
}

/// 比较 `1.2.3` 形式的版本号；a > b 返回正数。
///
/// 只做主机序比较，不处理 `-beta` 这类后缀（框架版本不发预发布号）。
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp(r'[.+-]'))
      .map((String s) => int.tryParse(s.replaceAll(RegExp(r'\D'), '')) ?? 0)
      .toList(growable: false);

  final List<int> left = parts(a);
  final List<int> right = parts(b);
  final int length = left.length > right.length ? left.length : right.length;
  for (int i = 0; i < length; i++) {
    final int l = i < left.length ? left[i] : 0;
    final int r = i < right.length ? right[i] : 0;
    if (l != r) return l - r;
  }
  return 0;
}

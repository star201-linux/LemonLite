// lib/data/models/miniapp_metadata.dart
//
// 小程序包里的 `metadata.json`。
//
// 为什么要这么一个文件：服务端只知道「包在哪、sha256 是多少、版本号是几」，
// 而这些是**分发信息**，不是**应用信息**。真正能说明「我是谁、我要什么权限」
// 的应该是包自己 —— 就像 Android 应用的 AndroidManifest.xml。
// 没有它，权限页只能拿市场数据里的声明凑合，而市场数据是可以和包不一致的。
//
// 包根目录放一个 metadata.json：
//
//   {
//     "id": "com.example.notes",
//     "name": "记事本",
//     "version": "1.2.0",
//     "entry": "index.html",
//     "description": "本地优先的记事本",
//     "author": "someone",
//     "icon": "icon.png",
//     "permissions": ["camera", "bluetooth"],
//     "minFrameworkVersion": "0.2.0"
//   }
//
// 约定：
//   * `id` 必须与包里被安装到的 appId 一致。不一致直接拒绝安装 ——
//     否则一个包可以顶着别人的 id 拿到别人已授权的权限。
//   * `permissions` 里写的是 MiniappPermission 的 id，与浏览器权限名基本一致：
//     camera / microphone / displayCapture / speakerSelection /
//     pictureInPicture / location / accelerometer / gyroscope / magnetometer /
//     ambientLight / proximity / gamepad / vibrate / midi / bluetooth / usb /
//     serial / nfc / networkInfo / webauthn / clipboard / sdcard /
//     notifications / battery / deviceMemory / print。
//     写错的 id 不会让安装失败，但会在权限页作为「未知声明」列出来，
//     方便作者发现。
//   * 定位只写 `location` 一项：精度（精确/近似）与是否允许后台不是声明的
//     东西，而是用户在权限管理里单独设置的授权维度。
//   * `entry` 缺省 index.html；`version` 缺省用服务端给的版本（更新检查以
//     服务端为准，包里这个字段用于展示与本机记录）。
//   * `minFrameworkVersion` 缺省不限制；高于宿主框架版本时拒绝安装，
//     而不是让小程序在缺 API 的宿主上白屏。

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

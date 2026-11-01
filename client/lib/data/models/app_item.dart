// lib/data/models/app_item.dart
//
// 应用市场里的一个应用（对应 index.json 的 apps[] 元素）。
//
// 字段对应关系（含可选增补）：
//   id / name / description / category / version / author / url / size / updated_at / tags
//   icon         图标地址（可写相对路径，如 "icons/demo.png"，会基于服务器地址解析）
//   screenshots  截图列表（可选）
//   homepage     项目主页（可选）
//   permissions  这个小程序会用到哪些受控能力（可选，见 miniapp_permission.dart）
//
// `permissions` 是 0.2 之后加的字段，也是"权限"这件事在**市场侧**的表达：
// 小程序把自己的能力需求写在市场数据里，宿主在打开它之前就能一次性问清楚，
// 而不是等它悄悄调到第三个 API 时才开始一个个弹窗。声明只是"提前告知"，
// 不等于授权 —— 用户仍然要确认（见 pages/permissions/permission_prompt.dart）。

import 'json_utils.dart';
import 'miniapp_permission.dart';

class AppItem {
  const AppItem({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.version,
    required this.author,
    required this.packageUrl,
    this.packageEntry = 'index.html',
    this.packageSha256 = '',
    this.packageBytes = 0,
    this.icon,
    this.homepage,
    this.size = 0,
    this.tags = const <String>[],
    this.screenshots = const <String>[],
    this.permissions = const <String>[],
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final String category;
  final String version;
  final String author;

  /// 小程序包的下载地址（0.6 起）。
  ///
  /// 为空表示这个条目还没上架包 —— 客户端显示「暂不可用」而不是白屏。
  /// 这是一个绝对地址（服务端拼好的）。
  final String packageUrl;

  /// 包内入口文件的相对路径（默认 index.html）
  final String packageEntry;

  /// 包的 SHA-256（十六进制）。下载后必须校验。
  final String packageSha256;

  /// 包体积（字节）
  final int packageBytes;

  /// 图标地址（支持相对路径，可为空 —— UI 会用名称首字生成占位图标）
  final String? icon;

  /// 项目主页（可选）
  final String? homepage;

  /// 包体积（字节）。也接受 `"2.3 MB"` 这种人类可读写法。
  final int size;

  final List<String> tags;
  final List<String> screenshots;

  /// index.json 里声明的受控能力 id（未知 id 会被忽略，见 [declaredPermissions]）
  final List<String> permissions;

  final DateTime? updatedAt;

  /// 宽松解析。id 与 name 全缺失时返回 null（这种条目既不能渲染也没法去重）。
  static AppItem? fromJson(Map<String, dynamic> json) {
    final String id = asString(json['id']);
    final String name = asString(json['name']);
    if (id.isEmpty && name.isEmpty) return null;

    return AppItem(
      id: id.isEmpty ? name : id,
      name: name.isEmpty ? id : name,
      description: asString(json['description'], fallback: '暂无简介'),
      category: asString(json['category'], fallback: 'uncategorized'),
      version: asString(json['version'], fallback: '1.0.0'),
      author: asString(json['author'], fallback: '未知作者'),
      // 字段名与服务端 DTO 一致（camelCase）。旧的 `url` 字段不再读取 ——
      // 远程网页那条路已经删了，留着它只会让「为什么打不开」更难查。
      packageUrl: asString(json['packageUrl']),
      packageEntry: asString(json['packageEntry'], fallback: 'index.html'),
      packageSha256: asString(json['packageSha256']),
      packageBytes: asInt(json['packageBytes']),
      icon: asStringOrNull(json['icon']),
      homepage: asStringOrNull(json['homepage']),
      size: asByteSize(json['size']),
      tags: asStringList(json['tags']),
      screenshots: asStringList(json['screenshots']),
      permissions: asStringList(json['permissions'] ?? json['required_permissions']),
      updatedAt: asDateTime(json['updated_at'] ?? json['updatedAt']),
    );
  }

  /// 体积展示：`1.2 MB` / `128 KB` / `—`
  String get sizeLabel {
    if (size <= 0) return '体积未知';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get updatedAtLabel => formatDateTimeLabel(updatedAt);

  /// 是否有可打开的小程序（有包可下 / 已装）
  bool get canOpen => packageUrl.trim().isNotEmpty;

  /// 包的展示体积
  String get packageSizeLabel {
    if (packageBytes <= 0) return '体积未知';
    if (packageBytes < 1024) return '$packageBytes B';
    if (packageBytes < 1024 * 1024) {
      return '${(packageBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(packageBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 声明里能识别出来的受控权限。
  /// 顺序按 [MiniappPermission.values] 固定，保证界面上清单不会因数据书写顺序而跳动。
  ///
  /// 注意：这一版只有摄像头 / 麦克风 / 管理所有文件三项是「权限」。
  /// 市场数据里如果还写着 network、storage 这类旧 id，它们会落进
  /// [unknownPermissionIds] —— 那是**预期行为**：那些能力已经不需要授权了，
  /// 详情页会明确说明「已不再需要授权」，而不是假装它们还是权限。
  List<MiniappPermission> get declaredPermissions {
    final Set<MiniappPermission> wanted = permissions
        .map((String id) => MiniappPermission.byId(id))
        .whereType<MiniappPermission>()
        .toSet();
    return MiniappPermission.values
        .where(wanted.contains)
        .toList(growable: false);
  }

  /// 声明里认不出来的 id。
  ///
  /// 分成两类，因为它们的含义完全不同：
  ///   * [retiredPermissionIds] —— 曾经是权限、现在已不需要授权（network / storage …）。
  ///     老数据里写着很正常，不该当成错误；
  ///   * [unknownPermissionIds] —— 真正拼错的 id（例如 camra），需要提醒维护者。
  List<String> get unknownPermissionIds => permissions
      .where(
        (String id) =>
            MiniappPermission.byId(id) == null &&
            !MiniappPermission.isRetired(id),
      )
      .toList(growable: false);

  /// 声明里那些「已退役」的旧权限 id（不再需要授权，但仍然可用）
  List<String> get retiredPermissionIds => permissions
      .where(
        (String id) =>
            MiniappPermission.byId(id) == null &&
            MiniappPermission.isRetired(id),
      )
      .toList(growable: false);

  /// 本地搜索用的拼接串（名称 / 作者 / 简介 / 分类 / 标签 / 版本）
  String get searchBlob =>
      '$name $author $description $category $version ${tags.join(' ')}'.toLowerCase();

  /// 把相对路径解析成绝对地址（index.json 允许 url / icon / screenshots 写相对路径）
  static String resolveUrl(String base, String path) {
    final String value = path.trim();
    if (value.isEmpty) return '';
    final Uri? uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return value; // 已是绝对地址
    try {
      final String normalizedBase = base.endsWith('/') ? base : '$base/';
      return Uri.parse(normalizedBase).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  /// 用服务器地址把内部所有相对地址解析成绝对地址。
  /// 放在 Repository 里调用，这样 UI 层拿到的永远是可直接使用的地址。
  AppItem resolveAgainst(String base) => AppItem(
        id: id,
        name: name,
        description: description,
        category: category,
        version: version,
        author: author,
        // 包地址不动：服务端已经拼成绝对地址了（客户端要直接拿去下载）
        packageUrl: packageUrl,
        packageEntry: packageEntry,
        packageSha256: packageSha256,
        packageBytes: packageBytes,
        icon: icon == null ? null : resolveUrl(base, icon!),
        homepage: homepage,
        size: size,
        tags: tags,
        screenshots: screenshots
            .map((String item) => resolveUrl(base, item))
            .where((String item) => item.isNotEmpty)
            .toList(growable: false),
        permissions: permissions,
        updatedAt: updatedAt,
      );

  @override
  String toString() => 'AppItem($id, $name, $category)';
}

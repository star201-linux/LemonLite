
import 'category.dart';
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
    this.categories = const <AppCategory>[],
    this.tags = const <String>[],
    this.screenshots = const <String>[],
    this.permissions = const <String>[],
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;

  /// 主分类 id（服务端 apps.category_id）。
  ///
  /// 保留它是因为客户端有些地方只认一个分类（比如搜索的 category 参数）；
  /// 完整的归类在 [categories] 里 —— 0.6 起一个应用可以属于多个分类。
  final String category;
  final String version;
  final String author;

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

  /// 完整分类列表（服务端返回的 `categories` 数组：`[{id, name}]`）。
  ///
  /// 服务端为主分类保留了 `category` 字段，多分类关系只在这里。
  /// 详情页展示「分类」用它的 name 拼接，不再自己猜。
  final List<AppCategory> categories;

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
      packageUrl: asString(json['packageUrl']),
      packageEntry: asString(json['packageEntry'], fallback: 'index.html'),
      packageSha256: asString(json['packageSha256']),
      packageBytes: asInt(json['packageBytes']),
      icon: asStringOrNull(json['icon']),
      homepage: asStringOrNull(json['homepage']),
      size: asByteSize(json['size']),
      categories: asMapList(json['categories'])
          .map(AppCategory.fromJson)
          .whereType<AppCategory>()
          .toList(growable: false),
      tags: asStringList(json['tags']),
      screenshots: asStringList(json['screenshots']),
      permissions: asStringList(
        json['permissions'] ?? json['required_permissions'],
      ),
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

  List<MiniappPermission> get declaredPermissions {
    final Set<MiniappPermission> wanted = permissions
        .map((String id) => MiniappPermission.byId(id))
        .whereType<MiniappPermission>()
        .toSet();
    return MiniappPermission.values
        .where(wanted.contains)
        .toList(growable: false);
  }

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
      '$name $author $description $category $version ${tags.join(' ')}'
          .toLowerCase();

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
    categories: categories,
    tags: tags,
    screenshots: screenshots
        .map((String item) => resolveUrl(base, item))
        .where((String item) => item.isNotEmpty)
        .toList(growable: false),
    permissions: permissions,
    updatedAt: updatedAt,
  );

  /// 落盘用（主页 / 搜索的本地缓存）。
  ///
  /// 字段名与 [fromJson] 完全对称，所以 `fromJson(toJson())` 是恒等变换。
  /// 注意这里写的是**已经解析过的绝对地址**（resolveAgainst 之后的对象）——
  /// 缓存只在同一台服务器下有效，换了服务器整份缓存会被丢弃
  ///（见 MarketCacheService 里的 server 字段）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'category': category,
    'version': version,
    'author': author,
    'packageUrl': packageUrl,
    'packageEntry': packageEntry,
    'packageSha256': packageSha256,
    'packageBytes': packageBytes,
    'icon': icon,
    'homepage': homepage,
    'size': size,
    'categories': categories
        .map((AppCategory c) => <String, dynamic>{'id': c.id, 'name': c.name})
        .toList(growable: false),
    'tags': tags,
    'screenshots': screenshots,
    'permissions': permissions,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  @override
  String toString() => 'AppItem($id, $name, $category)';
}

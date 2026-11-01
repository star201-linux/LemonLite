// lib/data/models/category.dart
//
// index.json 里的分类条目：`{ "id": "tools", "name": "工具" }`

import 'json_utils.dart';

class AppCategory {
  const AppCategory({required this.id, required this.name});

  final String id;
  final String name;

  /// 特殊分类 id：主页「全部」chip 用（不对应 index.json 里的真实分类）
  static const String allId = 'all';

  /// 宽松解析：任何字段都不抛异常，缺 id 时拿 name 兜底，
  /// 两个都没有则返回 null，由调用方过滤掉。
  static AppCategory? fromJson(Map<String, dynamic> json) {
    final String id = asString(json['id']);
    final String name = asString(json['name'], fallback: id);
    if (id.isEmpty && name.isEmpty) return null;
    return AppCategory(id: id.isEmpty ? name : id, name: name.isEmpty ? id : name);
  }

  @override
  bool operator ==(Object other) =>
      other is AppCategory && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'AppCategory($id, $name)';
}

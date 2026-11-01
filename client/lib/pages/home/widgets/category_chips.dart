// lib/pages/home/widgets/category_chips.dart
//
// 分类筛选 chips（横向滚动）。
// 用 M3 的 FilterChip：选中态自带「勾选 + 填充色」，不用自己管理视觉状态。
// 每个 chip 上带该分类的应用数量，用户不用点进去就知道里面有没有东西。

import 'package:flutter/material.dart';

import '../../../data/models/category.dart';

class CategoryChips extends StatelessWidget {
  const CategoryChips({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.countOf,
    required this.onSelected,
  });

  final List<AppCategory> categories;
  final String selectedId;

  /// 传入函数而不是 Map，避免每次 build 都重建映射表
  final int Function(String categoryId) countOf;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: categories.length,
        separatorBuilder: (BuildContext context, int index) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final AppCategory category = categories[index];
          final int count = countOf(category.id);
          return Center(
            child: FilterChip(
              label: Text('${category.name} · $count'),
              selected: category.id == selectedId,
              onSelected: (bool _) => onSelected(category.id),
            ),
          );
        },
      ),
    );
  }
}

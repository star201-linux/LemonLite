// lib/pages/home/widgets/category_chips.dart
//
// 分类筛选 chips（横向滚动，MD3 Expressive）。
//
// 为什么不用 Material 的 FilterChip 了：
//   M3E 的 chip 是更大的药丸（更高、更圆的角），选中态用 primaryContainer，
//   未选中用 surfaceContainerHigh；默认 FilterChip 的描边 + 勾选图标
//   在这里显得偏「表单」，不像一个可横向浏览的筛选带。
//   自己画一个 AnimatedContainer 反而更可控，也能做颜色过渡。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: categories.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(width: 10),
        itemBuilder: (BuildContext context, int index) {
          final AppCategory category = categories[index];
          final int count = countOf(category.id);
          return Center(
            child: _CategoryChip(
              label: category.name,
              count: count,
              selected: category.id == selectedId,
              onTap: () {
                HapticFeedback.selectionClick();
                onSelected(category.id);
              },
            ),
          );
        },
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    final Color background = selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
    final Color foreground = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: '$label，$count 个应用',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(999),
              border: selected
                  ? null
                  : Border.all(color: scheme.outlineVariant, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (selected) ...<Widget>[
                  Icon(Icons.check_rounded, size: 16, color: foreground),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: textTheme.labelLarge?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: textTheme.labelSmall?.copyWith(
                    color: foreground.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

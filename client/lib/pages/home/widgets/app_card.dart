// lib/pages/home/widgets/app_card.dart
//
// 应用卡片。
//
// 为什么用「列表卡片」而不是网格：市场条目要展示 简介 + 作者 + 标签，
// 网格在大字体 / 长中文名称下极易溢出（要么截断得很难看，要么直接溢出报错）。
// 列表卡片在手机上一屏也能放 4~5 个，信息密度与可读性都更好。
// 用 Card.outlined（描边卡片）而不是填充色卡片，视觉层级更轻，
// 也更符合 M3 里「列表容器」的用法。
//
// 动效上有两处刻意的加法：
//   * 按压缩放（0.975）：手指按下去时卡片有「被压下」的反馈，
//     由 InkWell 的高亮回调驱动，所以它和水波纹是同一个时机。
//   * 图标的 Hero：与详情页共享 tag，点进详情时图标飞过去。
// 性能上的两处减法：
//   * 每张卡片包一层 RepaintBoundary —— 水波纹 / 按压动画只重画这一张，
//     不会带着整条列表一起重画。
//   * 图标按显示尺寸解码（见 app_icon.dart 里的 cacheWidth）。

import 'package:flutter/material.dart';

import '../../../data/models/app_item.dart';
import '../../../theme/motion.dart';
import 'app_icon.dart';

class AppCard extends StatefulWidget {
  const AppCard({super.key, required this.app, required this.onTap});

  final AppItem app;
  final VoidCallback onTap;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  /// 按压动画的状态句柄：由 InkWell 的高亮回调驱动
  final GlobalKey<PressableScaleState> _pressKey = GlobalKey<PressableScaleState>();

  @override
  Widget build(BuildContext context) {
    final AppItem app = widget.app;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return RepaintBoundary(
      child: PressableScale(
        key: _pressKey,
        scale: 0.975,
        child: Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias, // 让水波纹被卡片圆角裁掉
          child: InkWell(
            onTap: widget.onTap,
            onHighlightChanged: (bool pressed) =>
                _pressKey.currentState?.setPressed(pressed),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AppIcon(
                    name: app.name,
                    iconUrl: app.icon,
                    heroTag: 'app-icon:${app.id}',
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                app.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _VersionPill(version: app.version),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          app.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          app.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (app.tags.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: app.tags
                                .take(3)
                                .map((String tag) => _TagPill(text: tag))
                                .toList(growable: false),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 版本号小徽标
class _VersionPill extends StatelessWidget {
  const _VersionPill({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'v$version',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 标签小徽标
class _TagPill extends StatelessWidget {
  const _TagPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

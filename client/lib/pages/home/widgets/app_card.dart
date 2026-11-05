// lib/pages/home/widgets/app_card.dart
//
// 应用卡片（MD3 Expressive）。
//
// 视觉语言：
//   * 28dp 大圆角填充卡片（surfaceContainerLow），不再用描边卡片；
//   * 标题用 titleLarge + 600 字重，简介保持两行；
//   * 版本号 / 标签都是药丸形 tonal chip；
//   * 右侧一枚圆形箭头，明确「可点进去」；
//   * 按压缩放 + Hero 图标，保留原来两处便宜但有效的反馈。
//
// 为什么仍是列表卡片而不是网格：中文长名称 + 简介 + 标签在网格里极易溢出，
// 列表在手机一屏也能放 4~5 个，信息密度与可读性更好。

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
  final GlobalKey<PressableScaleState> _pressKey =
      GlobalKey<PressableScaleState>();

  @override
  Widget build(BuildContext context) {
    final AppItem app = widget.app;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return RepaintBoundary(
      child: PressableScale(
        key: _pressKey,
        scale: 0.975,
        child: Card.filled(
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: InkWell(
            onTap: widget.onTap,
            onHighlightChanged: (bool pressed) =>
                _pressKey.currentState?.setPressed(pressed),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AppIcon(
                    name: app.name,
                    iconUrl: app.icon,
                    size: 60,
                    heroTag: 'app-icon:${app.id}',
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                app.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: -0.2,
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
                          style: textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          app.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                        if (app.tags.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 10),
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
                  const SizedBox(width: 8),
                  _ArrowBubble(onTap: widget.onTap),
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
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'v$version',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 标签小徽标（tonal，药丸形）
class _TagPill extends StatelessWidget {
  const _TagPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onTertiaryContainer),
      ),
    );
  }
}

/// 右侧圆形箭头：把「可点」从水波纹里再明确一次。
class _ArrowBubble extends StatelessWidget {
  const _ArrowBubble({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

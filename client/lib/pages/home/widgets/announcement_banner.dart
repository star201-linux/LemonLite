// lib/pages/home/widgets/announcement_banner.dart
//
// 市场页顶部的公告横幅（级别 2）。
//
// 为什么是「横幅」而不是 SnackBar / 顶部弹层：
//   * SnackBar 会被「网络错误」「更新提示」挤掉，也可能正好遮住底部的操作栏；
//   * 浮层（Overlay）要自己算导航栏高度，平板/折叠屏上容易压到内容。
//   横幅插在列表里，滚动时跟着走，不抢任何人的位置。
//
// 配色只用 `ColorScheme`：公告横幅最怕「一眼看上去像第三方广告」，
// 用 primaryContainer 它就永远和 App 的主题色同族，深浅色模式也自动跟随。

import 'package:flutter/material.dart';

import '../../../data/models/announcement.dart';
import '../../settings/announcements_page.dart';

class AnnouncementBanner extends StatelessWidget {
  const AnnouncementBanner({
    super.key,
    required this.announcement,
    required this.onDismiss,
  });

  final Announcement announcement;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(AnnouncementsPage.route()),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.campaign_rounded,
                    size: 20,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        announcement.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        announcement.content,
                        // 两行：足够看清「这是什么事」，又不至于把市场内容顶下去。
                        // 想看全文点一下进公告页。
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer.withValues(
                            alpha: 0.85,
                          ),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: onDismiss,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: scheme.onPrimaryContainer,
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

// lib/pages/settings/announcement_dialog.dart
//
// 启动时弹出的公告（级别 3 / 4）。
//
// 谁来弹、弹几次由 AnnouncementService 决定：
//   * 级别 3：点过「确定」之后这台设备不再出现；
//   * 级别 4：每次启动都弹，直到运营发布下一条公告。
//
// 弹窗本身是无状态的 —— 它只负责显示和回调 onConfirm，
// 「记住已读」那件事不放在 UI 里（那会让这个 dialog 和本地存储耦合）。
//
// 内容可能很长（更新说明、活动规则），所以正文放在可滚动的容器里，
// 高度上限按屏幕高度算 —— 写死一个像素值在平板上会显得像被截断。

import 'package:flutter/material.dart';

import '../../data/models/announcement.dart';
import 'announcements_page.dart';

class AnnouncementDialog extends StatelessWidget {
  const AnnouncementDialog({
    super.key,
    required this.announcement,
    this.onConfirm,
  });

  final Announcement announcement;

  /// 点「确定」之后要做的事（通常是标记已读）。
  /// 先关弹窗再回调，避免回调里 await 存储时界面还压着。
  final Future<void> Function()? onConfirm;

  /// 返回值无意义；调用方只用它来「等弹窗关掉」。
  static Future<void> show(
    BuildContext context, {
    required Announcement announcement,
    Future<void> Function()? onConfirm,
  }) async {
    await showDialog<void>(
      context: context,
      // 公告是「通知」：点空白关掉等于没看见，会被当成没发过
      barrierDismissible: false,
      builder: (BuildContext ctx) =>
          AnnouncementDialog(announcement: announcement, onConfirm: onConfirm),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.5;
    final bool sticky = announcement.level == AnnouncementLevel.sticky;

    return AlertDialog(
      icon: Icon(
        sticky ? Icons.priority_high_rounded : Icons.campaign_outlined,
        color: sticky ? scheme.error : scheme.primary,
      ),
      title: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          announcement.title,
          textAlign: TextAlign.center,
          style: textTheme.titleMedium,
        ),
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                announcement.publishedLabel,
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                announcement.content,
                style: textTheme.bodyMedium?.copyWith(height: 1.55),
              ),
              if (sticky) ...<Widget>[
                const SizedBox(height: 16),
                // 级别 4 的弹窗是「每次启动都弹」，不解释一句的话，
                // 用户的合理推断是「这 App 有毛病，关不掉」。
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这条公告在新公告发布前会每次启动时提醒',
                          style: textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            final NavigatorState navigator = Navigator.of(context);
            navigator.pop();
            navigator.push(AnnouncementsPage.route());
          },
          child: const Text('历史公告'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            // 回调放在 pop 之后：标记已读要写本地存储，
            // 等界面收起来再写，不会有「点了没反应」的错觉。
            onConfirm?.call();
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

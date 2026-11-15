// lib/pages/settings/announcement_dialog.dart
//
// 启动时弹出的公告。
//
// 触发点在 AppShell：每次启动拉一次 `/api/announcements/latest`，
// 有公告就弹。**不做「已读就不再弹」** —— 运营发公告的目的就是让所有人看到，
// 而「已读」状态一旦本地化，换台设备、清一次数据就会重新弹，
// 反而比「每次都弹」更难解释。嫌烦的话，发公告的人自然会少发。
//
// 内容可能很长（更新说明、活动规则），所以正文放在可滚动的容器里，
// 高度上限按屏幕高度算 —— 写死一个像素值在平板上会显得像被截断。

import 'package:flutter/material.dart';

import '../../data/models/announcement.dart';
import 'announcements_page.dart';

class AnnouncementDialog extends StatelessWidget {
  const AnnouncementDialog({super.key, required this.announcement});

  final Announcement announcement;

  /// 返回值无意义；调用方只用它来「等弹窗关掉」。
  static Future<void> show(
    BuildContext context, {
    required Announcement announcement,
  }) async {
    await showDialog<void>(
      context: context,
      // 公告是「通知」：点空白关掉等于没看见，会被当成没发过
      barrierDismissible: false,
      builder: (BuildContext ctx) =>
          AnnouncementDialog(announcement: announcement),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.5;

    return AlertDialog(
      icon: Icon(Icons.campaign_outlined, color: scheme.primary),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}

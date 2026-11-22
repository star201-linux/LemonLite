
import 'package:flutter/material.dart';

class SessionOfflineDialog extends StatelessWidget {
  const SessionOfflineDialog({super.key, required this.reason});

  /// 服务端给的失效原因（如「登录已失效，请重新登录」），可能为空
  final String reason;

  /// 返回 true 表示用户选择「去登录」。
  static Future<bool> show(BuildContext context, {required String reason}) async {
    final bool? go = await showDialog<bool>(
      context: context,
      // 这是「通知」不是「选择」：点空白关掉会让用户以为没发生过
      barrierDismissible: false,
      builder: (BuildContext ctx) => SessionOfflineDialog(reason: reason),
    );
    return go == true;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String detail = reason.trim();

    return AlertDialog(
      icon: Icon(Icons.link_off, color: scheme.error),
      title: const Text('账号已下线'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '这台设备的登录已失效：可能是在别的设备退了登录、被管理员下线，或者登录已过期。',
            style: textTheme.bodyMedium,
          ),
          if (detail.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              detail,
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '本机的小程序、设置与数据都不受影响，重新登录即可继续。',
            style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('知道了'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('去登录'),
        ),
      ],
    );
  }
}

// lib/pages/home/widgets/app_icon.dart
//
// 应用图标。三种情况都要好看：
//   1. 有图标并且能加载 → 网络图片
//   2. 加载中 → 转圈占位（避免布局跳动）
//   3. 没有图标 / 加载失败 → 用名称首字 + 主题色生成占位图标
// M3 的 App 图标习惯是「圆角方形」，所以统一用 28% 圆角裁切。

import 'package:flutter/material.dart';

class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.name, this.iconUrl, this.size = 56});

  final String name;
  final String? iconUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? url = iconUrl;

    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: SizedBox(
        width: size,
        height: size,
        child: (url == null || url.isEmpty)
            ? _fallback(scheme)
            : Image.network(
                url,
                semanticLabel: '$name 应用图标',
                fit: BoxFit.cover,
                // 图标加载失败不应该让卡片报错，直接退回占位图标
                errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                    _fallback(scheme),
                loadingBuilder:
                    (BuildContext c, Widget child, ImageChunkEvent? progress) {
                      if (progress == null) return child;
                      return _fallback(scheme, loading: true);
                    },
              ),
      ),
    );
  }

  Widget _fallback(ColorScheme scheme, {bool loading = false}) {
    return ColoredBox(
      color: scheme.secondaryContainer,
      child: Center(
        child: loading
            ? SizedBox(
                width: size * 0.32,
                height: size * 0.32,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onSecondaryContainer,
                ),
              )
            : Text(
                _initial,
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: size * 0.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }

  String get _initial {
    final String text = name.trim();
    if (text.isEmpty) return '?';
    return text.substring(0, 1).toUpperCase();
  }
}

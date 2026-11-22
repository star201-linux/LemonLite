
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material3_expressive_loading_indicator/material3_expressive_loading_indicator.dart';

/// 圆形加载指示器：形状蠕动 + 旋转。
class M3ELoadingIndicator extends StatelessWidget {
  const M3ELoadingIndicator({
    super.key,
    this.size,
    this.color,
    this.semanticsLabel = '加载中',
  });

  /// 行内尺寸（按钮、列表 leading、角标）。
  const M3ELoadingIndicator.inline({
    super.key,
    this.size = 18,
    this.color,
    this.semanticsLabel = '加载中',
  });

  /// 边长（逻辑像素）。为 null 时遵循父级紧约束，否则按屏幕自动选 48 / 32。
  final double? size;

  /// 默认取主题的 primary
  final Color? color;

  final String semanticsLabel;

  /// 手机 48、手表 32 —— 对应 M3 的默认档与可穿戴档。
  static double autoSize(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide < 320 ? 32 : 48;

  @override
  Widget build(BuildContext context) {
    final Color resolved = color ?? Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints c) {
        final double s = _resolveSize(ctx, c);
        // 底层的形状是**按 38/48 的比例**画在 48×48 容器里的，容器给小了
        // 形状不会跟着缩，而是直接溢出（按钮里那个白块压住文字就是这么来的）。
        // 所以固定用 48×48 渲染，再用 FittedBox 整体缩放到目标尺寸 ——
        // 视觉比例与规范一致（48 容器 / 38 活动形状），也不会溢出。
        return SizedBox(
          width: s,
          height: s,
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 48,
              height: 48,
              child: ExpressiveLoadingIndicator(
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                color: resolved,
                semanticsLabel: semanticsLabel,
              ),
            ),
          ),
        );
      },
    );
  }

  double _resolveSize(BuildContext context, BoxConstraints c) {
    final double? explicit = size;
    if (explicit != null) return explicit;
    final bool tight =
        c.hasBoundedWidth &&
        c.hasBoundedHeight &&
        (c.maxWidth - c.minWidth).abs() < 0.5 &&
        (c.maxHeight - c.minHeight).abs() < 0.5;
    if (tight) return math.min(c.maxWidth, c.maxHeight);
    return autoSize(context);
  }
}

/// 线性进度条：波浪滚动。值给 null 就是不确定进度（indeterminate）。
class M3ELinearProgressIndicator extends StatelessWidget {
  const M3ELinearProgressIndicator({
    super.key,
    this.value,
    this.height,
    this.color,
    this.trackColor,
    this.showStopIndicator = true,
    this.semanticsLabel,
  });

  /// 0…1；null = 不确定进度
  final double? value;

  /// 未指定时：手机 8、手表 6
  final double? height;

  final Color? color;
  final Color? trackColor;

  /// 末端小圆点（M3 的 determinate 线性条规范里有；不确定模式下不画）
  final bool showStopIndicator;

  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool compact = MediaQuery.sizeOf(context).shortestSide < 320;
    final double barHeight = height ?? (compact ? 6 : 8);

    return ExpressiveLinearProgressIndicator(
      value: value,
      minHeight: barHeight,
      color: color ?? scheme.primary,
      backgroundColor: trackColor ?? scheme.surfaceContainerHighest,
      amplitude: 1,
      borderRadius: BorderRadius.circular(barHeight),
      stopIndicatorRadius: showStopIndicator ? barHeight / 2 : 0,
      semanticsLabel: semanticsLabel,
    );
  }
}

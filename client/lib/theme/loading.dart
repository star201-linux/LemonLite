// lib/theme/loading.dart
//
// M3 Expressive 加载指示器（统一入口）。
//
// 为什么不用 Flutter 自带的 CircularProgressIndicator：
//   Material 3 Expressive 把「转圈」重新设计成了**形状蠕动**——一个 12 边形
//   在几个圆角多边形之间来回变形，同时整体缓慢旋转；线性进度条则变成一条
//   滚动的波浪。自带的 CircularProgressIndicator 还是 M2 时代的匀速圆环，
//   放在这套 UI 里会像另一个年代的控件。
//
// 底层用 material3_expressive_loading_indicator（内置在 third_party/，
// 从 AndroidX `LoadingIndicator.kt` 移植，形状数据与弹簧动画对齐规范）。
// 这里只做三件事：**尺寸策略、颜色取主题、语义标签**。
//
// 尺寸为什么要分档（手机 / 手表 / 行内）：
//   * 手机上 M3 的默认是 48dp 容器（活动形状 38dp），整屏加载状态用它；
//   * 手表（shortestSide < 320）上 48dp 会占掉小圆屏很大一块，规范给的是
//     更小的一档，这里取 32dp，线性条也变细、去掉末端圆点；
//   * 按钮里、列表 leading、角标这种行内位置用 16–20dp —— 再大就会把
//     控件撑变形，形状蠕动在这个尺寸下也看不出来，但旋转仍然在动。
//
// 调用约定：
//   * 整屏 / 大块内容 → `const M3ELoadingIndicator()`（按屏幕自动选 48 / 32）
//   * 已经被 SizedBox 框住的 → 直接写 `const M3ELoadingIndicator()`，
//     它会跟随父级的紧约束（见 _resolveSize），不必重复写尺寸
//   * 按钮里 → `const M3ELoadingIndicator.inline()`（18，可用 size 覆盖）
//   * 进度条 → `M3ELinearProgressIndicator(value: …)`

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

  /// 尺寸优先级：显式 size → 父级紧约束 → 按屏幕自动。
  ///
  /// 为什么要看父级紧约束：绝大多数调用点已经用 `SizedBox(width: 20,
  /// height: 20)` 框住了原来的圆环，再让调用方重复写一遍 20 既啰嗦又容易
  /// 写错（写大了会被父级裁掉，写小了周围一圈空白）。
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
      // 波浪的振幅是「条高的一半减去描边」，条太细时振幅会被算成 0，
      // 看起来就是一条直线 —— 所以默认高度给到 8（手表 6），
      // 比规范的 4dp 粗，但这是这套实现里唯一能看见波浪的档位。
      amplitude: 1,
      borderRadius: BorderRadius.circular(barHeight),
      stopIndicatorRadius: showStopIndicator ? barHeight / 2 : 0,
      semanticsLabel: semanticsLabel,
    );
  }
}

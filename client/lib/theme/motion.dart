// lib/theme/motion.dart
//
// 可复用的动效组件。
//
// 为什么单独一个文件而不是塞进 app_theme.dart：
//   app_theme 负责「配色 / 字阶 / 转场」，是**配置**；
//   这里是**行为**（一段会跑起来的动画），两者改动频率完全不同。
//
// 两条自我约束：
//   1. 只用合成器负担得起的属性 —— 位移（Transform）与透明度（Opacity）。
//      整页缩放、逐帧变化的圆角裁剪都会让每一帧重新光栅化整屏，
//      在中间档手机上直接体现为掉帧。
//   2. 尊重系统的「减弱动态效果」（无障碍）：开了就跳过动画直接给结果。

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 一次性入场动画：淡入 + 轻微上移。
///
/// 用 `TweenAnimationBuilder` 而不是 `AnimationController`：
/// 列表项会随滚动反复创建，每个都持有 controller 的话要管 dispose、
/// 还要担心 Ticker 泄漏；隐式动画由框架自己管生命周期。
///
/// [index] 用来做错峰：第 0 个立刻开始，第 1 个晚 [delay]，以此类推。
/// 只对前 [maxStagger] 个生效 —— 否则第二页的第一条要等半秒才出现。
class StaggeredEntrance extends StatelessWidget {
  const StaggeredEntrance({
    super.key,
    required this.child,
    this.index = 0,
    this.delay = const Duration(milliseconds: 45),
    this.duration = const Duration(milliseconds: 320),
    this.offset = 14,
    this.maxStagger = 8,
  });

  final Widget child;
  final int index;
  final Duration delay;
  final Duration duration;
  final double offset;
  final int maxStagger;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;

    final int step = index.clamp(0, maxStagger);
    final int delayMs = delay.inMilliseconds * step;
    final int durationMs = duration.inMilliseconds;
    final int totalMs = durationMs + delayMs;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: totalMs),
      curve: Curves.linear,
      child: child,
      builder: (BuildContext context, double t, Widget? inner) {
        // 把「延迟」折进总时长里：前 delayMs 毫秒进度为 0，之后才真正开始动。
        final double raw = ((t * totalMs - delayMs) / durationMs).clamp(0.0, 1.0);
        final double eased = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, offset * (1 - eased)),
            child: inner,
          ),
        );
      },
    );
  }
}

/// 按压缩放：按下 0.97，松开回弹到 1。
///
/// 这是 M3E 里「触觉反馈」最便宜的一种表达 —— 只改一个 Transform 的 scale，
/// 不触发任何布局，也不需要额外的 controller（`AnimatedScale` 自带）。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.scale = 0.97,
    this.duration = M3EMotion.fast,
  });

  final Widget child;
  final double scale;
  final Duration duration;

  @override
  State<PressableScale> createState() => PressableScaleState();
}

class PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  /// 供父级（例如 InkWell 的 onHighlightChanged）驱动按压状态
  void setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return widget.child;
    }
    return AnimatedScale(
      scale: _pressed ? widget.scale : 1.0,
      duration: widget.duration,
      curve: Curves.easeOutCubic,
      child: widget.child,
    );
  }
}

/// 四态视图（加载 / 空 / 错误 / 内容）之间的交叉淡入。
///
/// 直接套一个 AnimatedSwitcher 就够，但切换时**位移方向**要一致：
/// 统一「新内容从下往上 3% 浮入」，不要一会儿横一会儿竖。
class StateTransition extends StatelessWidget {
  const StateTransition({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return AnimatedSwitcher(
      duration: M3EMotion.standard,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.03),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}


import 'package:flutter/material.dart';

import 'app_theme.dart';

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

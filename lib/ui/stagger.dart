import 'package:flutter/material.dart';

import 'motion.dart';

/// M-2（层次感 stagger）：一组元素依次出现，间隔 [stepMs]（规范 30–60ms）。
///
/// 口径：`ui-motion` v0.21 foundations「有层次」——不一起蹦出来。
/// 降级（系统减弱动画 / 省电）时**零 stagger、零位移直接显示**（DDS §24.2 R4）。
/// 播放时机 = 元素自身生命周期内一次；父级列表整体重建（换筛选、换分组）会再播一次，
/// 这是有意的：换内容即换一次入场，滚动回来不重播（元素未被回收时）。
class StaggerIn extends StatefulWidget {
  final int index;
  final Widget child;

  /// 每项间隔（30–60ms 带内）。
  final int stepMs;

  /// 单项自身时长（小元素档 150–250ms）。
  final int baseMs;

  /// 超过该序号不再排队，避免长列表尾部等太久（总时长仍 ≤700ms）。
  final int maxSteps;

  /// 关闭入场（例如列表项自身已有动画，避免叠两层）。
  final bool enabled;
  const StaggerIn({
    required this.index,
    required this.child,
    this.stepMs = 40,
    this.baseMs = 200,
    this.maxSteps = 10,
    this.enabled = true,
    super.key,
  });

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    final step = widget.stepMs.clamp(30, 60);
    final delay = widget.index.clamp(0, widget.maxSteps) * step;
    final total = delay + widget.baseMs;
    _c = AnimationController(
        vsync: this, duration: Duration(milliseconds: total));
    _anim = CurvedAnimation(
      parent: _c,
      curve: Interval(delay / total, 1, curve: Curves.easeOut),
    );
    if (widget.enabled) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    if (!widget.enabled || !policy.animates) return widget.child;
    return FadeTransition(
      opacity: _anim,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, 10 * (1 - _anim.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

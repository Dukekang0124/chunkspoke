import 'package:flutter/material.dart';

import 'motion.dart';

/// M1（#58 红点数字角标）：数字翻牌 + 角标轻弹 + 宽度平滑 + 清零缩小淡出。
///
/// 口径（`ui-motion` v0.21 · 58）：翻牌约 250ms ease-out；弹一下 1→1.2→1 约 300ms；
/// 宽度过渡约 200ms；消失 scale 1→0 + 淡出约 220ms。
/// 降级（减弱动画/省电）时数字直接换、角标直接显隐。
class BadgeCount extends StatefulWidget {
  final int count;
  final Widget child;
  final Color color;
  final Color textColor;

  /// 超过该值显示「cap+」（默认 99+，与规范一致）。
  final int cap;
  const BadgeCount({
    required this.count,
    required this.child,
    this.color = const Color(0xFFFF6B6B),
    this.textColor = Colors.white,
    this.cap = 99,
    super.key,
  });

  @override
  State<BadgeCount> createState() => _BadgeCountState();
}

class _BadgeCountState extends State<BadgeCount>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop;
  int _last = -1;

  @override
  void initState() {
    super.initState();
    _pop = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _last = widget.count;
    if (widget.count > 0) _pop.value = 1; // 首帧不再弹一下
  }

  @override
  void didUpdateWidget(covariant BadgeCount old) {
    super.didUpdateWidget(old);
    if (widget.count != old.count && widget.count > 0 && widget.count != _last) {
      final policy = Motion.of(context);
      if (policy.animates) _pop.forward(from: 0);
    }
    _last = widget.count;
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  String get _label =>
      widget.count > widget.cap ? '${widget.cap}+' : '${widget.count}';

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    final visible = widget.count > 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned(
          top: -4,
          right: -10,
          child: IgnorePointer(
            child: AnimatedScale(
              // 清零时缩到 0 并淡出，不是一下消失。
              scale: visible ? 1 : 0,
              duration: policy.dur(220),
              curve: Curves.easeIn,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: policy.dur(220),
                curve: Curves.easeIn,
                child: AnimatedBuilder(
                  animation: _pop,
                  builder: (_, child) => Transform.scale(
                    scale: 1 + 0.2 * _popCurve(_pop.value),
                    child: child,
                  ),
                  child: AnimatedContainer(
                    duration: policy.dur(200),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 18),
                    decoration: BoxDecoration(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: kBgBadgeRing, width: 1.5),
                    ),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: policy.dur(250),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, a) => FadeTransition(
                          opacity: a,
                          child: SlideTransition(
                            position: Tween<Offset>(
                                    begin: const Offset(0, .8),
                                    end: Offset.zero)
                                .animate(a),
                            child: child,
                          ),
                        ),
                        child: Text(_label,
                            key: ValueKey(_label),
                            style: TextStyle(
                                color: widget.textColor,
                                fontSize: 10,
                                height: 1.2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 弹一下：0→1 先冲到 1（约 60% 处最高），再回落，最大 0.2 倍放大。
  static double _popCurve(double t) =>
      t <= 0 || t >= 1 ? 0 : (t < .6 ? t / .6 : (1 - t) / .4);
}

const Color kBgBadgeRing = Color(0xFF1A1B2E);

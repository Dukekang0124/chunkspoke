import 'package:flutter/material.dart';

import 'motion.dart';

/// M-2（动效底线「有反馈」）：可点元素的按下态包装（共享 helper）。
/// 传 `onTap` 时自带点击；不传时只借指针事件做反馈，点击仍归内层组件。
///
/// 参数：按下缩到 [scale]（默认 0.97，规范 0.96–0.98），按下 60ms、松开 150ms；
/// 降级（减弱动画/省电）时不缩放，直接切换。触屏同样生效（不做 hover，那是鼠标端专属）。
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  /// 用于自身已有按压反馈的组件（InkWell 等）只想保留手势时置 false。
  final bool enableScale;

  /// 不可点（纯展示）时置 false：按下不反馈，避免误导。
  final bool enabled;
  const PressableScale({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.enableScale = true,
    this.enabled = true,
    super.key,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    final target =
        (widget.enableScale && widget.enabled && _down && policy.animates)
            ? widget.scale
            : 1.0;
    final scaled = AnimatedScale(
      scale: target,
      duration: policy.dur(_down ? 60 : 150),
      curve: Curves.easeOut,
      child: widget.child,
    );
    if (widget.onTap == null && widget.onLongPress == null) {
      // 只借指针事件做按下反馈，不进手势竞技场：点击仍由内层按钮自己处理。
      return Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: scaled,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      child: scaled,
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// M1：撒花共享组件（统一过闸）。
///
/// 定位：**氛围庆祝层**，只在真实状态变化时由调用方挂载（六步完成 / 复习升档 /
/// 关卡完成），无状态变化不得放（DDS §24.2 R1）。
///
/// 闸门口径：
///   - 系统「减弱动画」开启 → 整段不放，并在下一帧回调 [onDone]（调用方直接显示结果文案）；
///   - 省电模式 → 粒子减半；
///   - 时长 1800ms 属**氛围层豁免**（不套 150–250/300–450/450–600ms 三级带，见 DDS §24.1 豁免清单）。
class ConfettiBurst extends StatefulWidget {
  final int baseCount;
  final Duration duration;
  final VoidCallback? onDone;
  const ConfettiBurst(
      {super.key,
      this.baseCount = 60,
      this.duration = const Duration(milliseconds: 1800),
      this.onDone});

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _doneNotified = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration)
      ..forward().whenCompleteOrCancel(_notifyDone);
  }

  void _notifyDone() {
    if (_doneNotified || !mounted) return;
    _doneNotified = true;
    // 回调不得在 build 内触发，推到下一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onDone?.call());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    if (!policy.confettiOn) {
      _c.stop();
      _notifyDone();
      return const SizedBox.shrink();
    }
    final count = policy.particles(widget.baseCount);
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => CustomPaint(
          key: const ValueKey('confetti-layer'),
          size: Size.infinite,
          painter: _ConfettiPainter(_c.value, count),
        ),
      ),
    );
  }
}

/// 彩带粒子绘制（原 `screens/level.dart` 的 `_ConfettiPainter`，逐字节等价迁移）。
class _ConfettiPainter extends CustomPainter {
  final double t;
  final int count;
  _ConfettiPainter(this.t, this.count);
  final math.Random _rng = math.Random(7);
  static const _colors = [
    Color(0xFFFFB84D),
    Color(0xFF34D399),
    Colors.white,
    Color(0xFFF59E0B),
    Color(0xFF60A5FA),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < count; i++) {
      final x = _rng.nextDouble() * size.width;
      final y =
          (_rng.nextDouble() * size.height + t * size.height) % size.height;
      final c = _colors[i % _colors.length];
      final w = 6.0 + _rng.nextDouble() * 5;
      final h = 10.0 + _rng.nextDouble() * 6;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(_rng.nextDouble() * math.pi + t * 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: w, height: h),
            const Radius.circular(2)),
        Paint()..color = c.withValues(alpha: 1.0 - t * 0.25),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.t != t;
}

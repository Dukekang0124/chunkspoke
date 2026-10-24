import 'package:flutter/material.dart';

import 'motion.dart';

/// M1（#40 复制变勾 / #21 实时打勾）：对勾沿笔画一笔画出来。
///
/// 参数：描边 300ms（规范 300–350ms）ease-out；降级时直接显示完整对勾。
class CheckDraw extends StatefulWidget {
  final double size;
  final Color color;
  final double stroke;
  final int durationMs;

  /// 置 false 时不重播（例如列表里大量复用同一图标）。
  final bool animate;
  const CheckDraw({
    this.size = 18,
    this.color = const Color(0xFF34D399),
    this.stroke = 2.2,
    this.durationMs = 300,
    this.animate = true,
    super.key,
  });

  @override
  State<CheckDraw> createState() => _CheckDrawState();
}

class _CheckDrawState extends State<CheckDraw>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: Duration(milliseconds: widget.durationMs));
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    final full = !policy.animates || !widget.animate;
    return CustomPaint(
      size: Size(widget.size, widget.size),
      painter: _CheckPainter(
        progress: full ? 1.0 : _c.value,
        color: widget.color,
        stroke: widget.stroke,
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double stroke;
  _CheckPainter({
    required this.progress,
    required this.color,
    required this.stroke,
  });

  static Path _path(Size s) {
    return Path()
      ..moveTo(s.width * .20, s.height * .55)
      ..lineTo(s.width * .42, s.height * .75)
      ..lineTo(s.width * .80, s.height * .28);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = _path(size);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (progress >= 1) {
      canvas.drawPath(p, paint);
      return;
    }
    var total = 0.0;
    for (final m in p.computeMetrics()) {
      total += m.length;
    }
    for (final m in p.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, total * progress), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) =>
      old.progress != progress || old.color != color || old.stroke != stroke;
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';

/// M1（#38 播放暂停变形）：三角形与两竖条**顶点一一对应**插值，
/// 中间帧能看到三角形被「掰开」，而不是两个图标硬切。
///
/// 口径（`ui-motion` v0.21 · 38）：变形约 320ms（本波裁定收紧到 ≤200ms 的主传输键反馈档）、
/// 回弹超调 ≤8%、变形过程中整体转 90°（起止均为 0°，中段最大）。
/// 降级（减弱动画/省电）时直接显示目标图标。
class PlayPauseMorph extends StatelessWidget {
  final bool playing;
  final double size;
  final Color color;

  /// 主传输键 200ms；列表内小图标不接本组件（库内禁用场景）。
  final int durationMs;
  const PlayPauseMorph({
    required this.playing,
    this.size = 34,
    this.color = Colors.black,
    this.durationMs = 200,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    if (!policy.animates) {
      return Icon(playing ? Icons.pause : Icons.play_arrow,
          size: size, color: color);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: playing ? 1 : 0),
      duration: policy.dur(durationMs),
      curve: Curves.easeOut,
      builder: (_, t, __) => CustomPaint(
        key: const ValueKey('play-pause-morph'),
        size: Size.square(size),
        painter: _PlayPausePainter(t, color),
      ),
    );
  }
}

class _PlayPausePainter extends CustomPainter {
  final double t; // 0 = 播放三角，1 = 暂停双条
  final Color color;
  _PlayPausePainter(this.t, this.color);

  // 三角形拆成左右两块四边形，与暂停的两根竖条逐顶点对应。
  static const List<Offset> _playLeft = [
    Offset(-0.42, -0.50),
    Offset(0.04, -0.25),
    Offset(0.04, 0.25),
    Offset(-0.42, 0.50),
  ];
  static const List<Offset> _playRight = [
    Offset(0.04, -0.25),
    Offset(0.50, 0.00),
    Offset(0.50, 0.00),
    Offset(0.04, 0.25),
  ];
  static const List<Offset> _pauseLeft = [
    Offset(-0.42, -0.50),
    Offset(-0.14, -0.50),
    Offset(-0.14, 0.50),
    Offset(-0.42, 0.50),
  ];
  static const List<Offset> _pauseRight = [
    Offset(0.14, -0.50),
    Offset(0.42, -0.50),
    Offset(0.42, 0.50),
    Offset(0.14, 0.50),
  ];

  Path _quad(List<Offset> a, List<Offset> b, double t, double s) {
    final p = Path();
    for (var i = 0; i < 4; i++) {
      final x = (a[i].dx + (b[i].dx - a[i].dx) * t) * s;
      final y = (a[i].dy + (b[i].dy - a[i].dy) * t) * s;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    p.close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    // 变形途中转 90°，起止回到 0°（不改变最终朝向）。
    canvas.rotate(math.sin(t * math.pi) * math.pi / 2);
    canvas.drawPath(_quad(_playLeft, _pauseLeft, t, s), paint);
    canvas.drawPath(_quad(_playRight, _pauseRight, t, s), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlayPausePainter old) =>
      old.t != t || old.color != color;
}

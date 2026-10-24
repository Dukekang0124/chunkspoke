import 'package:flutter/material.dart';

import 'motion.dart';

/// M1（数字滚动）：数值变化时滚过去，不硬换。
///
/// 口径：count-up 450ms（上限 600ms，属「小元素/状态反馈」档的放宽），ease-out；
/// 首次构建从 0 滚到目标值；之后每次值变化从当前显示值滚到新值；
/// 降级（减弱动画/省电）时直接显示最终值。
class CountUpText extends StatelessWidget {
  final int value;
  final TextStyle? style;
  final int from;
  final int durationMs;

  /// 数字 → 文案（默认原样十进制）。前后缀文案请放在本 widget 之外，保持数字可独立滚动。
  final String Function(int v) format;
  const CountUpText(this.value,
      {this.style,
      this.from = 0,
      this.durationMs = 450,
      this.format = _defaultFormat,
      super.key});

  static String _defaultFormat(int v) => '$v';

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    if (!policy.animates) return Text(format(value), style: style);
    return TweenAnimationBuilder<int>(
      tween: IntTween(begin: from, end: value),
      duration: policy.dur(durationMs > 600 ? 600 : durationMs),
      curve: Curves.easeOut,
      builder: (_, v, __) => Text(format(v), style: style),
    );
  }
}

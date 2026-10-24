import 'dart:async';

import 'package:flutter/material.dart';

import 'check_mark.dart';
import 'motion.dart';
import 'theme.dart';

/// M1（#40 复制变勾）：复制反馈出现在按钮本身，不弹提示框。
///
/// 口径（`ui-motion` v0.21 · 40）：图标切换约 250ms、对勾描边约 300ms、
/// 文字向上滚动换词、约 2 秒后自动换回；降级时直接换图标与文案。
class CopyMorphButton extends StatefulWidget {
  /// 真正写剪贴板的动作（抛异常则不进入已复制态）。
  final Future<void> Function() copy;
  final String label;
  final String doneLabel;
  final CopyMorphVariant variant;
  final double fontSize;
  const CopyMorphButton({
    required this.copy,
    required this.label,
    this.doneLabel = '已复制',
    this.variant = CopyMorphVariant.outlined,
    this.fontSize = 14,
    super.key,
  });

  @override
  State<CopyMorphButton> createState() => _CopyMorphButtonState();
}

enum CopyMorphVariant { outlined, filled, text }

class _CopyMorphButtonState extends State<CopyMorphButton> {
  bool _copied = false;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await widget.copy();
    } catch (_) {
      if (mounted) setState(() => _copied = false);
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    _revert?.cancel();
    _revert = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final policy = Motion.of(context);
    final dur = policy.dur(250);
    final accent = widget.variant == CopyMorphVariant.filled
        ? Colors.black87
        : kPrimary;
    final icon = AnimatedSwitcher(
      duration: dur,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _copied
          ? const CheckDraw(key: ValueKey('ok'), size: 18, stroke: 2.4)
          : Icon(Icons.copy,
              key: const ValueKey('copy'), size: 16, color: accent),
    );
    // 文字向上滚动换词（进：从下方滑入并淡入；退：原路退回）。
    final text = AnimatedSwitcher(
      duration: dur,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => ClipRect(
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
      ),
      child: Text(_copied ? widget.doneLabel : widget.label,
          key: ValueKey(_copied),
          style: TextStyle(
              fontSize: widget.fontSize,
              color: _copied ? const Color(0xFF34D399) : accent)),
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [icon, const SizedBox(width: 6), text],
    );
    switch (widget.variant) {
      case CopyMorphVariant.filled:
        return ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: _start,
            child: row);
      case CopyMorphVariant.text:
        return TextButton(onPressed: _start, child: row);
      case CopyMorphVariant.outlined:
        return OutlinedButton(
            style: OutlinedButton.styleFrom(
                side: BorderSide(color: kPrimary.withValues(alpha: .5))),
            onPressed: _start,
            child: row);
    }
  }
}

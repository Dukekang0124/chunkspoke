import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/session.dart';
import '../data/vocab.dart';
import '../ui/theme.dart';

class _PlaceholderCard {
  final String front;
  final String back;
  const _PlaceholderCard(this.front, this.back);
}

const List<_PlaceholderCard> _demoCards = [
  _PlaceholderCard('get up', '起床；站起来'),
  _PlaceholderCard('on the way to work', '在上班路上'),
  _PlaceholderCard('make a decision', '做决定'),
];

/// 复习台骨架：卡片流 + 键盘流（空格翻面 / 1-3 自评 / Enter 下一个）。
/// 预置阶段只演示交互，不接内容包、不落库。
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<ReviewScreen> createState() => ReviewScreenState();
}

class ReviewScreenState extends State<ReviewScreen> {
  final FocusNode _focus = FocusNode(debugLabel: 'review-keyboard');
  int _index = 0;
  bool _flipped = false;
  ReviewGrade? _grade;
  int _graded = 0;

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      setState(() => _flipped = !_flipped);
    } else if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      _applyGrade(ReviewGrade.retry);
    } else if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      _applyGrade(ReviewGrade.keep);
    } else if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      _applyGrade(ReviewGrade.pass);
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _next();
    }
  }

  void _applyGrade(ReviewGrade grade) {
    setState(() => _grade = grade);
    _graded += 1;
    widget.session.markReviewed();
  }

  void _next() {
    setState(() {
      _index = (_index + 1) % _demoCards.length;
      _flipped = false;
      _grade = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final card = _demoCards[_index];
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '复习台',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const Spacer(),
                Text(
                  '占位卡 ${_index + 1}/${_demoCards.length} · 本次已评 $_graded',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Center(
                child: GestureDetector(
                  onTap: () => setState(() => _flipped = !_flipped),
                  child: Container(
                    width: 420,
                    height: 260,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _grade == null ? kLocked : _gradeColor(_grade!),
                        width: _grade == null ? 1 : 2,
                      ),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _flipped ? card.back : card.front,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: _flipped ? 22 : 30,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _flipped ? '空格翻回' : '空格翻面',
                            style: const TextStyle(color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _GradeChip(label: '1 重学', color: kError, active: _grade == ReviewGrade.retry),
                const SizedBox(width: 12),
                _GradeChip(
                  label: '2 保留',
                  color: Colors.white70,
                  active: _grade == ReviewGrade.keep,
                ),
                const SizedBox(width: 12),
                _GradeChip(label: '3 通过', color: kUnlocked, active: _grade == ReviewGrade.pass),
              ],
            ),
            const SizedBox(height: 12),
            const Center(
              child: Text(
                '空格翻面 · 1/2/3 自评 · Enter 下一个（预置阶段不落盘）',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _gradeColor(ReviewGrade grade) {
    switch (grade) {
      case ReviewGrade.retry:
        return kError;
      case ReviewGrade.keep:
        return Colors.white70;
      case ReviewGrade.pass:
        return kUnlocked;
    }
  }
}

class _GradeChip extends StatelessWidget {
  const _GradeChip({required this.label, required this.color, required this.active});

  final String label;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: active ? color : kLocked),
      ),
      child: Text(label, style: TextStyle(color: active ? color : Colors.white60, fontSize: 13)),
    );
  }
}

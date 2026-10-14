import 'package:flutter/material.dart';
import '../models/content_pack.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'build_step.dart';
import 'say_widget.dart';
import 'swap_step.dart';

/// 每个词块循环：BUILD → SAY(原始句) → SWAP(说替换变体)。
class PracticeLoop extends StatefulWidget {
  final Level level;
  final VoidCallback onDone;
  const PracticeLoop({required this.level, required this.onDone, super.key});

  @override
  State<PracticeLoop> createState() => _PracticeLoopState();
}

class _PracticeLoopState extends State<PracticeLoop> {
  int _ci = 0; // 当前词块索引
  int _phase = 0; // 0 build, 1 say, 2 swap

  Chunk get _chunk => widget.level.chunks[_ci];

  void _advance() {
    if (_ci < widget.level.chunks.length - 1) {
      setState(() {
        _ci++;
        _phase = 0;
      });
    } else {
      widget.onDone();
    }
  }

  String _phaseLabel() {
    switch (_phase) {
      case 0:
        return 'Build';
      case 1:
        return 'Say';
      default:
        return 'Swap';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_phaseLabel(),
                  style: const TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
              Text('chunk ${_ci + 1}/${widget.level.chunks.length}',
                  style: const TextStyle(color: Colors.white54)),
            ],
          ),
        ),
        Expanded(
          child: _phase == 0
              ? BuildStep(
                  level: widget.level,
                  chunk: _chunk,
                  onDone: () => setState(() => _phase = 1),
                )
              : _phase == 1
                  ? SayWidget(
                      sentence: _chunk.sentence.text,
                      levelId: widget.level.id,
                      onDone: () => setState(() => _phase = 2),
                    )
                  : SwapStep(chunk: _chunk, levelId: widget.level.id, onDone: _advance),
        ),
      ],
    );
  }
}

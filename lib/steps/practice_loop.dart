import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/state_machine.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'build_step.dart';
import 'say_widget.dart';
import 'swap_step.dart';
import 'l4_step.dart';

/// 每个词块循环：BUILD → SAY → SWAP → [L4 开口]。
/// 各阶段完成时用状态机事件驱动 chunk 推进（L1→L2→L3→L4→复习），
/// L4 阶段由 ChunkProgressStore 的当前 level 决定是否出现（M1/M3 状态机）。
class PracticeLoop extends StatefulWidget {
  final Level level;
  final VoidCallback onDone;
  const PracticeLoop({required this.level, required this.onDone, super.key});

  @override
  State<PracticeLoop> createState() => _PracticeLoopState();
}

class _PracticeLoopState extends State<PracticeLoop> {
  int _ci = 0; // 当前词块索引
  int _phase = 0; // 0 build, 1 say, 2 swap, 3 l4
  bool _isL4 = false;

  Chunk get _chunk => widget.level.chunks[_ci];

  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _refreshL4();
  }

  void _refreshL4() {
    _p.chunkStore.get(_chunk.id).then((row) {
      if (mounted) setState(() => _isL4 = row.level == ChunkLevel.l4);
    });
  }

  void _advance() {
    if (_ci < widget.level.chunks.length - 1) {
      setState(() {
        _ci++;
        _phase = 0;
      });
      _refreshL4();
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
      case 2:
        return 'Swap';
      default:
        return 'Open';
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
                  onDone: () async {
                    await _p.chunkStore.applyEvent(_chunk.id, ChunkEvent.assembleCorrect);
                    if (mounted) setState(() => _phase = 1);
                  },
                )
              : _phase == 1
                  ? SayWidget(
                      sentence: _chunk.sentence.text,
                      levelId: widget.level.id,
                      onDone: () async {
                        await _p.chunkStore.applyEvent(_chunk.id, ChunkEvent.dragCorrect);
                        if (mounted) setState(() => _phase = 2);
                      },
                    )
                  : _phase == 2
                      ? SwapStep(
                          chunk: _chunk,
                          levelId: widget.level.id,
                          onDone: _isL4
                              ? () => setState(() => _phase = 3)
                              : () async {
                                  await _p.chunkStore
                                      .applyEvent(_chunk.id, ChunkEvent.accuracyPass);
                                  _advance();
                                },
                        )
                      : L4Step(
                          chunk: _chunk,
                          levelId: widget.level.id,
                          onDone: _advance,
                        ),
        ),
      ],
    );
  }
}

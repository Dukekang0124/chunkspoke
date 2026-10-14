import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

class BuildStep extends StatefulWidget {
  final Level level;
  final Chunk chunk;
  final VoidCallback onDone;
  const BuildStep(
      {required this.level, required this.chunk, required this.onDone, super.key});

  @override
  State<BuildStep> createState() => _BuildStepState();
}

class _BuildStepState extends State<BuildStep> {
  late final List<String> _expected;
  late final List<String?> _filled;
  late final List<String> _tray;
  late final Map<String, String> _typeOf;
  bool _built = false;

  @override
  void initState() {
    super.initState();
    _expected = widget.chunk.sentence.slots.map((s) => s.text).toList();
    _filled = List<String?>.filled(_expected.length, null);
    _typeOf = {};
    for (final s in widget.chunk.sentence.slots) _typeOf[s.text] = s.type;
    for (final c in widget.level.chunks) _typeOf[c.text] = c.type;

    final distractors = widget.level.chunks
        .where((c) => !_expected.contains(c.text))
        .toList()
      ..shuffle();
    _tray = [..._expected];
    for (final d in distractors.take(2)) _tray.add(d.text);
    _tray.shuffle();
  }

  String _typeFor(String t) => _typeOf[t] ?? 'content';

  void _place(int i, String tile) {
    if (tile != _expected[i] || _filled[i] != null) return; // 顺序错误 → 回弹（DragTarget 自动处理）
    setState(() {
      _filled[i] = tile;
      _tray.remove(tile);
    });
    if (_filled.every((e) => e != null)) {
      setState(() => _built = true);
      Provider.of<TtsService>(context, listen: false).speak(widget.chunk.sentence.text);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) widget.onDone();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          SceneCard(widget.level.theme),
          const SizedBox(height: 16),
          const Text('中文题干 · 拼出这句英文',
              style: TextStyle(color: kPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: kBg.withOpacity(0.5),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(widget.chunk.meaningCN,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          if (widget.chunk.sentence.coreWords.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: widget.chunk.sentence.coreWords
                  .map((w) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: kPrimary.withOpacity(0.16),
                          border: Border.all(color: kPrimary.withOpacity(0.5)),
                        ),
                        child: Text(w, style: const TextStyle(color: kPrimary, fontSize: 13)),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _built ? kUnlocked : Colors.white24, width: _built ? 2 : 1),
              color: _built ? kUnlocked.withOpacity(0.08) : Colors.transparent,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: List.generate(_expected.length, (i) {
                return DragTarget<String>(
                  builder: (ctx, cand, rej) => _filled[i] != null
                      ? ChunkTile(_filled[i]!, _typeFor(_filled[i]!))
                      : Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text('—',
                              style: TextStyle(color: Colors.white24, fontSize: 16)),
                        ),
                  onWillAccept: (data) => data == _expected[i] && _filled[i] == null,
                  onAccept: (data) => _place(i, data!),
                );
              }),
            ),
          ),
          if (_built)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('Sentence built! Now say it.',
                  style: TextStyle(color: kUnlocked, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          const Spacer(),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: _tray
                .map((t) => Draggable<String>(
                      data: t,
                      feedback: ChunkTile(t, _typeFor(t)),
                      childWhenDragging: Opacity(
                        opacity: 0.3,
                        child: ChunkTile(t, _typeFor(t)),
                      ),
                      child: ChunkTile(t, _typeFor(t)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

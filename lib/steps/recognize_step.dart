import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// RECOGNIZE 步骤：听音选词，每词块连续 3 次选对即过；答错仅重置计数 + 轻微抖动，无红叉、无报错文案。
class RecognizeStep extends StatefulWidget {
  final Level level;
  final VoidCallback onDone;
  const RecognizeStep({required this.level, required this.onDone, super.key});

  @override
  State<RecognizeStep> createState() => _RecognizeStepState();
}

class _RecognizeStepState extends State<RecognizeStep> {
  late List<Chunk> _pending;
  final Map<String, int> _streak = {};
  late Chunk _current;
  late List<String> _options;
  double _shake = 0;

  @override
  void initState() {
    super.initState();
    _pending = List.from(widget.level.chunks);
    _nextQuestion();
  }

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);

  void _nextQuestion() {
    _current = _pending.first;
    _streak.putIfAbsent(_current.id, () => 0);
    final distractors = widget.level.chunks
        .where((c) => c.id != _current.id)
        .toList()
      ..shuffle();
    _options = [_current.text];
    for (final d in distractors.take(3)) _options.add(d.text);
    _options.shuffle();
    _tts.speak(_current.text);
  }

  void _answer(String picked) {
    if (picked == _current.text) {
      _streak[_current.id] = _streak[_current.id]! + 1;
      if (_streak[_current.id]! >= 3) {
        _pending.removeWhere((c) => c.id == _current.id);
        if (_pending.isEmpty) {
          widget.onDone();
          return;
        }
      }
      _nextQuestion();
      setState(() {});
    } else {
      _streak[_current.id] = 0;
      setState(() => _shake = 12);
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) setState(() => _shake = 0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final typeMap = {for (final c in widget.level.chunks) c.text: c.type};
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Text('点你听到的词块', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          IconButton(
            icon: const Icon(Icons.volume_up, color: kPrimary, size: 40),
            onPressed: () => _tts.speak(_current.text),
          ),
          const SizedBox(height: 20),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            transform: Matrix4.translationValues(_shake, 0, 0),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: _options
                  .map((t) => GestureDetector(
                        onTap: () => _answer(t),
                        child: ChunkTile(t, typeMap[t] ?? 'content'),
                      ))
                  .toList(),
            ),
          ),
          const Spacer(),
          Text('需要提示？稍后长按词块',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}

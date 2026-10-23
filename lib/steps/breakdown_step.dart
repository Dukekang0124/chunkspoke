import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/feedback.dart';

/// ① 拆解：把词块拆成词卡，逐个听发音、看清构成，再拼回整块。
class BreakdownStep extends StatefulWidget {
  final Chunk chunk;
  final Level level;
  final VoidCallback onDone;

  const BreakdownStep({
    required this.chunk,
    required this.level,
    required this.onDone,
    super.key,
  });

  @override
  State<BreakdownStep> createState() => _BreakdownStepState();
}

class _BreakdownStepState extends State<BreakdownStep> {
  late final List<String> _words;
  late final Set<int> _heard;

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _words = widget.chunk.text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    _heard = <int>{};
  }

  Future<void> _hear(int i) async {
    setState(() => _heard.add(i));
    final ok = await _tts.speak(_words[i]);
    if (!ok && mounted) speakOrHint(context, _tts, _words[i]);
  }

  Future<void> _hearAll() async {
    final ok = await _tts.speak(widget.chunk.text);
    if (!ok && mounted) speakOrHint(context, _tts, widget.chunk.text);
  }

  bool get _allHeard => _words.isEmpty || _heard.length >= _words.length;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('第 2/6 步 · 拆解',
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 10),
          const Text('把词块拆开看：点每张卡片听发音',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kBg.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: List.generate(_words.length, (i) {
                    final heard = _heard.contains(i);
                    return GestureDetector(
                      onTap: () => _hear(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: heard
                              ? kUnlocked.withValues(alpha: 0.14)
                              : kPrimary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: heard ? kUnlocked : kPrimary,
                              width: heard ? 2 : 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (heard) ...[
                              const Icon(Icons.check,
                                  color: kUnlocked, size: 16),
                              const SizedBox(width: 4),
                            ],
                            Text(_words[i],
                                style: TextStyle(
                                    color: heard ? kUnlocked : kPrimary,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 14),
                TextButton.icon(
                  onPressed: _hearAll,
                  icon: const Icon(Icons.volume_up, color: kPrimary, size: 18),
                  label: const Text('整块再听一遍',
                      style: TextStyle(color: kPrimary)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(widget.chunk.meaningCN,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 14)),
          const Spacer(),
          Text(
            _allHeard ? '拆完了，拼回去它就长在你嘴里' : '还剩 ${_words.length - _heard.length} 张卡片没听',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary,
                disabledBackgroundColor: Colors.white12,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _allHeard ? widget.onDone : null,
              child: Text('拼回去 · 去听辨',
                  style: TextStyle(
                      color: _allHeard ? Colors.black87 : Colors.white38,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

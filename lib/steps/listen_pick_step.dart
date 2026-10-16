import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/feedback.dart';

/// ① 听辨块：播放「词块」音频，从 3 个词块选项中选出听到的那一块（选项是块，不是整句）。
/// 点对即过关；点错揭示正确答案并可点正确项继续。
class ListenPickStep extends StatefulWidget {
  final Chunk chunk;
  final Level level;
  final VoidCallback onDone;
  const ListenPickStep(
      {required this.chunk, required this.level, required this.onDone, super.key});

  @override
  State<ListenPickStep> createState() => _ListenPickStepState();
}

class _ListenPickStepState extends State<ListenPickStep> {
  late final List<String> _options;
  bool _correct = false;
  double _shake = 0;
  bool _revealed = false;
  String? _wrongText;

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    final target = widget.chunk.text;
    final others = widget.level.chunks
        .where((c) => c.text != target)
        .map((c) => c.text)
        .toList()
      ..shuffle();
    // 3 个选项（1 正确 + 2 干扰），均为「词块」。
    _options = [target, ...others.take(2)]..shuffle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tts.speak(target);
    });
  }

  void _pick(String s) {
    if (s == widget.chunk.text) {
      chimeCorrect();
      setState(() => _correct = true);
      return;
    }
    if (_revealed) return;
    buzzWrong();
    setState(() {
      _wrongText = s;
      _revealed = true;
      _shake = 10;
    });
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _shake = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_correct) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 8),
            const Icon(Icons.check_circle, color: kUnlocked, size: 44),
            const SizedBox(height: 8),
            Text(widget.chunk.text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 20),
            const Text('听辨正确！这块就是它',
                style: TextStyle(color: kUnlocked, fontSize: 16)),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: widget.onDone,
                child: const Text('下一步',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Text('听音频，选出你听到的「词块」',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          IconButton(
            icon: const Icon(Icons.volume_up, color: kPrimary, size: 40),
            onPressed: () => _tts.speak(widget.chunk.text),
          ),
          const SizedBox(height: 16),
          if (_revealed)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('✅ 正确答案是上面标出的那块，点它继续',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kUnlocked, fontSize: 14)),
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            transform: Matrix4.translationValues(_shake, 0, 0),
            child: Column(
              children: _options
                  .map((s) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: GestureDetector(
                          onTap: () => _pick(s),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _revealed
                                    ? (s == widget.chunk.text
                                        ? kUnlocked
                                        : (s == _wrongText
                                            ? Colors.redAccent
                                            : Colors.white24))
                                    : Colors.white24,
                                width: _revealed && s == widget.chunk.text ? 2 : 1,
                              ),
                              color: _revealed && s == widget.chunk.text
                                  ? kUnlocked.withOpacity(0.12)
                                  : kBg.withOpacity(0.5),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_revealed && s == widget.chunk.text)
                                  const Icon(Icons.check_circle,
                                      color: kUnlocked, size: 18),
                                if (_revealed && s == _wrongText)
                                  const Icon(Icons.close,
                                      color: Colors.redAccent, size: 18),
                                Text(s,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 17)),
                              ],
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

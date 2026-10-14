import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// LEARN 步骤：逐张展示词块卡，自动播放发音，长按英文弹中文。无测试。
class LearnStep extends StatefulWidget {
  final Level level;
  final VoidCallback onDone;
  const LearnStep({required this.level, required this.onDone, super.key});

  @override
  State<LearnStep> createState() => _LearnStepState();
}

class _LearnStepState extends State<LearnStep> {
  int _i = 0;

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _play();
  }

  void _play() => _tts.speak(widget.level.chunks[_i].text);

  void _next() {
    if (_i < widget.level.chunks.length - 1) {
      setState(() => _i++);
      _play();
    } else {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.level.chunks[_i];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          SceneCard(widget.level.theme),
          const SizedBox(height: 28),
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CnText(c.text, c.meaningCN,
                      style: TextStyle(
                          color: chunkColor(c.type),
                          fontSize: 30,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 18),
                  CnText(c.sentence.text, c.meaningCN,
                      style: const TextStyle(color: Colors.white, fontSize: 18)),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _play,
                    child: const Text('Replay', style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          ),
          Text('${_i + 1} / ${widget.level.chunks.length}',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _next,
              child: Text(_i < widget.level.chunks.length - 1 ? 'Next' : 'Start practice',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

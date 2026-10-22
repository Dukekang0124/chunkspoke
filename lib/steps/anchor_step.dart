import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';

/// ⓪ 锚定：先看场景、听懂这一块的意思，再开始拆。
class AnchorStep extends StatefulWidget {
  final Chunk chunk;
  final Level level;
  final int chunkIndex;
  final int chunkTotal;
  final VoidCallback onDone;

  const AnchorStep({
    required this.chunk,
    required this.level,
    required this.onDone,
    this.chunkIndex = 0,
    this.chunkTotal = 1,
    super.key,
  });

  @override
  State<AnchorStep> createState() => _AnchorStepState();
}

class _AnchorStepState extends State<AnchorStep> {
  TtsService get _tts => Provider.of<TtsService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play();
    });
  }

  Future<void> _play() async {
    final ok = await _tts.speak(widget.chunk.text);
    if (!ok && mounted) speakOrHint(context, _tts, widget.chunk.text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          SceneCard(widget.level.theme),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('第 1/6 步 · 锚定',
                  style: TextStyle(
                      color: kPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('第 ${widget.chunkIndex + 1}/${widget.chunkTotal} 块',
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          const Spacer(),
          const Text('先认识这一块',
              style: TextStyle(color: Colors.white70, fontSize: 15)),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
            decoration: BoxDecoration(
              color: kBg.withOpacity(0.6),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kPrimary.withOpacity(0.45)),
            ),
            child: Column(
              children: [
                Text(widget.chunk.text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(widget.chunk.meaningCN,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: kPrimary, fontSize: 16)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          IconButton(
            icon: const Icon(Icons.volume_up, color: kPrimary, size: 34),
            onPressed: _play,
          ),
          const Text('听一遍，记住它在这个场景里的意思',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: widget.onDone,
              child: const Text('开始拆解',
                  style: TextStyle(
                      color: Colors.black87,
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

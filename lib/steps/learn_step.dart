import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/motion.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';

/// LEARN 步骤：展示英文词块 + 中文卡；中文卡长按 3.5 秒溶解（隐藏）用于自测回忆。
class LearnStep extends StatefulWidget {
  final Level level;
  final VoidCallback onDone;
  const LearnStep({required this.level, required this.onDone, super.key});

  @override
  State<LearnStep> createState() => _LearnStepState();
}

class _LearnStepState extends State<LearnStep> {
  int _i = 0;
  bool _cnDissolved = false;
  Timer? _dissolveTimer;

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _play();
  }

  @override
  void dispose() {
    _dissolveTimer?.cancel();
    super.dispose();
  }

  void _play() => _tts.speak(widget.level.chunks[_i].text);

  void _beginDissolve() {
    _dissolveTimer?.cancel();
    _dissolveTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted) setState(() => _cnDissolved = true);
    });
  }

  void _cancelDissolve() => _dissolveTimer?.cancel();

  void _next() {
    _dissolveTimer?.cancel();
    if (_i < widget.level.chunks.length - 1) {
      setState(() {
        _i++;
        _cnDissolved = false;
      });
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
                  Text(c.text,
                      style: TextStyle(
                          color: chunkColor(c.type),
                          fontSize: 30,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 18),
                  GestureDetector(
                    onTap: () => setState(() => _cnDissolved = false),
                    onLongPressStart: (_) => _beginDissolve(),
                    onLongPressEnd: (_) => _cancelDissolve(),
                    child: AnimatedOpacity(
                      opacity: _cnDissolved ? 0.0 : 1.0,
                      duration: Motion.of(context).dur(400),
                      curve: Curves.easeOut,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: kBg.withValues(alpha: 0.5),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(c.meaningCN,
                            style: const TextStyle(color: Colors.white, fontSize: 18)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(_cnDissolved ? '已隐藏 · 点按恢复' : '长按中文卡 3.5 秒溶解（自测）',
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => speakOrHint(
                        context, _tts, widget.level.chunks[_i].text),
                    child: const Text('重听', style: TextStyle(color: Colors.white70)),
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
              child: Text(_i < widget.level.chunks.length - 1 ? '继续' : '开始练习',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

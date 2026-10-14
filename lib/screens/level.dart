import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../steps/learn_step.dart';
import '../steps/recognize_step.dart';
import '../steps/practice_loop.dart';

class LevelScreen extends StatefulWidget {
  final Level level;
  const LevelScreen({required this.level, super.key});

  @override
  State<LevelScreen> createState() => _LevelScreenState();
}

class _LevelScreenState extends State<LevelScreen> {
  int _phase = 0; // 0 learn, 1 recognize, 2 practice
  bool _done = false;

  void _finish() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    await progress.markCompleted(widget.level.id);
    for (final d in const ['recognize', 'build', 'say', 'swap']) {
      await progress.recordDim(widget.level.id, d);
    }
    await progress.bumpStreak();
    await progress.scheduleReview(
        widget.level.chunks.map((c) => '${widget.level.id}:${c.id}').toList());
    if (mounted) setState(() => _done = true);
  }

  Widget _body() {
    switch (_phase) {
      case 0:
        return LearnStep(level: widget.level, onDone: () => setState(() => _phase = 1));
      case 1:
        return RecognizeStep(level: widget.level, onDone: () => setState(() => _phase = 2));
      case 2:
        return PracticeLoop(level: widget.level, onDone: _finish);
      default:
        return Container();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('${widget.level.id} · ${widget.level.theme}'),
      ),
      body: _done ? _Completion(level: widget.level) : _body(),
    );
  }
}

class _Completion extends StatelessWidget {
  final Level level;
  const _Completion({required this.level});

  @override
  Widget build(BuildContext context) {
    const dims = ['识别', '组装', '开口', '重组'];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: kUnlocked, size: 64),
            const SizedBox(height: 16),
            const Text('Level complete!',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: dims
                  .map((d) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          children: [
                            const Icon(Icons.star, color: kUnlocked, size: 28),
                            const SizedBox(height: 4),
                            Text(d, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to map', style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

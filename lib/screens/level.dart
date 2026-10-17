import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/chunk_progress.dart';
import '../services/state_machine.dart';
import '../services/crash_log.dart';
import '../ui/theme.dart';
import '../ui/labels.dart';
import '../steps/practice_loop.dart';

/// 场景会话页：直接进入「逐块闭环」练习（听辨→造句→照读→开口）。
/// 进入时由 PracticeLoop 读取断点，给出「继续 / 从头开始」；✕ 干净返回场景列表。
class LevelScreen extends StatefulWidget {
  final Level level;
  const LevelScreen({required this.level, super.key});

  @override
  State<LevelScreen> createState() => _LevelScreenState();
}

class _LevelScreenState extends State<LevelScreen> {
  bool _done = false;

  Future<void> _finish() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    await progress.markCompleted(widget.level.id);
    for (final d in const ['recognize', 'build', 'say', 'swap']) {
      await progress.recordDim(widget.level.id, d);
    }
    // 将本关仍未掌握的块放入到期复习队列：写 chunks 表 due_date（与首页到期读取同源），
    // 修正旧 kv 'review' 键格式错配导致「完成关卡→排复习」失效的问题（S5）。
    final store = progress.chunkStore;
    for (final c in widget.level.chunks) {
      try {
        final row = await store.get(c.id);
        if (!ChunkProgressStore.isMastered(row)) {
          await store.applyEvent(c.id, ChunkEvent.scheduleReview);
        }
      } catch (e, st) {
        CrashLog.write('Level.finish review(${c.id}): $e', st);
      }
    }
    if (mounted) setState(() => _done = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          // P0 修复：用 maybePop（栈底已保证是场景列表），退出后绝不空栈黑屏。
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(sceneCn(widget.level.theme),
                style: const TextStyle(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            Text(widget.level.theme,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
      body: _done
          ? _Completion(level: widget.level)
          : PracticeLoop(level: widget.level, onDone: _finish),
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
            const Text('关卡完成！',
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
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
                            Text(d,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
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
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('返回地图',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

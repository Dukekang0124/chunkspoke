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
  List<bool> _dims = const [true, true, true, true];

  Future<void> _finish() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    await progress.markCompleted(widget.level.id);
    // 将本关仍未掌握的块放入到期复习队列：写 chunks 表 due_date（与首页到期读取同源）。
    // 去双写：跳过路径已经在练习中落过 scheduleReview，这里只对「仍未掌握且尚未进复习」的块兜底，
    // 避免 sessions 表 scheduleReview 事件翻倍（实测 12 块 → 24 条）。
    final store = progress.chunkStore;
    for (final c in widget.level.chunks) {
      try {
        final row = await store.get(c.id);
        if (!ChunkProgressStore.isMastered(row) &&
            row.level != ChunkLevel.review) {
          await store.applyEvent(c.id, ChunkEvent.scheduleReview);
        }
      } catch (e, st) {
        CrashLog.write('Level.finish review(${c.id}): $e', st);
      }
    }
    // 诚实统计四步达成：用本关各块的最新进度行判读，未达标的星置灰。
    List<bool> dims = const [true, true, true, true];
    try {
      final rows = await Future.wait(
          widget.level.chunks.map((c) => store.get(c.id)));
      dims = [
        rows.every((r) => r.level.index >= ChunkLevel.l2.index), // 听辨：都已过听音识块
        rows.every((r) => r.l2OneTry == 1), // 说块：一次过（拖对首试）
        rows.every((r) => r.level.index >= ChunkLevel.l3.index), // 拼句：都已块拼句
        rows.every((r) => r.lastScore >= 80 || r.l4SelfEval), // 开口：命中≥80 或自评
      ];
    } catch (e, st) {
      CrashLog.write('Level.finish dims: $e', st);
    }
    if (mounted) setState(() => _done = true);
    if (mounted) _dims = dims;
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
          ? _Completion(level: widget.level, dims: _dims)
          : PracticeLoop(level: widget.level, onDone: _finish),
    );
  }
}

class _Completion extends StatelessWidget {
  final Level level;
  final List<bool> dims; // 顺序：听辨 / 说块 / 拼句 / 开口（按真实达成置灰/点亮）
  const _Completion({required this.level, required this.dims});

  @override
  Widget build(BuildContext context) {
    const labels = ['听辨', '说块', '拼句', '开口'];
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
            const SizedBox(height: 8),
            const Text('星 = 本次真实达成，未达标的留给你补练',
                style: TextStyle(fontSize: 13, color: Colors.white54)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(labels.length, (i) {
                final ok = i < dims.length && dims[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      Icon(ok ? Icons.star : Icons.star_border,
                          color: ok ? kUnlocked : Colors.white24, size: 28),
                      const SizedBox(height: 4),
                      Text(labels[i],
                          style: TextStyle(
                              color: ok ? Colors.white70 : Colors.white38,
                              fontSize: 12)),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 28),
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
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('补练没拿到的星（回场景再练一遍）',
                  style: TextStyle(color: Colors.white38, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

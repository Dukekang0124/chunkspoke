import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;

import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/chunk_progress.dart';
import '../services/state_machine.dart';
import '../services/crash_log.dart';
import '../services/review_notify.dart';
import '../services/scene_progression.dart';
import '../services/session_report.dart';
import '../ui/theme.dart';
import '../ui/labels.dart';
import '../ui/feedback.dart';
import '../ui/motion.dart';
import '../steps/practice_loop.dart';

/// 场景会话页：直接进入「逐块闭环」练习（锚定→拆解→听辨→跟读→替换→造句）。
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
  SessionReport? _report;
  String _nextReview = '暂无待复习';
  Level? _nextScene;
  bool _nextUnlocked = false;
  int _nextMissing = 0;

  Future<void> _finish(SessionReport report) async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
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
    NextSceneState? next;
    try {
      final rows =
          await Future.wait(widget.level.chunks.map((c) => store.get(c.id)));
      dims = [
        rows.every((r) => r.level.index >= ChunkLevel.l2.index), // 听辨：都已过听音识块
        rows.every((r) => r.l2OneTry == 1), // 跟读：一次过（拖对首试）
        rows.every((r) => r.level.index >= ChunkLevel.l3.index), // 替换：都已通过定替
        rows.every((r) => r.lastScore >= 80 || r.l4SelfEval), // 开口：命中≥80 或自评
      ];
      final masteredKeys = <String>{
        for (final r in rows)
          if (ChunkProgressStore.isMastered(r)) r.chunkKey
      };
      next = nextSceneState(content.levels, widget.level.id, masteredKeys);
    } catch (e, st) {
      CrashLog.write('Level.finish dims: $e', st);
    }
    // B6：下次复习时间（最近一次未来到期）。
    String nextReview = '暂无待复习';
    try {
      final ts =
          await store.nextDueTimestamp(progress.now.millisecondsSinceEpoch);
      if (ts != null) {
        final d = DateTime.fromMillisecondsSinceEpoch(ts);
        nextReview = '${d.month}月${d.day}日';
      }
    } catch (e, st) {
      CrashLog.write('Level.nextDue: $e', st);
    }
    // 到期复习提醒按最新资产排期重排（失败静默，不影响结算展示）。
    await syncReviewReminder(progress);
    if (mounted) {
      _report = report;
      _nextReview = nextReview;
      _nextScene = next?.level;
      _nextUnlocked = next?.unlocked ?? false;
      _nextMissing = next?.missing ?? 0;
      setState(() => _done = true);
      _dims = dims;
    }
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
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            Text(widget.level.theme,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
      body: _done
          ? CompletionView(
              level: widget.level,
              dims: _dims,
              report: _report,
              nextReview: _nextReview,
              nextScene: _nextScene,
              nextUnlocked: _nextUnlocked,
              nextMissing: _nextMissing)
          : PracticeLoop(level: widget.level, onDone: _finish),
    );
  }
}

class CompletionView extends StatefulWidget {
  final Level level;
  final List<bool> dims; // 顺序：听辨 / 跟读 / 替换 / 开口（按真实达成置灰/点亮）
  final SessionReport? report;
  final String nextReview;
  final Level? nextScene;
  final bool nextUnlocked;
  final int nextMissing;
  const CompletionView(
      {required this.level,
      required this.dims,
      this.report,
      this.nextReview = '暂无待复习',
      this.nextScene,
      this.nextUnlocked = false,
      this.nextMissing = 0,
      super.key});

  @override
  State<CompletionView> createState() => _CompletionViewState();
}

class _CompletionViewState extends State<CompletionView>
    with TickerProviderStateMixin {
  // 两个独立动画（彩带 + 徽章）必须各占一个 ticker，SingleTicker 会在建第二个时抛错。
  late final AnimationController _confetti;
  late final AnimationController _badge;
  bool _lowPower = false;

  @override
  void initState() {
    super.initState();
    _confetti = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..forward();
    _badge = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500))
      ..forward();
    // B7 省电模式探测：省电时粒子减半。
    PowerService.isPowerSaveMode().then((v) {
      if (mounted) setState(() => _lowPower = v);
    });
  }

  @override
  void dispose() {
    _confetti.dispose();
    _badge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = ['听辨', '跟读', '替换', '开口'];
    final reduce = MediaQuery.of(context).disableAnimations; // B7 尊重系统减弱动画
    final policy = MotionPolicy(reduceMotion: reduce, lowPower: _lowPower);
    final canContinue = widget.nextUnlocked && widget.nextScene != null;
    final hasMissingStars = widget.dims.any((ok) => !ok);
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // B5 徽章（scale-in 弹入）
                ScaleTransition(
                  scale: CurvedAnimation(
                      parent: _badge, curve: Curves.easeOutBack),
                  child:
                      const Icon(Icons.emoji_events, color: kPrimary, size: 72),
                ),
                const SizedBox(height: 14),
                const Text('关卡完成！',
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 8),
                const Text('星 = 本次真实达成，未达标的留给你补练',
                    style: TextStyle(fontSize: 13, color: Colors.white54)),
                if (widget.nextScene != null) ...[
                  const SizedBox(height: 12),
                  if (canContinue)
                    _unlockBanner(sceneCn(widget.nextScene!.theme))
                  else
                    _lockedHint(widget.nextScene!, widget.nextMissing),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(labels.length, (i) {
                    final ok = i < widget.dims.length && widget.dims[i];
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
                const SizedBox(height: 20),
                _reportCard(),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: canContinue
                        ? _openNext
                        : () => Navigator.of(context).maybePop(),
                    child: Text(
                        canContinue
                            ? '继续学习：${sceneCn(widget.nextScene!.theme)}'
                            : '返回地图',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 16)),
                  ),
                ),
                const SizedBox(height: 10),
                if (canContinue)
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('返回地图',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  )
                else if (hasMissingStars || widget.nextScene != null)
                  TextButton(
                    onPressed: _replay,
                    child: const Text('再练一遍本场景',
                        style: TextStyle(color: Colors.white38, fontSize: 13)),
                  ),
                TextButton(
                  onPressed: () => showFeedbackSheet(context),
                  child: const Text('反馈',
                      style: TextStyle(color: Colors.white54, fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
        // B5 彩带（尊重系统减弱动画 / 省电降级时跳过或减半）
        if (policy.confettiOn)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _confetti,
              builder: (_, __) => CustomPaint(
                size: Size.infinite,
                painter:
                    _ConfettiPainter(_confetti.value, policy.particles(60)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _unlockBanner(String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: kPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kPrimary.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_open, color: kPrimary, size: 16),
          const SizedBox(width: 6),
          Text('下一场景已解锁：$name',
              style: const TextStyle(color: kPrimary, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _lockedHint(Level next, int missing) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock, color: Colors.white54, size: 16),
          const SizedBox(width: 6),
          Text(
              '再达标 $missing 块解锁「${sceneCn(next.theme)}」'
              '（上一场景需达 80%）',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }

  void _openNext() {
    final next = widget.nextScene;
    if (next == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LevelScreen(level: next)),
    );
  }

  void _replay() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LevelScreen(level: widget.level)),
    );
  }

  Widget _reportCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('本次战报',
              style: TextStyle(
                  color: kPrimary, fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 8),
          _reportRow('本次完成', '${widget.report?.completed ?? 0} 块'),
          _reportRow('四星全绿', '${widget.report?.starChunks ?? 0} 块'),
          _reportRow('开口句数', '${widget.report?.spoken ?? 0} 句'),
          _reportRow('下次复习', widget.nextReview),
        ],
      ),
    );
  }

  Widget _reportRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          const Spacer(),
          Text(v,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// B5 彩带粒子绘制。
class _ConfettiPainter extends CustomPainter {
  final double t;
  final int count;
  _ConfettiPainter(this.t, this.count);
  final math.Random _rng = math.Random(7);
  static const _colors = [
    Color(0xFFFFB84D),
    Color(0xFF34D399),
    Colors.white,
    Color(0xFFF59E0B),
    Color(0xFF60A5FA),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < count; i++) {
      final x = _rng.nextDouble() * size.width;
      final y =
          (_rng.nextDouble() * size.height + t * size.height) % size.height;
      final c = _colors[i % _colors.length];
      final w = 6.0 + _rng.nextDouble() * 5;
      final h = 10.0 + _rng.nextDouble() * 6;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(_rng.nextDouble() * math.pi + t * 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset.zero, width: w, height: h),
            const Radius.circular(2)),
        Paint()..color = c.withValues(alpha: 1.0 - t * 0.25),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => old.t != t;
}

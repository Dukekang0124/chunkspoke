import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/chunk_progress.dart';
import '../services/state_machine.dart';
import '../services/crash_log.dart';
import '../services/review_notify.dart';
import '../services/scene_progression.dart';
import '../services/license_code.dart' show kFreeLevelCount;
import '../services/license_state.dart';
import '../services/session_report.dart';
import '../screens/license_activate.dart' show showWechatPurchaseSheet, kEarlyBirdPrice;
import '../ui/theme.dart';
import '../ui/labels.dart';
import '../ui/feedback.dart';
import '../ui/confetti.dart';
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
  // 1.8.1（任务书 §五）：免费区最后一关学完 + 未激活 → 结算页出转化横幅。
  bool _freeTierDone = false;
  bool _hasFullAccess = false;
  int _freeChunks = 0;
  int _totalChunks = 0;

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
      // 1.6.0（LIC-1）：下一场景是否「可进入」也要过 license 门；锁住的场景
      // 只提示、不给 CTA。null = 与 1.5.x 完全一致。
      final lic = mounted
          ? Provider.of<LicenseState?>(context, listen: false)
          : null;
      next = nextSceneState(content.levels, widget.level.id, masteredKeys,
          allowed: lic?.allowsLevel);
      // 1.8.1：本关是不是「免费区最后一关」（现网 = F），且这一关确实达标（≥80% 掌握）。
      // 数字按内容包实时算，不写死 137/487 —— 1.8.0 起免费区是 生存 S0 + A–F = 167/517。
      const freeIdx = kFreeLevelCount - 1;
      final freeLast = (freeIdx >= 0 && freeIdx < content.levels.length)
          ? content.levels[freeIdx]
          : null;
      final masteredHere = widget.level.chunks
          .where((c) => masteredKeys.contains(c.id))
          .length;
      _freeTierDone = freeLast != null &&
          widget.level.id == freeLast.id &&
          masteredHere >= sceneUnlockTarget(widget.level);
      _freeChunks = content.levels
          .take(kFreeLevelCount)
          .fold(0, (s, l) => s + l.chunks.length);
      _totalChunks =
          content.levels.fold(0, (s, l) => s + l.chunks.length);
      _hasFullAccess = lic?.hasFullAccess ?? false;
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
      // 墙外场景：即便进度达标也按「未解锁」呈现（CTA 会引导回 A–F），
      // 避免结算页给一个点了就弹墙的按钮。
      final licNow = Provider.of<LicenseState?>(context, listen: false);
      final nextLevel = next?.level;
      final nextIdx = nextLevel == null
          ? -1
          : content.levels.indexWhere((l) => l.id == nextLevel.id);
      final nextAllowed =
          nextIdx < 0 || licNow == null || licNow.allowsLevel(nextIdx);
      _nextUnlocked = (next?.unlocked ?? false) && nextAllowed;
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
          icon: Icon(Icons.close, color: kTextSecondary),
          // P0 修复：用 maybePop（栈底已保证是场景列表），退出后绝不空栈黑屏。
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(sceneCn(widget.level.theme),
                style: TextStyle(
                    color: kText,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            Text(widget.level.theme,
                style: TextStyle(color: kTextMuted, fontSize: 12)),
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
              nextMissing: _nextMissing,
              freeTierDone: _freeTierDone,
              hasFullAccess: _hasFullAccess,
              freeChunks: _freeChunks,
              totalChunks: _totalChunks)
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

  /// 1.8.1（任务书 §五）：免费区最后一关已达标 + 未激活 → 结算页底部出转化横幅。
  /// 默认 false：老调用与既有测试行为不变，PRO/老用户也永远看不到横幅。
  final bool freeTierDone;
  final bool hasFullAccess;
  final int freeChunks;
  final int totalChunks;
  const CompletionView(
      {required this.level,
      required this.dims,
      this.report,
      this.nextReview = '暂无待复习',
      this.nextScene,
      this.nextUnlocked = false,
      this.nextMissing = 0,
      this.freeTierDone = false,
      this.hasFullAccess = false,
      this.freeChunks = 0,
      this.totalChunks = 0,
      super.key});

  @override
  State<CompletionView> createState() => _CompletionViewState();
}

class _CompletionViewState extends State<CompletionView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _badge;
  bool _badgeStarted = false;

  @override
  void initState() {
    super.initState();
    _badge = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_badgeStarted) return;
    _badgeStarted = true;
    // G-03 / DDS §24：奖杯接入中心动效闸，reduced-motion 直切静态图标。
    if (Motion.of(context).animates) _badge.forward();
  }

  @override
  void dispose() {
    _badge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = ['听辨', '跟读', '替换', '开口'];
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
                // B5 徽章（scale-in 弹入；减弱动画时直出静态图标）
                if (Motion.of(context).animates)
                  ScaleTransition(
                    scale: CurvedAnimation(
                        parent: _badge, curve: Curves.easeOutBack),
                    child: Icon(Icons.emoji_events,
                        color: kPrimary, size: 72),
                  )
                else
                  Icon(Icons.emoji_events, color: kPrimary, size: 72),
                const SizedBox(height: 14),
                Text('关卡完成！',
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: kText)),
                const SizedBox(height: 8),
                Text('星 = 本次真实达成，未达标的留给你补练',
                    style: TextStyle(fontSize: 13, color: kTextMuted)),
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
                              color: ok ? kUnlocked : kBorderStrong, size: 28),
                          const SizedBox(height: 4),
                          Text(labels[i],
                              style: TextStyle(
                                  color: ok ? kTextSecondary : kTextFaint,
                                  fontSize: 12)),
                        ],
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 20),
                _reportCard(),
                // 1.8.1（任务书 §五）：免费区最后一关学完 + 未激活 → 转化横幅。
                // PRO / 老用户（hasFullAccess）永远不出现；没学完 F 也不出现。
                if (widget.freeTierDone && !widget.hasFullAccess) ...[
                  const SizedBox(height: 12),
                  _freeContentCompleteBanner(),
                ],
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
                            TextStyle(color: kOnPrimary, fontSize: 16)),
                  ),
                ),
                const SizedBox(height: 10),
                if (canContinue)
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text('返回地图',
                        style: TextStyle(color: kTextMuted, fontSize: 13)),
                  )
                else if (hasMissingStars || widget.nextScene != null)
                  TextButton(
                    onPressed: _replay,
                    child: Text('再练一遍本场景',
                        style: TextStyle(color: kTextFaint, fontSize: 13)),
                  ),
                TextButton(
                  onPressed: () => showFeedbackSheet(context),
                  child: Text('反馈',
                      style: TextStyle(color: kTextMuted, fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
        // B5 彩带（M1 起走共享组件，内部统一过减弱动画/省电闸）
        const ConfettiBurst(),
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
          Icon(Icons.lock_open, color: kPrimary, size: 16),
          const SizedBox(width: 6),
          Text('下一场景已解锁：$name',
              style: TextStyle(color: kPrimary, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _lockedHint(Level next, int missing) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: kBorderSoft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kBorderStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock, color: kTextMuted, size: 16),
          const SizedBox(width: 6),
          Text(
              '再达标 $missing 块解锁「${sceneCn(next.theme)}」'
              '（上一场景需达 80%）',
              style: TextStyle(color: kTextSecondary, fontSize: 13)),
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

  /// 免费内容走完横幅（任务书 §五）：数字按内容包实时算，不写死 137/487。
  Widget _freeContentCompleteBanner() {
    final remaining =
        widget.totalChunks > widget.freeChunks ? widget.totalChunks - widget.freeChunks : 0;
    final counts = widget.totalChunks > 0
        ? '${widget.freeChunks}/${widget.totalChunks} 块 · 还有 $remaining 块等你解锁 · '
        : '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kPrimary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPrimary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('🎉 你已完成全部免费内容',
              style: TextStyle(
                  color: kText, fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$counts早鸟 ¥$kEarlyBirdPrice 永久买断',
              style: TextStyle(color: kTextSecondary, fontSize: 13)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              child: Text('了解详情',
                  style: TextStyle(color: kOnPrimary, fontSize: 14)),
              onPressed: () => showWechatPurchaseSheet(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reportCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本次战报',
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
          Text(k, style: TextStyle(color: kTextMuted, fontSize: 13)),
          const Spacer(),
          Text(v,
              style: TextStyle(
                  color: kText,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

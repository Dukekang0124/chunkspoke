import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/chunk_progress.dart';
import '../services/database.dart';
import '../services/crash_log.dart';
import '../services/state_machine.dart';
import '../services/session_report.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'listen_pick_step.dart';
import 'build_step.dart';
import 'l4_step.dart';

/// 练习阶段枚举（值即环节序号，供状态机在两种顺序间切换）。
class Phase {
  static const int listenPick = 0; // ① 听音识块
  static const int speakChunk = 1; // ② 开口说块
  static const int buildSentence = 2; // ③ 块拼句
  static const int speakSentence = 3; // ④ 开口说句
}

/// 会话环节顺序（纯函数，供状态机与单测复用）：
/// 新学 = ①→②→③→④；复习 = ②→④（跳过听辨块与块拼句）。
List<int> phaseOrder({required bool reviewMode}) => reviewMode
    ? const [Phase.speakChunk, Phase.speakSentence]
    : const [
        Phase.listenPick,
        Phase.speakChunk,
        Phase.buildSentence,
        Phase.speakSentence
      ];

/// 五步状态机的「下一环节」：返回 -1 表示本块最后一步（结算掌握）。
/// 新学：0→1→2→3→-1；复习：1→3→-1。
int nextPhase(int cur, {required bool reviewMode}) {
  final order = phaseOrder(reviewMode: reviewMode);
  final i = order.indexOf(cur);
  if (i < 0 || i >= order.length - 1) return -1;
  return order[i + 1];
}

/// 词块拼装练习闭环（v1.2.2·五步）：
///   新学块：① 听音识块 → ② 开口说块 → ③ 块拼句 → ④ 开口说句 → ⑤ 掌握判定
///   复习块（reviewMode）：只走 ② 开口说块 → ④ 开口说句 两步（间隔复习，轻量）。
/// ②④ 双达标 → 绿勾 / 进度 +1 跳动 / 鼓励语 → 进下一块。
/// 块全部完成后（新学模式）进入「句子闯关」（目标句逐句开口说对即过）。
/// 掌握计数：通过即 +1，落盘由 ChunkProgressStore 完成；顶/底圆环读同一数据源（P0-2）。
class PracticeLoop extends StatefulWidget {
  final Level level;

  /// 指定要练的词块序列；缺省为 level.chunks。复习会话用到期块列表传入。
  final List<Chunk>? chunks;

  /// 复习模式：只走 ② 开口说块 + ④ 开口说句 两步。
  final bool reviewMode;
  final void Function(SessionReport report) onDone;
  const PracticeLoop(
      {required this.level,
      this.chunks,
      this.reviewMode = false,
      required this.onDone,
      super.key});

  @override
  State<PracticeLoop> createState() => _PracticeLoopState();
}

class _PracticeLoopState extends State<PracticeLoop> {
  int _ci = 0; // 当前词块索引
  int _phase = Phase.listenPick; // 当前环节序号
  int _mastered = 0; // 本次会话已掌握/已完成块数（进度环）
  bool _ready = false;
  bool _showResume = false;
  int _resumeIndex = 0;
  bool _challenge = false; // 句子闯关模式
  int _si = 0; // 当前目标句索引

  bool _chunkDone = false;
  bool _justMastered = false;
  String _encourage = '';
  Timer? _doneTimer;

  // —— B1 / B6：连对与战报统计（本会话内累计）——
  int _combo = 0; // 连续掌握块数（断连重计）
  int _maxCombo = 0; // 本次最高连对
  int _newMastered = 0; // 本次新掌握块数
  int _spoken = 0; // 本次开口判定通过次数

  List<Chunk> get _chunks => widget.chunks ?? widget.level.chunks;
  Chunk get _chunk => _chunks[_ci];
  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);
  int get _total => _chunks.length;
  int get _challengeTotal => widget.level.sentences.length;
  List<String> get _keys => _chunks.map((c) => c.id).toList(growable: false);

  /// 环节顺序：新学四步；复习两步；首场景前 3 块走加速档（跳过块拼句，A5）。
  List<int> get _order {
    if (widget.reviewMode) return phaseOrder(reviewMode: true);
    if (_accel) {
      return const [
        Phase.listenPick,
        Phase.speakChunk,
        Phase.speakSentence
      ];
    }
    return phaseOrder(reviewMode: false);
  }

  /// A5 加速档：全新用户首场景前 3 块（听音识块→开口说块→开口说句），跳过块拼句。
  bool get _accel => !widget.reviewMode && !_p.firstPracticeDone && _ci < 3;

  int _nextPhaseOf(int cur) => nextPhase(cur, reviewMode: widget.reviewMode);

  final List<String> _cheers = const [
    '搞定！',
    '漂亮！',
    '稳了！',
    '这就是节奏！',
    '记住了！',
    '脱口而出了！',
    '肌肉记忆+1',
    '再来一块！',
    '越来越顺了！',
    '一块到手！',
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _doneTimer?.cancel();
    super.dispose();
  }

  /// 断点续练：找到「下一个未完成块」，并统计已掌握数。
  /// 复习会话不走断点门（每次按到期列表从首个开始）。
  Future<void> _init() async {
    int mastered = 0;
    int start = 0;
    try {
      if (!widget.reviewMode) {
        start = await _p.chunkStore.nextUnmasteredIndex(_keys);
      }
      for (final c in _chunks) {
        final row = await _p.chunkStore.get(c.id);
        if (ChunkProgressStore.isMastered(row)) mastered++;
      }
    } catch (e, st) {
      CrashLog.write('PracticeLoop._init: $e', st);
    }
    if (!mounted) return;
    try {
      if (!_p.firstPracticeStarted) {
        await _p.setFirstPracticeStarted();
        await _p.logEvent('first_practice_start');
      }
    } catch (e, st) {
      CrashLog.write('firstPracticeStart log: $e', st);
    }
    setState(() {
      _resumeIndex = start >= _total ? 0 : start;
      _ci = _resumeIndex;
      _phase = _order.first;
      _mastered = mastered;
      _showResume =
          !widget.reviewMode && mastered > 0 && mastered < _total;
      _ready = true;
    });
  }

  /// 当前词块对应的「目标句」（块拼句 / 开口说句用）；无则回退为该词块自身。
  TargetSentence _sentenceForChunk(Chunk c) {
    for (final s in widget.level.sentences) {
      if (s.chunkIds.contains(c.id)) return s;
    }
    return TargetSentence(
        id: c.id, text: c.text, meaningCN: c.meaningCN, chunkIds: [c.id]);
  }

  /// 后台落盘（不阻塞 UI）：异常只记录，绝不抛回调用方导致卡死。
  Future<void> _persist(ChunkEvent event,
      {int accuracy = 0, bool selfEval = false}) async {
    try {
      await _p.chunkStore.applyEvent(_chunk.id, event,
          accuracy: accuracy, selfEval: selfEval);
    } catch (e, st) {
      CrashLog.write('applyEvent($event) 失败（已乐观推进，不阻塞）: $e', st);
    }
  }

  /// 通过当前环节 → 按顺序切到下一环节并后台落盘。
  /// 若已是本会话最后一步（新学=开口说句 / 复习=开口说句），则结算掌握。
  void _passPhase(ChunkEvent event,
      {int accuracy = 0, bool selfEval = false}) {
    if (!mounted) return;
    final next = _nextPhaseOf(_phase);
    if (next < 0) {
      _onChunkComplete();
      return;
    }
    setState(() => _phase = next);
    _persist(event, accuracy: accuracy, selfEval: selfEval);
  }

  void _advance() {
    if (_ci < _total - 1) {
      setState(() {
        _ci++;
        _phase = _order.first;
      });
    } else {
      widget.onDone(_report());
    }
  }

  SessionReport _report() => SessionReport(
        newMastered: _newMastered,
        spoken: _spoken,
        maxCombo: _maxCombo,
        reviewed: widget.reviewMode ? _total : 0,
      );

  void _enterChallenge() {
    if (!mounted) return;
    setState(() {
      _challenge = true;
      _si = 0;
    });
  }

  void _challengeNext() {
    if (_si < _challengeTotal - 1) {
      setState(() => _si++);
    } else {
      widget.onDone(_report());
    }
  }

  /// 一块完成 → ⑤ 掌握判定 + 反馈三件套（绿勾 / 进度跳动 / 鼓励语）。
  Future<void> _onChunkComplete({bool? mastered, bool deferToReview = false}) async {
    // 真实出口：主动跳过/延期 → 置复习队列 + 次日到期，推进到下一块。
    if (deferToReview) {
      await _scheduleReview(_chunk.id);
      if (!mounted) return;
      _advance();
      return;
    }
    final justMastered = mastered ??
        ChunkProgressStore.isMastered(await _safeGet(_chunk.id));
    if (!mounted) return;
    final remaining = _total - (_ci + 1);
    if (justMastered) {
      try {
        await _p.bumpStreak();
      } catch (e, st) {
        CrashLog.write('bumpStreak: $e', st);
      }
      try {
        if (!_p.firstPracticeDone) {
          await _p.setFirstPracticeDone();
          await _p.logEvent('first_practice_done');
        }
      } catch (e, st) {
        CrashLog.write('firstPracticeDone log: $e', st);
      }
      _mastered++;
      _combo++;
      if (_combo > _maxCombo) _maxCombo = _combo;
      _newMastered++;
      _maybeCelebrateMilestone(); // 非阻塞：跨里程碑弹全屏庆祝（A4）
    } else {
      _combo = 0; // 断连重计（B1）
    }
    setState(() {
      _chunkDone = true;
      _justMastered = justMastered;
      _encourage = justMastered
          ? '${_cheers[_ci % _cheers.length]} 还剩 $remaining 个'
          : '没到 80%，现在再练一遍';
    });
    _doneTimer?.cancel();
    if (!justMastered) {
      _doneTimer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        setState(() {
          _chunkDone = false;
          _phase = _order.first;
        });
      });
      return;
    }
    _doneTimer = Timer(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      setState(() => _chunkDone = false);
      // 新学模式最后一块掌握且本场景有目标句 → 进入「句子闯关」；复习模式直接结束。
      if (!widget.reviewMode && _ci == _total - 1 && _challengeTotal > 0) {
        _enterChallenge();
      } else {
        _advance();
      }
    });
  }

  /// 主动跳过/延期：置复习队列 + 次日到期（容错，失败不阻断推进）。
  Future<void> _scheduleReview(String key) async {
    try {
      await _p.chunkStore.applyEvent(key, ChunkEvent.scheduleReview);
    } catch (e, st) {
      CrashLog.write('scheduleReview($key): $e', st);
    }
  }

  /// A4：跨里程碑（10/25/50/100）弹全屏庆祝 + 可保存战报卡。
  Future<void> _maybeCelebrateMilestone() async {
    int? ms;
    try {
      ms = await _p.pendingMilestone();
    } catch (e, st) {
      CrashLog.write('pendingMilestone: $e', st);
    }
    if (ms == null || !mounted) return;
    final milestone = ms; // 提升为非空，供闭包捕获
    try {
      await _p.markMilestoneCelebrated(milestone);
    } catch (e, st) {
      CrashLog.write('markMilestone: $e', st);
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MilestoneDialog(
          milestone: milestone,
          onSave: () => _saveMilestoneReport(milestone)),
    );
  }

  Future<void> _saveMilestoneReport(int ms) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/chunkspoke_milestone_$ms.txt');
      final now = DateTime.now();
      await f.writeAsString(
        'ChunkSpoke 里程碑战报\n'
        '累计掌握：$ms 块\n'
        '连续打卡：${_p.streak} 天\n'
        '今日开口：${_p.todaySpoken} 句\n'
        '日期：${now.year}-${now.month}-${now.day}\n',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('战报卡已保存到 ${f.path}'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e, st) {
      CrashLog.write('saveMilestoneReport: $e', st);
    }
  }

  Future<ChunkRow> _safeGet(String key) async {
    try {
      return await _p.chunkStore.get(key);
    } catch (e, st) {
      CrashLog.write('PracticeLoop.get($key): $e', st);
      return ChunkRow(chunkKey: key, level: ChunkLevel.l1, dueDate: 0,
          failCount: 0, lastScore: 0);
    }
  }

  String _phaseLabel() {
    if (_challenge) return '句子闯关';
    switch (_phase) {
      case Phase.listenPick:
        return '听音识块';
      case Phase.speakChunk:
        return widget.reviewMode ? '复习·开口说块' : '开口说块';
      case Phase.buildSentence:
        return '块拼句';
      default:
        return widget.reviewMode ? '复习·开口说句' : '开口说句';
    }
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            MasteryRing(_total > 0 ? _mastered / _total : 0, size: 38),
            const SizedBox(width: 8),
            Text(widget.reviewMode ? '复习 $_mastered/$_total' : '已掌握 $_mastered/$_total',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const Spacer(),
            Text(_phaseLabel(),
                style: const TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            if (_challenge)
              Text('第 ${_si + 1}/$_challengeTotal 句',
                  style: const TextStyle(color: Colors.white54, fontSize: 13))
            else
              Text('第 ${_ci + 1}/$_total 块',
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      );

  Widget _resumeGate() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              MasteryRing(_total > 0 ? _mastered / _total : 0, size: 84),
              const SizedBox(height: 16),
              Text('已掌握 $_mastered/$_total',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('上次学到第 ${_resumeIndex + 1} 块',
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => setState(() {
                    _showResume = false;
                    _ci = _resumeIndex;
                    _phase = _order.first;
                  }),
                  child: Text('继续 · 第 ${_resumeIndex + 1} 块',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => setState(() {
                  _showResume = false;
                  _ci = 0;
                  _phase = _order.first;
                }),
                child: const Text('从头开始',
                    style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
        ),
      );

  Widget _chunkDoneView() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // B4 掌握盖章：已掌握时盖「已掌握」章，否则绿勾。
            if (_justMastered)
              Transform.rotate(
                angle: -0.15,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: kPrimary, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('已掌握',
                      style: TextStyle(
                          color: kPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2)),
                ),
              )
            else
              const Icon(Icons.check_circle, color: kUnlocked, size: 72),
            const SizedBox(height: 12),
            Text(_encourage,
                style: const TextStyle(
                    color: kUnlocked, fontSize: 18, fontWeight: FontWeight.w600)),
            // B1：连对 ≥3 显示 Combo xN（断连重计）。
            if (_combo >= 3) ...[
              const SizedBox(height: 8),
              Text('Combo x$_combo',
                  style: const TextStyle(
                      color: kPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 14),
            MasteryRing(_total > 0 ? _mastered / _total : 0, size: 60),
            const SizedBox(height: 8),
            Text(widget.reviewMode ? '复习 $_mastered/$_total' : '已掌握 $_mastered/$_total',
                style: const TextStyle(color: Colors.white70)),
          ],
        ),
      );

  Widget _body() {
    if (_challenge) {
      final s = widget.level.sentences[_si];
      return L4Step(
        chunk: _chunk,
        levelId: widget.level.id,
        theme: widget.level.theme,
        targetText: s.text,
        persist: false,
        onPass: () {
          _spoken++;
          _challengeNext();
        },
        onSkip: _challengeNext,
      );
    }
    switch (_phase) {
      case Phase.listenPick:
        return ListenPickStep(
          chunk: _chunk,
          level: widget.level,
          onDone: () => _passPhase(ChunkEvent.assembleCorrect),
        );
      case Phase.speakChunk:
        return L4Step(
          chunk: _chunk,
          levelId: widget.level.id,
          theme: widget.level.theme,
          targetText: _chunk.text,
          // 说块只推进到下一环节（dragCorrect），不再落 speakSuccess，
          // 避免「说块」与「说句」重复写掌握事件（S2）。
          persist: false,
          onPass: () {
            _spoken++;
            _passPhase(ChunkEvent.dragCorrect);
          },
          onSkip: () => _onChunkComplete(deferToReview: true),
        );
      case Phase.buildSentence:
        return BuildStep(
          level: widget.level,
          chunk: _chunk,
          sentence: _sentenceForChunk(_chunk),
          // 拼句正确完成 = 本步准确度满分，避免 lastScore 被冲成 0（S3）。
          onDone: () => _passPhase(ChunkEvent.accuracyPass, accuracy: 100),
        );
      default:
        final s = _sentenceForChunk(_chunk);
        return L4Step(
          chunk: _chunk,
          levelId: widget.level.id,
          theme: widget.level.theme,
          targetText: s.text,
          // 掌握与否以落盘后的 store 判定为准，不无条件 +1（S1）。
          onPass: () {
            _spoken++;
            _onChunkComplete();
          },
          onSkip: () => _onChunkComplete(deferToReview: true),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator(color: kPrimary));
    }
    if (_showResume) return _resumeGate();
    return Column(
      children: [
        _header(),
        Expanded(child: _chunkDone ? _chunkDoneView() : _body()),
      ],
    );
  }
}

/// A4：里程碑全屏庆祝弹窗 + 可保存战报卡（数字全部真实）。
class _MilestoneDialog extends StatelessWidget {
  final int milestone;
  final VoidCallback onSave;
  const _MilestoneDialog({required this.milestone, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final p = Provider.of<ProgressService>(context, listen: false);
    return Dialog(
      backgroundColor: kCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events, color: kPrimary, size: 64),
            const SizedBox(height: 12),
            const Text('里程碑达成 🎉',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('累计掌握 $milestone 块',
                style: const TextStyle(
                    color: kPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('连续打卡 ${p.streak} 天',
                      style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  const SizedBox(height: 6),
                  Text('今日开口 ${p.todaySpoken} 句',
                      style: const TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: onSave,
                child: const Text('保存战报卡',
                    style: TextStyle(
                        color: Colors.black87, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('继续', style: TextStyle(color: kPrimary)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

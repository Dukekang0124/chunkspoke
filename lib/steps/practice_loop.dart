import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/chunk_asset.dart';
import '../services/chunk_progress.dart';
import '../services/database.dart';
import '../services/crash_log.dart';
import '../services/learning_flow.dart';
import '../services/progress_display.dart';
import '../services/progress_integrity.dart';
import '../services/state_machine.dart';
import '../services/session_report.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'anchor_step.dart';
import 'breakdown_step.dart';
import 'free_use_step.dart';
import 'listen_pick_step.dart';
import 'substitute_step.dart';
import 'l4_step.dart';
import '../services/listening_palette.dart';
import '../ui/motion.dart';

/// 闯关切句的 State key：必须随句 id 变化，禁止复用上一句的判定/尝试次数。
Key challengeStepKey(String sentenceId) => ValueKey('challenge_$sentenceId');

/// 句子闯关只属于「完整关卡」会话（X-4 移除后的单一语义）。
/// 收听收词/复习传入显式 chunks → 按块返回；主线关卡 chunks 为空 → 末尾进句挑战。
bool challengeAfterChunks({
  required bool fullLevel,
  required bool mastered,
  required int chunkIndex,
  required int chunkTotal,
  required int sentenceTotal,
}) =>
    fullLevel &&
    mastered &&
    chunkIndex == chunkTotal - 1 &&
    sentenceTotal > 0;

/// 闯关句索引推进：返回 -1 表示本关最后一句已完成。
int nextChallengeIndex(int current, int total) =>
    current < total - 1 ? current + 1 : -1;

/// 六步学习闭环：
///   新学：⓪锚定 → ①拆解 → ②听辨 → ③影子跟读 → ④定向替换 → ⑤自由造句
///   复习：②听辨 → ③跟读 → ④替换 → ⑤开口（四星复用，不重走锚定/拆解）
///
/// 单块 8 分钟预算：超时自动存档并暂停，可「继续这一块」或「先到这里」；
/// 每过一步写断点，杀进程后可从未完成的那一步继续。
class PracticeLoop extends StatefulWidget {
  /// 仅 E2E 入口设置：直接进入句子闯关，跳过六步（生产入口恒为 false）。
  static bool debugStartChallenge = false;

  final Level level;

  /// 指定要练的词块序列；缺省为 level.chunks。复习会话用到期块列表传入。
  final List<Chunk>? chunks;

  /// 复习模式：后四步全走，结果写入词块资产状态机。
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

class _PracticeLoopState extends State<PracticeLoop>
    with WidgetsBindingObserver {
  int _ci = 0;
  int _phase = LearnPhase.anchor;
  StarBoard _stars = StarBoard.empty;
  int _completed = 0; // 本次完成块数（进度环；不再标「已掌握」）
  int _reviewed = 0;
  bool _ready = false;
  bool _showResume = false;
  bool _finished = false;
  LearnResume? _resume;
  int _resumeIndex = 0;

  /// ASR-211 修复 2/6：台账派生的「已掌握块数」（锚定与非锚定会话同一口径）。
  /// 环、断点块号、待通过文案全部读这两个数，不再各算各的。
  int _ledgerMastered = 0;

  /// ASR-211 修复 4/6：本页所有进度文案的唯一渲染模型（自检比对同一个对象）。
  LevelDisplay? _display;

  /// ASR-203 修复 1/3/4：完整关卡会话的对账结果（台账派生的块号、环、完成态）。
  ModuleAudit? _audit;
  bool _showDone = false;

  bool _challenge = false;
  bool _challengeDone = false;
  int _si = 0;
  int _challengeSpoken = 0;
  int _challengeSkipped = 0;

  bool _chunkDone = false;
  bool _justMastered = false;
  bool _paused = false;
  String _encourage = '';
  Timer? _doneTimer;
  Timer? _timeoutTimer;

  // —— 本次会话真实统计（战报与连对）——
  int _combo = 0;
  int _maxCombo = 0;
  int _newMastered = 0;
  int _spoken = 0;
  int _starChunks = 0;

  ProgressService? _progress;

  List<Chunk> get _chunks => widget.chunks ?? widget.level.chunks;
  Chunk get _chunk => _chunks[_ci];
  ProgressService get _p =>
      _progress ?? Provider.of<ProgressService>(context, listen: false);
  int get _total => _chunks.length;
  int get _progressCount => widget.reviewMode ? _reviewed : _completed;
  int get _challengeTotal => widget.level.sentences.length;
  bool get _isFullLevel => widget.chunks == null && !widget.reviewMode;
  List<String> get _keys => _chunks.map((c) => c.id).toList(growable: false);

  List<int> get _order => phaseOrder(reviewMode: widget.reviewMode);

  /// B5：识别词表只服务 E2E 脚本化识别；生产路径走全模型（不传词表），
  /// 避免小语法把无关语音强制解码成目标词。
  List<String> get _recognitionPhrases => [
        for (final s in widget.level.sentences) s.text,
        for (final c in widget.level.chunks) c.text,
      ];

  final List<String> _cheers = const [
    '搞定！',
    '漂亮！',
    '稳了！',
    '这就是节奏！',
    '记住了！',
    '脱口而出了！',
    '肌肉记忆+1',
    '越来越顺了！',
    '一块到手！',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _progress ??= Provider.of<ProgressService>(context, listen: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _writeResume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _doneTimer?.cancel();
    _timeoutTimer?.cancel();
    _writeResume();
    super.dispose();
  }

  Future<void> _init() async {
    if (PracticeLoop.debugStartChallenge && !widget.reviewMode) {
      _ready = true;
      _challenge = true;
      setState(() {});
      return;
    }
    int start = 0;
    int mastered = 0;
    LearnResume? resume;
    final full = _isFullLevel;
    try {
      if (!widget.reviewMode) {
        if (full) {
          // ASR-203 修复 1/4：完整关卡以台账（chunks 表）为唯一事实源。
          // 断点快照只在「与台账一致」时保留块内相位；不一致或整模块已掌握时当场自愈。
          var a = await ProgressIntegrity.audit(_p, widget.level,
              chunks: _chunks);
          if (a.staleSnapshot) {
            try {
              await _p.logEvent('resume_selfheal', {
                'level': a.levelId,
                'snapIndex': a.snapshotIndex,
                'ledgerIndex': a.ledgerNextIndex,
                'mastered': a.ledgerMastered,
                'total': a.total,
                'complete': a.complete,
              });
            } catch (e, st) {
              CrashLog.write('resume_selfheal log: $e', st);
            }
            a = await ProgressIntegrity.heal(_p, widget.level, a);
          }
          _audit = a;
          start = a.ledgerNextIndex;
          mastered = a.ledgerMastered;
        } else {
          start = await _p.chunkStore.nextUnmasteredIndex(_keys);
        }
        // ASR-205：自愈后重新取快照，且只认「与台账锚点同位」的那份。
        // 台账是唯一事实源；快照只提供块内相位。非同位的旧书签一律不采信，
        // 避免单块/复习等非锚定会话把陈旧块号带回来。
        final decoded =
            LearnResume.tryDecode(await _p.learnResumeFromDb(widget.level.id));
        if (decoded != null &&
            start < _total &&
            decoded.chunkIndex == start &&
            _keys[decoded.chunkIndex] == decoded.chunkId) {
          resume = decoded;
        }
      }
      if (!full) {
        for (final c in _chunks) {
          final row = await _p.chunkStore.get(c.id);
          if (row.level == ChunkLevel.mastered) mastered++;
        }
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
    final a = _audit;
    final bool done = full && (a?.complete ?? false);
    final int index;
    final bool showDone;
    final bool showResume;
    if (full && a != null) {
      index = a.startIndex;
      showDone = done;
      // 陈旧「接着上次练」一律废除：只有台账确实停在模块中间某块才弹。
      showResume = !done && a.shouldOfferResume;
    } else {
      // ASR-211 修复 2：非锚定会话（补练 / 自选块 / 复习）同样只认台账派生的位置。
      // 快照只提供块内相位（_continueResume 里取 phase/stars），不再决定第几块——
      // 否则「渲染值」有两个来源，自检按台账算就永远对不上这里的显示。
      index = start >= _total ? 0 : start;
      showDone = false;
      showResume = !widget.reviewMode &&
          (resume != null || (mastered > 0 && mastered < _total));
    }
    setState(() {
      _resume = showResume ? resume : null;
      _resumeIndex = index;
      _ledgerMastered = (full && a != null) ? a.ledgerMastered : mastered;
      _display = (full && a != null)
          ? LevelDisplay.of(a)
          : LevelDisplay(
              theme: widget.level.theme,
              total: _total,
              mastered: mastered,
              gapIndex: index,
              skipped: const [],
              complete: _total > 0 && mastered >= _total,
            );
      _ci = index;
      _phase = _order.first;
      _stars = StarBoard.empty;
      _showDone = showDone;
      _showResume = showResume;
      _ready = true;
    });
    if (!_showResume && !_showDone) {
      _beginChunk(_ci, saveResume: _resume == null);
    }
  }

  // —— 断点存档 ——

  Future<void> _writeResume() async {
    final p = _progress;
    // ASR-211 修复 2：块内书签只属于**锚定会话**（整模块闯关）。
    // 补练/自选块会话的 _ci 是子集内的下标，写进 `learnResume_<levelId>` 会把
    // 整模块的断点拽偏（案三「台账 21/25、断点第 10 块」的次路径来源之一）。
    // 子集会话完成时的断点仍由 chunkStore 的台账派生式落，不经这里。
    if (p == null ||
        widget.reviewMode ||
        !_isFullLevel ||
        _challenge ||
        _finished) {
      return;
    }
    if (!_ready || _ci >= _total) return;
    try {
      final data = LearnResume(
        chunkIndex: _ci,
        chunkId: _chunk.id,
        phase: _phase,
        stars: _stars,
        savedAt: p.now.millisecondsSinceEpoch,
      ).encode();
      await p.setLearnResume(widget.level.id, data);
    } catch (e, st) {
      CrashLog.write('PracticeLoop.saveResume: $e', st);
    }
  }

  Future<void> _clearResume() async {
    try {
      await _p.clearLearnResume(widget.level.id);
    } catch (e, st) {
      CrashLog.write('PracticeLoop.clearResume: $e', st);
    }
  }

  // —— 阶段推进 ——

  void _beginChunk(int index, {bool saveResume = true}) {
    _timeoutTimer?.cancel();
    setState(() {
      _ci = index;
      _phase = _order.first;
      _stars = StarBoard.empty;
    });
    _startTimeout();
    if (saveResume) _writeResume();
    _logPhase();
  }

  void _startTimeout() {
    _timeoutTimer?.cancel();
    if (widget.reviewMode || _challenge) return;
    _timeoutTimer = Timer(kLearnChunkTimeout, _onTimeout);
  }

  void _onTimeout() {
    if (!mounted || widget.reviewMode || _challenge || _chunkDone) return;
    _writeResume();
    try {
      Provider.of<TtsService>(context, listen: false).stop();
    } catch (_) {}
    setState(() => _paused = true);
  }

  void _logPhase() {
    if (!mounted || _challenge) return;
    _p
        .logEvent('learn_phase', {
          'phase': _phase,
          'mode': widget.reviewMode ? 'review' : 'learn',
          'chunk': _chunk.id,
        })
        .catchError((_) {});
  }

  void _setPhase(int next) {
    if (!mounted) return;
    setState(() => _phase = next);
    _writeResume();
    _logPhase();
  }

  void _advanceFromPhase(int next,
      {int accuracy = 0,
      bool selfEval = false,
      bool fourStarsGreen = false,
      bool enforceFourStars = false,
      ChunkEvent? event}) {
    if (event != null) {
      _persist(event,
          accuracy: accuracy,
          selfEval: selfEval,
          fourStarsGreen: fourStarsGreen,
          enforceFourStars: enforceFourStars);
    }
    if (next < 0) {
      _finishChunk();
    } else {
      _setPhase(next);
    }
  }

  /// 后台落盘（不阻塞 UI）：异常只记录，绝不抛回导致卡死。
  Future<void> _persist(ChunkEvent event,
      {int accuracy = 0,
      bool selfEval = false,
      bool fourStarsGreen = false,
      bool enforceFourStars = false,
      Map<String, String>? alsoKv}) async {
    try {
      await _p.chunkStore.applyEvent(_chunk.id, event,
          accuracy: accuracy,
          selfEval: selfEval,
          review: widget.reviewMode,
          fourStarsGreen: fourStarsGreen,
          enforceFourStars: enforceFourStars,
          alsoKv: alsoKv);
    } catch (e, st) {
      CrashLog.write('applyEvent($event) 失败（已乐观推进，不阻塞）: $e', st);
    }
  }

  // —— 各步完成 ——

  void _onListenDone(ListenPickResult r) {
    setState(() => _stars = _stars.copyWith(listen: r.star));
    _advanceFromPhase(
      nextPhase(LearnPhase.listen, reviewMode: widget.reviewMode),
      event: widget.reviewMode ? null : ChunkEvent.assembleCorrect,
    );
  }

  void _onShadowDone(bool passed) {
    if (!passed && widget.reviewMode) {
      _deferReviewChunk('已跳过这块，明天再来');
      return;
    }
    setState(() => _stars = _stars.copyWith(speak: passed));
    if (passed) _spoken++;
    _advanceFromPhase(
      nextPhase(LearnPhase.shadow, reviewMode: widget.reviewMode),
      event: (!widget.reviewMode && passed) ? ChunkEvent.dragCorrect : null,
    );
  }

  void _onSubstituteDone(int? accuracy) {
    if (accuracy == null && widget.reviewMode) {
      _deferReviewChunk('已跳过这块，明天再来');
      return;
    }
    setState(() => _stars = _stars.copyWith(substitute: accuracy != null));
    if (accuracy != null) _spoken++;
    _advanceFromPhase(
      nextPhase(LearnPhase.substitute, reviewMode: widget.reviewMode),
      accuracy: 100,
      event: (!widget.reviewMode && accuracy != null)
          ? ChunkEvent.accuracyPass
          : null,
    );
  }

  void _onFreeUseDone(int accuracy) {
    setState(() => _stars = _stars.copyWith(free: true));
    _spoken++;
    _finishChunk();
  }

  void _onReviewSpoken(int accuracy) {
    setState(() => _stars = _stars.copyWith(free: true));
    _spoken++;
    _finishChunk();
  }

  void _onFreeUseSkip() {
    if (widget.reviewMode) {
      _deferReviewChunk('已顺延到明天');
      return;
    }
    _scheduleReview();
    _completed++;
    _combo = 0;
    _showStamp(
      mastered: false,
      stamp: '已存档',
      encourage: '这块先存着，明天再来巩固',
      next: _afterChunkNext(),
    );
  }

  void _deferReviewChunk(String encourage) {
    _persist(ChunkEvent.deferReview);
    _reviewed++;
    _showStamp(
      mastered: false,
      stamp: '明天再来',
      encourage: encourage,
      next: _afterChunkNext(),
    );
  }

  void _finishChunk() {
    if (widget.reviewMode) {
      _finishReviewChunk();
      return;
    }
    _finishLearningChunk();
  }

  Future<void> _finishLearningChunk() async {
    final allGreen = _stars.allGreen;
    final before = await _safeGet(_chunk.id);
    // ASR-203 修复 2：本块完成与断点快照同事务落盘。
    // 台账推进到哪一块，快照就同步到哪一块（最后一块完成则清空），
    // 进程即便在中间被杀，也不会留下「台账已推进、断点停在旧块」的双源分歧。
    final alsoKv = _isFullLevel
        ? ProgressIntegrity.resumeKvAfterChunkDone(
            levelId: widget.level.id,
            keys: _keys,
            doneIndex: _ci,
            nowMs: _p.now.millisecondsSinceEpoch)
        : null;
    await _persist(
      ChunkEvent.speakSuccess,
      accuracy: 100,
      fourStarsGreen: allGreen,
      enforceFourStars: true,
      alsoKv: alsoKv,
    );
    final row = await _safeGet(_chunk.id);
    if (!mounted) return;
    final mastered = row.level == ChunkLevel.mastered;
    // 盖章文案跟资产轴走：关卡轴 mastered 只影响场景解锁，不代表词块已掌握。
    final assetMastered = row.assetState == ChunkAssetState.mastered &&
        ChunkProgressStore.isMastered(row);
    final newlyMastered =
        mastered && before.level != ChunkLevel.mastered;
    _completed++;
    if (allGreen) _starChunks++;
    if (newlyMastered) {
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
      _combo++;
      if (_combo > _maxCombo) _maxCombo = _combo;
      _newMastered++;
      _maybeCelebrateMilestone();
    } else {
      _combo = 0;
    }
    if (!mounted) return;
    final remaining = _total - (_ci + 1);
    final dueText =
        row.dueDate > 0 ? '下次 ${_md(row.dueDate)} 复习' : '已排进巩固复习';
    _showStamp(
      mastered: assetMastered,
      stamp: assetMastered ? '已掌握' : '本块完成',
      encourage: assetMastered
          ? '${_cheers[_ci % _cheers.length]} 四星全绿 · 还剩 $remaining 个'
          : '拿到 ${_stars.count}/4 星 · $dueText',
      // 单一语义（X-4 移除）：句子闯关只属于「完整关卡」会话；
      // 单块六步（收听收词/复习）按块返回，不触发句挑战。
      next: challengeAfterChunks(
              fullLevel: _isFullLevel,
              mastered: mastered,
              chunkIndex: _ci,
              chunkTotal: _total,
              sentenceTotal: _challengeTotal)
          ? const WalkNext.challenge()
          : _afterChunkNext(),
    );
  }

  Future<void> _finishReviewChunk() async {
    final row = await _safeGet(_chunk.id);
    if (!mounted) return;
    _reviewed++;
    final assetMastered = row.assetState == ChunkAssetState.mastered &&
        ChunkProgressStore.isMastered(row);
    final nextDue = row.dueDate > 0 ? ' · 下次 ${_md(row.dueDate)}' : '';
    _showStamp(
      mastered: assetMastered,
      stamp: assetMastered ? '已掌握' : '复习完成',
      encourage:
          assetMastered ? '复习通过 · 已进入长期记忆' : '复习完成$nextDue',
      next: _afterChunkNext(),
    );
  }

  void _showStamp({
    required bool mastered,
    required String stamp,
    required String encourage,
    required WalkNext next,
  }) {
    if (!mounted) return;
    _timeoutTimer?.cancel();
    setState(() {
      _chunkDone = true;
      _justMastered = mastered;
      _encourage = encourage;
      _stampText = stamp;
    });
    _doneTimer?.cancel();
    _doneTimer = Timer(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      setState(() => _chunkDone = false);
      if (next.challenge) {
        _enterChallenge();
      } else {
        _advance();
      }
    });
  }

  String _stampText = '本块完成';

  WalkNext _afterChunkNext() =>
      _ci < _total - 1 ? const WalkNext.chunk() : const WalkNext.finish();

  void _advance() {
    _timeoutTimer?.cancel();
    if (_ci < _total - 1) {
      _beginChunk(_ci + 1);
    } else {
      _finishAll();
    }
  }

  Future<void> _finishAll() async {
    _finished = true;
    await _clearResume();
    if (!mounted) return;
    widget.onDone(_report());
  }

  SessionReport _report() => SessionReport(
        newMastered: _newMastered,
        spoken: _spoken,
        maxCombo: _maxCombo,
        reviewed: widget.reviewMode ? _reviewed : 0,
        completed: _completed,
        starChunks: _starChunks,
      );

  String _md(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}月${d.day}日';
  }

  // —— 句子闯关（保持不变）——

  void _enterChallenge() {
    if (!mounted) return;
    _clearResume();
    setState(() {
      _challenge = true;
      _challengeDone = false;
      _si = 0;
      _challengeSpoken = 0;
      _challengeSkipped = 0;
    });
  }

  void _challengeNext() {
    final next = nextChallengeIndex(_si, _challengeTotal);
    if (next >= 0) {
      setState(() => _si = next);
    } else {
      setState(() => _challengeDone = true);
    }
  }

  void _challengeSkip() {
    _challengeSkipped++;
    _challengeNext();
  }

  Future<void> _scheduleReview() async {
    try {
      await _p.chunkStore.applyEvent(_chunk.id, ChunkEvent.scheduleReview);
    } catch (e, st) {
      CrashLog.write('scheduleReview(${_chunk.id}): $e', st);
    }
  }

  /// A4：跨里程碑（10/25/50/100）弹全屏庆祝 + 可保存战报卡。
  /// W2-1：里程碑按资产轴「已掌握」计数。
  Future<void> _maybeCelebrateMilestone() async {
    int? ms;
    try {
      ms = await _p.pendingMilestone();
    } catch (e, st) {
      CrashLog.write('pendingMilestone: $e', st);
    }
    if (ms == null || !mounted) return;
    final milestone = ms;
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
        '已掌握（资产轴）：$ms 块\n'
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
      return ChunkRow(
          chunkKey: key,
          level: ChunkLevel.l1,
          dueDate: 0,
          failCount: 0,
          lastScore: 0);
    }
  }

  /// 当前词块对应的「目标句」；无则回退为该词块自身。
  TargetSentence _sentenceForChunk(Chunk c) {
    for (final s in widget.level.sentences) {
      if (s.chunkIds.contains(c.id)) return s;
    }
    return TargetSentence(
        id: c.id, text: c.text, meaningCN: c.meaningCN, chunkIds: [c.id]);
  }

  List<Chunk> get _allChunks {
    final content = Provider.of<ContentPack>(context, listen: false);
    return [for (final lv in content.levels) ...lv.chunks];
  }

  // —— UI ——

  Widget _header() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            MasteryRing(_total > 0 ? _progressCount / _total : 0, size: 38),
            const SizedBox(width: 8),
            Text(
                widget.reviewMode
                    ? '复习 $_reviewed/$_total'
                    : '本次完成 $_completed/$_total',
                style:
                    TextStyle(color: kTextSecondary, fontSize: 13)),
            const Spacer(),
            Text('${phaseLabel(_phase, reviewMode: widget.reviewMode)} · '
                '⭐${_stars.count}/4',
                style: TextStyle(
                    color: kPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            if (_challenge)
              Text(
                  _challengeDone
                      ? '$_challengeTotal/$_challengeTotal 句'
                      : '第 ${_si + 1}/$_challengeTotal 句',
                  style: TextStyle(color: kTextMuted, fontSize: 13))
            else
              Text('第 ${_ci + 1}/$_total 块',
                  style: TextStyle(color: kTextMuted, fontSize: 13)),
          ],
        ),
      );

  Widget _resumeGate() {
    final a = _audit;
    final r = _resume;
    final d = _display;
    // ASR-211 修复 2：这里的块号与真正会打开的位置必须同源（台账派生的 _resumeIndex）。
    // 快照的 chunkIndex 不再参与显示——「写着第 10 块、进去练第 22 块」就是这么来的。
    //
    // ASR-211 修复 6：跳块时（后面已掌握、前面还欠着）「上次学到 第 X 块」是误导，
    // 换成语义正确的「第 X 块待通过 · 已掌握 N/M」，两个数同时报。
    final bool gapAhead = d?.gapAhead ?? false;
    final int pending = a?.pendingChunkIds.length ?? 0;
    final phaseSuffix =
        r == null ? '' : ' · ${phaseLabel(r.phase, reviewMode: false)}';
    final headline = d == null
        ? '第 ${_resumeIndex + 1} 块'
        : (d.gapAhead ? d.anchorLine : '上次学到 ${d.anchorLine}');
    final double ring = d?.ring ?? (_total > 0 ? _ledgerMastered / _total : 0.0);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MasteryRing(ring, size: 84),
            const SizedBox(height: 16),
            Text('接着上次练',
                style: TextStyle(
                    color: kText,
                    fontSize: 22,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('$headline$phaseSuffix',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextSecondary, fontSize: 15)),
            if (gapAhead) ...[
              const SizedBox(height: 6),
              Text('后面已有 $pending 块之外的词练过了，先补这一块就接上',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextMuted, fontSize: 13)),
            ],
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
                onPressed: _continueResume,
                child: Text('继续 · 第 ${_resumeIndex + 1} 块$phaseSuffix',
                    style: TextStyle(
                        color: kOnPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 10),
            if (gapAhead && pending > 0)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _startPendingCatchup,
                  child: Text('补练未通过块（$pending）',
                      style: TextStyle(color: kTextSecondary)),
                ),
              ),
            TextButton(
              onPressed: () {
                _clearResume();
                setState(() {
                  _showResume = false;
                  _resume = null;
                });
                _beginChunk(0);
              },
              child: Text('从头开始',
                  style: TextStyle(color: kTextMuted)),
            ),
          ],
        ),
      ),
    );
  }

  /// ASR-211 修复 6：跳块补练入口——把本模块**未掌握**的块按课文顺序排成一个子会话。
  /// 走非锚定路径（chunks != null），与「错块复习」同一套挂载方式。
  void _startPendingCatchup() {
    final pending = (_audit?.pendingChunkIds ?? const <String>[]).toSet();
    final list =
        widget.level.chunks.where((c) => pending.contains(c.id)).toList();
    if (list.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('补练未通过块')),
        body: PracticeLoop(
          level: widget.level,
          chunks: list,
          onDone: (_) => Navigator.of(context).maybePop(),
        ),
      ),
    ));
  }

  void _continueResume() {
    final r = _resume;
    setState(() => _showResume = false);
    if (r == null) {
      _beginChunk(_resumeIndex, saveResume: false);
      return;
    }
    _timeoutTimer?.cancel();
    setState(() {
      // ASR-211 修复 2：位置来自台账（_resumeIndex），快照只补相位与星数。
      _ci = _resumeIndex.clamp(0, _total - 1);
      _phase = _order.contains(r.phase) ? r.phase : _order.first;
      _stars = r.stars;
    });
    _startTimeout();
    _writeResume();
    _logPhase();
  }

  /// ASR-203 修复 3：整模块掌握后的完成态门。
  ///
  /// 台账 25/25 时不再弹陈旧的「接着上次练 · 第 21 块」，而是如实显示
  /// 「已完成 25/25」+ 环 100%，并给两条真实出路：错块复习 / 从头开始。
  Widget _doneGate() {
    final a = _audit!;
    final wrong = a.wrongChunkIds.length;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MasteryRing(a.ringRatio, size: 84),
            const SizedBox(height: 16),
            Text('已完成 ${a.ledgerMastered}/${a.total}',
                key: const Key('done-gate-title'),
                style: TextStyle(
                    color: kText,
                    fontSize: 22,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
                wrong == 0
                    ? '本模块每一块都已掌握，可以再过一遍巩固。'
                    : '其中 $wrong 块留痕偏弱（一次没过或开口分低于 80），建议先错块复习。',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextSecondary, fontSize: 15)),
            const SizedBox(height: 26),
            if (wrong > 0) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('done-gate-review-wrong'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _startWrongChunkReview,
                  child: Text('错块复习（$wrong 块）',
                      style: TextStyle(
                          color: kOnPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                key: const Key('done-gate-restart'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kTextSecondary,
                  side: BorderSide(color: kBorderStrong),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _restartFromTop,
                child: const Text('从头开始',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text('返回地图', style: TextStyle(color: kTextMuted)),
            ),
          ],
        ),
      ),
    );
  }

  /// 完成态 → 错块复习：只把「已掌握但留痕不合格」的块排进复习会话。
  void _startWrongChunkReview() {
    final wrong = (_audit?.wrongChunkIds ?? const <String>[]).toSet();
    final list =
        widget.level.chunks.where((c) => wrong.contains(c.id)).toList();
    if (list.isEmpty) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('错块复习')),
        body: PracticeLoop(
          level: widget.level,
          chunks: list,
          reviewMode: true,
          onDone: (_) => Navigator.of(context).maybePop(),
        ),
      ),
    ));
  }

  /// 完成态 → 从头开始：清空快照，从第 1 块重走六步。
  void _restartFromTop() {
    _clearResume();
    setState(() {
      _showDone = false;
      _showResume = false;
      _resume = null;
      _completed = 0;
    });
    _beginChunk(0);
  }

  Widget _pauseView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.timer_outlined, color: kPrimary, size: 56),
              const SizedBox(height: 14),
              Text('这一块练了 8 分钟',
                  style: TextStyle(
                      color: kText,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  '进度已保存：第 ${_ci + 1}/$_total 块 · '
                  '${phaseLabel(_phase, reviewMode: false)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextSecondary, fontSize: 15)),
              const SizedBox(height: 6),
              Text('短时高频比一口气硬撑更记得住',
                  style: TextStyle(color: kTextFaint, fontSize: 13)),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: () {
                    setState(() => _paused = false);
                    _startTimeout();
                  },
                  child: Text('继续这一块',
                      style: TextStyle(
                          color: kOnPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () async {
                  await _writeResume();
                  if (mounted) Navigator.of(context).maybePop();
                },
                child: Text('先到这里',
                    style: TextStyle(color: kTextMuted)),
              ),
            ],
          ),
        ),
      );

  Widget _chunkDoneView() {
    final policy = Motion.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // M1（P0-2）：盖章弹入对齐闯关完成页既有模式（520ms、超调 ≤8%）；
          // 升档时描边由琥珀渐变到金，不硬换色。
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.45, end: 1),
            duration: policy.dur(520),
            curve: const Cubic(0.34, 1.56, 0.64, 1),
            builder: (_, v, child) => Transform.scale(scale: v, child: child),
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(
                begin: kPrimary,
                end: _justMastered
                    ? kListeningMasteredText
                    : kTextFaint,
              ),
              duration: policy.dur(360),
              curve: Curves.easeOut,
              builder: (_, accent, __) => Transform.rotate(
                angle: -0.15,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: accent ?? kPrimary, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_stampText,
                      style: TextStyle(
                          color: _justMastered
                              ? (accent ?? kListeningMasteredText)
                              : kTextSecondary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(_encourage,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: kUnlocked,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          if (!widget.reviewMode && _combo >= 3) ...[
            const SizedBox(height: 8),
            Text('Combo x$_combo',
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 14),
          MasteryRing(_total > 0 ? _progressCount / _total : 0, size: 60),
          const SizedBox(height: 8),
          Text(
              widget.reviewMode
                  ? '复习 $_reviewed/$_total'
                  : '本次完成 $_completed/$_total',
              style: TextStyle(color: kTextSecondary)),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(color: kTextMuted, fontSize: 13)),
            const SizedBox(width: 6),
            Text(value,
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _challengeDoneView() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.45, end: 1),
                duration: Motion.of(context).dur(520),
                curve: const Cubic(0.34, 1.56, 0.64, 1),
                builder: (_, v, child) =>
                    Transform.scale(scale: v, child: child),
                child:
                    Icon(Icons.emoji_events, color: kPrimary, size: 84),
              ),
              const SizedBox(height: 10),
              Text('闯关完成！',
                  style: TextStyle(
                      color: kText,
                      fontSize: 26,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('第 ${widget.level.id} 关 · $_challengeTotal/$_challengeTotal 句',
                  style: TextStyle(color: kTextSecondary, fontSize: 15)),
              const SizedBox(height: 18),
              Transform.rotate(
                angle: -0.12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: kPrimary, width: 2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('已通关',
                      style: TextStyle(
                          color: kPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 4)),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _statChip('命中', '$_challengeSpoken 句'),
                  const SizedBox(width: 12),
                  _statChip('跳过', '$_challengeSkipped 句'),
                ],
              ),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: () => widget.onDone(_report()),
                  child: Text('收下盖章 · 完成',
                      style: TextStyle(
                          color: kOnPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _body() {
    if (_challenge) {
      final s = widget.level.sentences[_si];
      final isLast = _si == _challengeTotal - 1;
      return L4Step(
        key: challengeStepKey(s.id),
        chunk: _chunk,
        levelId: widget.level.id,
        theme: widget.level.theme,
        targetText: s.text,
        persist: false,
        recognitionPhrases: _recognitionPhrases,
        passAdvanceDelay: const Duration(milliseconds: 1500),
        passActionLabel: isLast ? '查看闯关结果' : '下一句',
        skipHint: '先跳过这一句',
        onPass: () {
          _spoken++;
          _challengeSpoken++;
          _challengeNext();
        },
        onSkip: _challengeSkip,
      );
    }
    final stepKey = ValueKey(
        '${widget.reviewMode ? 'r' : 'l'}_${_ci}_${_phase}_${_chunk.id}');
    switch (_phase) {
      case LearnPhase.anchor:
        return AnchorStep(
          key: stepKey,
          chunk: _chunk,
          level: widget.level,
          chunkIndex: _ci,
          chunkTotal: _total,
          onDone: () => _setPhase(LearnPhase.breakdown),
        );
      case LearnPhase.breakdown:
        return BreakdownStep(
          key: stepKey,
          chunk: _chunk,
          level: widget.level,
          onDone: () => _setPhase(LearnPhase.listen),
        );
      case LearnPhase.listen:
        return ListenPickStep(
          key: stepKey,
          chunk: _chunk,
          level: widget.level,
          rounds: widget.reviewMode ? 2 : 3,
          onDone: _onListenDone,
        );
      case LearnPhase.shadow:
        return L4Step(
          key: stepKey,
          chunk: _chunk,
          levelId: widget.level.id,
          theme: widget.level.theme,
          targetText: _chunk.text,
          // 跟读只推进流程，掌握事件统一在最后一步结算。
          persist: false,
          review: false,
          recognitionPhrases: _recognitionPhrases,
          skipHint: widget.reviewMode ? '先跳过这块，明天再来' : '先跳过这一步',
          onPass: () => _onShadowDone(true),
          onSkip: () => _onShadowDone(false),
        );
      case LearnPhase.substitute:
        final s = _sentenceForChunk(_chunk);
        final plan = buildSubstitutionPlan(
          chunk: _chunk,
          sentence: s,
          allChunks: _allChunks,
        );
        return SubstituteStep(
          key: stepKey,
          chunk: _chunk,
          level: widget.level,
          plan: plan,
          meaningCN: s.meaningCN,
          review: widget.reviewMode,
          onPass: (acc) => _onSubstituteDone(acc),
          onSkip: () => _onSubstituteDone(null),
        );
      default:
        final s = _sentenceForChunk(_chunk);
        if (widget.reviewMode) {
          return L4Step(
            key: stepKey,
            chunk: _chunk,
            levelId: widget.level.id,
            theme: widget.level.theme,
            targetText: s.text,
            review: true,
            recognitionPhrases: _recognitionPhrases,
            skipHint: '先跳过这块，明天再来',
            onPass: () {
              _onReviewSpoken(100);
            },
            onSkip: () => _deferReviewChunk('已顺延到明天'),
          );
        }
        return FreeUseStep(
          key: stepKey,
          chunk: _chunk,
          level: widget.level,
          referenceText: s.text,
          meaningCN: s.meaningCN,
          onPass: _onFreeUseDone,
          onSkip: _onFreeUseSkip,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Center(child: CircularProgressIndicator(color: kPrimary));
    }
    if (_showDone) return _doneGate();
    if (_showResume) return _resumeGate();
    if (_paused) return _pauseView();
    return Column(
      children: [
        _header(),
        Expanded(
            child: _challengeDone
                ? _challengeDoneView()
                : (_chunkDone ? _chunkDoneView() : _body())),
      ],
    );
  }
}

/// 下一步去向：继续下一块 / 进句子闯关 / 收尾。
class WalkNext {
  final bool challenge;
  const WalkNext.chunk() : challenge = false;
  const WalkNext.finish() : challenge = false;
  const WalkNext.challenge() : challenge = true;
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
            Icon(Icons.emoji_events, color: kPrimary, size: 64),
            const SizedBox(height: 12),
            Text('里程碑达成 🎉',
                style: TextStyle(
                    color: kText,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('已掌握 $milestone 块',
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('连续打卡 ${p.streak} 天',
                      style: TextStyle(
                          color: kTextSecondary, fontSize: 14)),
                  const SizedBox(height: 6),
                  Text('今日开口 ${p.todaySpoken} 句',
                      style: TextStyle(
                          color: kTextSecondary, fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: onSave,
                child: Text('保存战报卡',
                    style: TextStyle(
                        color: kOnPrimary,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('继续', style: TextStyle(color: kPrimary)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

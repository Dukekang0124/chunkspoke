import 'chunk_asset.dart';
import 'database.dart';
import 'state_machine.dart';

/// 每日复习上限：防到期堆积（超出部分保持到期，次日自然顺延）。
const int kDailyReviewCap = 20;

/// 今日复习队列：已按上限截断，并给出顺延数量供 UI 诚实展示。
class ReviewQueue {
  final List<ChunkRow> items;
  final int dueTotal;
  final int reviewedToday;
  final int cap;

  const ReviewQueue({
    required this.items,
    required this.dueTotal,
    required this.reviewedToday,
    this.cap = kDailyReviewCap,
  });

  int get deferred => dueTotal - items.length;
  int get remainingToday => (cap - reviewedToday).clamp(0, cap);
  bool get capped => remainingToday == 0 && dueTotal > 0;
}

/// Structured, per-chunk progress store. Wraps AppDatabase and applies the
/// state-machine + scheduler rules, including:
///   - L4 fail x2 -> back to L3 (M1 trigger)
///   - M7 mastered HARD threshold (旧关卡轴，供场景解锁):
///       mastered = (L2 passed on the FIRST drag attempt)
///                  AND (L4 open-speak STT hit-rate >= 80%
///                       OR no-Key offline self-eval "said correct")
///   - 1.5 词块资产制（新轴）:
///       learning → consolidating/consolidated → longTerm → mastered,
///       复习失败 → relearning（1 天档），重修通过回到原位。
/// 两条轴并行：level 管场景解锁/续练；asset 管复习引擎/词块库/度量。
class ChunkProgressStore {
  final AppDatabase db;
  /// 词块「当日新学」计数钩子（P0-一.1）：新掌握一个词块时回调。
  final void Function()? onNewMastery;
  /// 层级查表钩子（指令 N §四.1）：T0 核心块在复习播单中优先。
  final String Function(String key)? tierOf;
  final DateTime Function() _clock;

  ChunkProgressStore(this.db,
      {this.onNewMastery, DateTime Function()? clock, this.tierOf})
      : _clock = clock ?? DateTime.now;

  DateTime get now => _clock();

  Future<ChunkRow> get(String key) async {
    final row = await db.getChunk(key);
    if (row != null) return row;
    return ChunkRow(
      chunkKey: key,
      level: ChunkLevel.l1,
      dueDate: 0,
      failCount: 0,
      lastScore: 0,
      l2OneTry: -1,
      l4SelfEval: false,
    );
  }

  /// 断点续练：返回第一个「尚未掌握」的词块索引；全部掌握则返回 keys.length。
  /// 「下一个未完成块」= 首个未 mastered 的块（完成 2 块 → 返回 2，即第 3 块）。
  Future<int> nextUnmasteredIndex(List<String> keys) async {
    for (int i = 0; i < keys.length; i++) {
      final row = await get(keys[i]);
      if (!isMastered(row)) return i;
    }
    return keys.length;
  }

  /// Mastered requires L2 one-try AND (score >= 80 OR self-eval).
  static bool isMastered(ChunkRow r) =>
      isMasteredWith(r.l2OneTry, r.lastScore, r.l4SelfEval);

  static bool isMasteredWith(int l2OneTry, int lastScore, bool selfEval) =>
      l2OneTry == 1 && (lastScore >= 80 || selfEval);

  /// 六步管线掌握判定：旧硬门槛之外，新学路径还要求本次四星全绿。
  /// 复习路径不传 [enforceFourStars]，保持「复习通过即升档」语义。
  static bool isMasteredWithStars({
    required int l2OneTry,
    required int lastScore,
    required bool selfEval,
    required bool fourStarsGreen,
  }) =>
      isMasteredWith(l2OneTry, lastScore, selfEval) && fourStarsGreen;

  Future<void> applyEvent(String key, ChunkEvent event,
      {int accuracy = 0,
      bool selfEval = false,
      bool review = false,
      bool fourStarsGreen = false,
      bool enforceFourStars = false}) async {
    final p = await get(key);
    final at = _clock();
    final atMs = at.millisecondsSinceEpoch;
    final asset = p.assetSnapshot;

    // —— 学习阶段主动跳过/延期：进入巩固中，次日回访 ——
    // 已在复习周期内的块：保持资产状态与既有排期，不重置档位。
    if (event == ChunkEvent.scheduleReview) {
      final entering = asset.state == ChunkAssetState.learning;
      final snap = entering ? ChunkAssetMachine.deferLearning(asset) : asset;
      final due = entering
          ? at.add(const Duration(days: 1)).millisecondsSinceEpoch
          : (p.dueDate > 0
              ? p.dueDate
              : at.add(const Duration(days: 1)).millisecondsSinceEpoch);
      await _write(
        p,
        asset: snap,
        level: entering ? ChunkLevel.review : p.level,
        dueDate: due,
        firstLearnedAt: p.firstLearnedAt == 0 ? atMs : p.firstLearnedAt,
      );
      await db.insertSession(key, event.name, 0, ts: atMs);
      return;
    }

    // —— 复习会话内跳过：不降档，只把到期推到明天（诚实：没练，明天再来）——
    if (event == ChunkEvent.deferReview) {
      final due = asset.state.isReviewable
          ? at.add(const Duration(days: 1)).millisecondsSinceEpoch
          : p.dueDate;
      await _write(p, asset: asset, dueDate: due);
      await db.insertSession(key, event.name, p.lastScore,
          review: true, ts: atMs);
      return;
    }

    // —— 复习失败：降档进入需重修，间隔重置回 1 天 ——
    if (event == ChunkEvent.speakFail && review) {
      final snap = asset.state.isReviewable
          ? ChunkAssetMachine.reviewFail(asset)
          : asset;
      final due = snap.state == ChunkAssetState.relearning
          ? at.add(const Duration(days: 1)).millisecondsSinceEpoch
          : p.dueDate;
      // 旧关卡等级不因复习失败回退：场景解锁不倒退（红线：解锁只能指向真实状态，
      // 但也不允许因复习波动把已解锁场景重新锁死）。
      await _write(
        p,
        asset: snap,
        level: p.level,
        dueDate: due,
        failCount: p.failCount + 1,
        reviewCount: p.reviewCount + 1,
        correctStreak: 0,
        lastReviewAt: atMs,
      );
      await db.insertSession(key, event.name, p.lastScore,
          review: true, ts: atMs);
      return;
    }

    // —— 非复习态开口失败：保持旧逻辑（L4 重试计数），资产不动 ——
    if (event == ChunkEvent.speakFail) {
      final next = ChunkStateMachine.transition(p.level, event);
      await _write(
        p,
        asset: asset,
        level: next,
        failCount: p.failCount + 1,
      );
      await db.insertSession(key, event.name, p.lastScore, ts: atMs);
      return;
    }

    var next = ChunkStateMachine.transition(p.level, event);

    // L2 one-try tracking（§4.3 修复“拖错一次永不掌握”毒块）：
    // 任何关卡重练 L2 都重新计——拖对即补回“一次过”，拖错清零。
    var l2OneTry = p.l2OneTry;
    if (next == ChunkLevel.l2 && p.level != ChunkLevel.l2) {
      l2OneTry = -1;
    }
    if (event == ChunkEvent.dragCorrect) {
      l2OneTry = 1;
    } else if (event == ChunkEvent.dragWrong && p.level == ChunkLevel.l2) {
      l2OneTry = 0;
    }

    var lastScore = p.lastScore;
    if (event == ChunkEvent.accuracyPass || event == ChunkEvent.accuracyFail) {
      lastScore = accuracy;
    }

    if (event == ChunkEvent.speakSuccess) {
      final l4SelfEval = p.l4SelfEval || selfEval;
      final willMaster = enforceFourStars
          ? isMasteredWithStars(
              l2OneTry: l2OneTry,
              lastScore: accuracy,
              selfEval: l4SelfEval,
              fourStarsGreen: fourStarsGreen,
            )
          : isMasteredWith(l2OneTry, accuracy, l4SelfEval);
      final isReviewEvent = review && asset.state.isReviewable;
      var snap = asset;
      var dueDate = p.dueDate;
      var reviewCount = p.reviewCount;
      var correctStreak = p.correctStreak;
      var lastReviewAt = p.lastReviewAt;
      var firstLearnedAt = p.firstLearnedAt;

      if (isReviewEvent) {
        snap = ChunkAssetMachine.reviewPass(asset);
        dueDate = ChunkAssetMachine.nextDue(at, snap)?.millisecondsSinceEpoch ?? 0;
        reviewCount = p.reviewCount + 1;
        correctStreak = p.correctStreak + 1;
        lastReviewAt = atMs;
        // 旧关卡轴：达标或资产已到终点 → mastered；否则保持复习态。
        next = (willMaster || snap.state == ChunkAssetState.mastered)
            ? ChunkLevel.mastered
            : p.level;
      } else {
        // 学习完成（六步管线在波 2 接入四星；波 1 只有「非全绿」路径）。
        if (asset.state == ChunkAssetState.learning) {
          snap = ChunkAssetMachine.completeLearning(asset,
              fourStarsGreen: fourStarsGreen);
          dueDate =
              ChunkAssetMachine.nextDue(at, snap)?.millisecondsSinceEpoch ?? 0;
          if (firstLearnedAt == 0) firstLearnedAt = atMs;
        }
        // 若该块已在资产周期内（重练旧块），保留其状态与到期，不回退进度。
        next = willMaster ? ChunkLevel.mastered : ChunkLevel.review;
      }

      final newlyMastered = willMaster && p.level != ChunkLevel.mastered;
      await _write(
        p,
        asset: snap,
        level: next,
        dueDate: dueDate,
        // 展示用 lastScore：仅当本次有 STT 分才覆盖 L3 分。
        lastScore: accuracy > 0 ? accuracy : p.lastScore,
        l2OneTry: l2OneTry,
        l4SelfEval: l4SelfEval,
        firstLearnedAt: firstLearnedAt,
        reviewCount: reviewCount,
        correctStreak: correctStreak,
        lastReviewAt: lastReviewAt,
      );
      await db.insertSession(
          key, event.name, accuracy > 0 ? accuracy : p.lastScore,
          review: isReviewEvent, ts: atMs);
      if (newlyMastered) onNewMastery?.call();
      return;
    }

    await _write(
      p,
      asset: asset,
      level: next,
      lastScore: lastScore,
      l2OneTry: l2OneTry,
    );
    await db.insertSession(key, event.name, lastScore, ts: atMs);
  }

  /// 单点落库：资产快照与旧关卡轴字段一起写，避免两套状态分叉。
  Future<void> _write(
    ChunkRow p, {
    required ChunkAssetSnapshot asset,
    ChunkLevel? level,
    int? dueDate,
    int? failCount,
    int? lastScore,
    int? l2OneTry,
    bool? l4SelfEval,
    int? firstLearnedAt,
    int? reviewCount,
    int? correctStreak,
    int? lastReviewAt,
  }) async {
    await db.upsertChunk(ChunkRow(
      chunkKey: p.chunkKey,
      level: level ?? p.level,
      dueDate: dueDate ?? p.dueDate,
      failCount: failCount ?? p.failCount,
      lastScore: lastScore ?? p.lastScore,
      l2OneTry: l2OneTry ?? p.l2OneTry,
      l4SelfEval: l4SelfEval ?? p.l4SelfEval,
      reviewStage: asset.stage,
      assetState: asset.state,
      assetReturnState: asset.returnState,
      assetReturnStage: asset.returnStage,
      firstLearnedAt: firstLearnedAt ?? p.firstLearnedAt,
      reviewCount: reviewCount ?? p.reviewCount,
      correctStreak: correctStreak ?? p.correctStreak,
      lastReviewAt: lastReviewAt ?? p.lastReviewAt,
    ));
  }

  Future<List<String>> dueChunkKeys(int now, {int? limit}) async {
    final rows = await db.dueChunks(now, limit: limit);
    return rows.map((r) => r.chunkKey).toList();
  }

  /// 今日复习队列（含每日上限与顺延统计）。
  Future<ReviewQueue> reviewQueue(DateTime now,
      {int cap = kDailyReviewCap}) async {
    final nowMs = now.millisecondsSinceEpoch;
    final dayStart =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final reviewedToday = await db.countReviewedSince(dayStart);
    final remaining = (cap - reviewedToday).clamp(0, cap);
    final dueTotal = await db.countDueChunks(nowMs);
    final items = remaining == 0
        ? const <ChunkRow>[]
        : await _dueTierFirst(nowMs, remaining);
    return ReviewQueue(
        items: items,
        dueTotal: dueTotal,
        reviewedToday: reviewedToday,
        cap: cap);
  }

  /// 到期块排序：注入层级表时 T0 先行，组内保持 DB 原序（欠账多者先）。
  /// 上限在排序之后才截断，避免 T0 到期块被普通块挤出当日队列。
  Future<List<ChunkRow>> _dueTierFirst(int nowMs, int remaining) async {
    final lookup = tierOf;
    if (lookup == null) return db.dueChunks(nowMs, limit: remaining);
    final all = await db.dueChunks(nowMs);
    final core = <ChunkRow>[];
    final rest = <ChunkRow>[];
    for (final r in all) {
      (lookup(r.chunkKey) == 'T0' ? core : rest).add(r);
    }
    return [...core, ...rest].take(remaining).toList();
  }

  /// All chunk keys currently at the mastered level (scene-unlock / stats).
  Future<List<String>> allMasteredKeys() => db.allMasteredKeys();

  /// 资产轴已掌握 key（AI 变式造句等「已掌握」池按此为准）。
  Future<List<String>> allAssetMasteredKeys() async {
    final rows = await db.allChunks();
    return [
      for (final r in rows)
        if (r.assetState == ChunkAssetState.mastered) r.chunkKey,
    ];
  }

  /// 资产轴全量行（词块库 / 首页概览 / 导出共用）。
  Future<List<ChunkRow>> allRows() => db.allChunks();

  /// 资产轴分组计数（W2-1：所有「已掌握」计数以此为准）。
  Future<Map<ChunkAssetState, int>> assetStateCounts() =>
      db.assetStateCounts();

  /// 资产轴已掌握块数（走完 1/3/7/14 天复习）。
  Future<int> assetMasteredCount() => db.countAssetMastered();

  /// 会话事件计数（导出：六步漏斗与复习保持率）。
  Future<Map<String, int>> sessionOutcomeCounts({bool? review}) =>
      db.sessionOutcomeCounts(review: review);

  /// 最近一次未来的复习到期时间（epoch ms；无则 null）。
  Future<int?> nextDueTimestamp(int now) => db.nextDueTimestamp(now);

  /// 最早到期时间（含已到期；无则 null），供到期提醒排期。
  Future<int?> earliestDueTimestamp() => db.earliestDueTimestamp();

  /// 资产全量导出（词块库与度量供数；JSON 可编码）。
  Future<List<Map<String, Object?>>> exportAssets() async {
    final rows = await db.allChunks();
    return [
      for (final r in rows)
        {
          'chunk_key': r.chunkKey,
          'level': r.level.name,
          'asset_state': r.assetState.name,
          'asset_label': r.assetState.label,
          'stage': r.reviewStage,
          'return_state': r.assetReturnState?.name,
          'return_stage': r.assetReturnStage,
          'due_date': r.dueDate,
          'first_learned_at': r.firstLearnedAt,
          'review_count': r.reviewCount,
          'correct_streak': r.correctStreak,
          'last_review_at': r.lastReviewAt,
          'fail_count': r.failCount,
          'last_score': r.lastScore,
        },
    ];
  }

  // —— M7 AI 周报统计（聚合数字 + 词块 ID，不碰录音原文）——
  Future<int> spokenCount() => db.countSessionEvent('speakSuccess');
  Future<double> avgScore() => db.avgSessionScore();
  Future<List<ChunkRow>> topFail(int n) => db.topFailChunks(n);
}

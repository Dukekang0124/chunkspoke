import 'chunk_asset.dart';
import 'database.dart';
import 'learning_flow.dart';
import 'state_machine.dart';
import 'user_package.dart';

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
  /// ASR-205：块 → 所属关卡 id（用于把断点派生自该关台账）。
  final String? Function(String key)? levelOfChunk;
  /// ASR-205：关卡 id → 关卡块序列（内容包原序）。
  final List<String>? Function(String levelId)? chunkKeysOfLevel;
  final DateTime Function() _clock;

  ChunkProgressStore(this.db,
      {this.onNewMastery,
      DateTime Function()? clock,
      this.tierOf,
      this.levelOfChunk,
      this.chunkKeysOfLevel})
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

  /// ASR-205：断点快照的**唯一派生式**。
  ///
  /// 锚点 = 台账里首个未掌握块；整关已掌握 = 空串（清空）。
  /// 返回 null 表示当前 store 没有关卡索引（单测/旧调用），调用方回退旧行为。
  /// [overrideRow] 用于「本块刚算出新状态、尚未落库」时参与判定，避免读到旧行。
  Future<String?> deriveResume(String levelId, {ChunkRow? overrideRow}) async {
    final keys = chunkKeysOfLevel?.call(levelId);
    if (keys == null || keys.isEmpty) return null;
    var anchor = keys.length;
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      final row = (overrideRow != null && overrideRow.chunkKey == key)
          ? overrideRow
          : await db.getChunk(key);
      if (row == null || row.level != ChunkLevel.mastered) {
        anchor = i;
        break;
      }
    }
    if (anchor >= keys.length) return '';
    return LearnResume(
      chunkIndex: anchor,
      chunkId: keys[anchor],
      phase: 0,
      stars: StarBoard.empty,
      savedAt: _clock().millisecondsSinceEpoch,
    ).encode();
  }

  /// 把派生结果包成 kv 对；无关卡索引时返回 null（不写）。
  Future<Map<String, String>?> _derivedResumeKv(ChunkRow newRow) async {
    final levelId = levelOfChunk?.call(newRow.chunkKey);
    if (levelId == null || levelId.isEmpty) return null;
    final encoded = await deriveResume(levelId, overrideRow: newRow);
    if (encoded == null) return null;
    return {learnResumeKey(levelId): encoded};
  }

  /// ASR-206 §二：导入合并专用写入点——一次改多条台账时，锚点按**写后**的台账
  /// 重新派生，并与块行落在同一事务里（保证「写台账必同事务同步锚点」）。
  ///
  /// 无关卡索引（旧调用/单测）时退回逐条 upsert，行为与改动前一致。
  Future<void> applyImportedRows(List<ChunkRow> rows) async {
    if (rows.isEmpty) return;
    final keysOf = chunkKeysOfLevel;
    final levelOf = levelOfChunk;
    if (keysOf == null || levelOf == null) {
      for (final r in rows) {
        await db.upsertChunk(r);
      }
      return;
    }
    final incoming = {for (final r in rows) r.chunkKey: r};
    final touched = {
      for (final r in rows)
        if ((levelOf(r.chunkKey) ?? '').isNotEmpty) levelOf(r.chunkKey)!
    };
    final kv = <String, String>{};
    for (final levelId in touched) {
      final keys = keysOf(levelId) ?? const <String>[];
      if (keys.isEmpty) continue;
      var anchor = keys.length;
      for (var i = 0; i < keys.length; i++) {
        final row = incoming[keys[i]] ?? await db.getChunk(keys[i]);
        if (row == null || row.level != ChunkLevel.mastered) {
          anchor = i;
          break;
        }
      }
      kv[learnResumeKey(levelId)] = anchor >= keys.length
          ? ''
          : LearnResume(
              chunkIndex: anchor,
              chunkId: keys[anchor],
              phase: 0,
              stars: StarBoard.empty,
              savedAt: _clock().millisecondsSinceEpoch,
            ).encode();
    }
    await db.upsertChunksAndKv(rows, kv);
  }

  Future<void> applyEvent(String key, ChunkEvent event,
      {int accuracy = 0,
      bool selfEval = false,
      bool review = false,
      bool fourStarsGreen = false,
      bool enforceFourStars = false,
      Map<String, String>? alsoKv}) async {
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
        // ASR-205：跳过/延期也是一条「本块完成」路径，断点同事务跟随台账。
        deriveResume: true,
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
        // ASR-203 修复 2：只有「本块完成」这条分支需要与断点快照同事务落盘。
        // ASR-205：快照不再信任调用方算的「下一块」，而是由台账派生（单源）。
        alsoKv: alsoKv,
        deriveResume: true,
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
      // ASR-234：自定义包接入六步后，user 块也会走到这条「本块完成」分支。
      // 每日新学（地图今日卡）是**官方内容**掌握口径，user 块练得再多也不该混进去
      // （混了就是新的案三：官方今日新学被用户自己的词表灌水）。连击/开口数属参与度，
      // 由 practice_loop 的 bumpStreak/noteSpoken 照常累计，不在这条官方计数里。
      if (newlyMastered && !isUserChunkKey(key)) onNewMastery?.call();
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
    Map<String, String>? alsoKv,
    bool deriveResume = false,
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
    final row = ChunkRow(
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
    );
    // ASR-205：完成路径的断点由台账派生，并与块行写入同一事务。
    // 派生值优先于调用方传的 alsoKv（后者仅作为无关卡索引时的兼容回退）。
    final derived = deriveResume ? await _derivedResumeKv(row) : null;
    final kv = <String, String>{...?alsoKv, ...?derived};
    if (kv.isEmpty) {
      await db.upsertChunk(row);
    } else {
      await db.upsertChunkAndKv(row, kv);
    }
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

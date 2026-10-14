import 'database.dart';
import 'state_machine.dart';
import 'review_scheduler.dart';

/// Structured, per-chunk progress store. Wraps AppDatabase and applies the
/// state-machine + scheduler rules, including:
///   - L4 fail x2 -> back to L3 (M1 trigger)
///   - M7 mastered HARD threshold:
///       mastered = (L2 passed on the FIRST drag attempt)
///                  AND (L4 open-speak STT hit-rate >= 80%
///                       OR no-Key offline self-eval "said correct")
///     A chunk that hasn't met BOTH conditions is locked at its current stage
///     and is routed into the review queue (review level) to loop — no skip path.
class ChunkProgressStore {
  final AppDatabase db;
  ChunkProgressStore(this.db);

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

  /// Mastered requires L2 one-try AND (score >= 80 OR self-eval).
  static bool isMastered(ChunkRow r) =>
      isMasteredWith(r.l2OneTry, r.lastScore, r.l4SelfEval);

  static bool isMasteredWith(int l2OneTry, int lastScore, bool selfEval) =>
      l2OneTry == 1 && (lastScore >= 80 || selfEval);

  Future<void> applyEvent(String key, ChunkEvent event,
      {int accuracy = 0, bool selfEval = false}) async {
    final p = await get(key);
    ChunkLevel next = ChunkStateMachine.transition(p.level, event);

    // L4 fail counter: two fails demote back to L3 and reset the counter.
    int failCount = p.failCount;
    if (event == ChunkEvent.speakFail && p.level == ChunkLevel.l4) {
      failCount += 1;
      if (failCount >= 2) {
        next = ChunkLevel.l3;
        failCount = 0;
      }
    }

    // L2 one-try tracking.
    int l2OneTry = p.l2OneTry;
    if (next == ChunkLevel.l2 && p.level != ChunkLevel.l2) {
      l2OneTry = -1; // entering L2 fresh — reset the one-try flag
    }
    if (p.level == ChunkLevel.l2 && event == ChunkEvent.dragWrong) {
      l2OneTry = 0; // needed more than one try -> never counts as one-try
    }
    if (p.level == ChunkLevel.l2 &&
        event == ChunkEvent.dragCorrect &&
        l2OneTry != 0) {
      l2OneTry = 1;
    }

    int lastScore = p.lastScore;
    if (event == ChunkEvent.accuracyPass || event == ChunkEvent.accuracyFail) {
      lastScore = accuracy;
    }

    // L4 open-speak success: record STT hit-rate and apply the mastered gate.
    // 掌握门槛只看「本次 L4 开口」的命中率(accuracy)；不沿用 L3 照读分。
    // 离线无 Key 路径没有 STT 分，改用 selfEval 替代。
    if (event == ChunkEvent.speakSuccess) {
      final l4SelfEval = p.l4SelfEval || selfEval;
      if (isMasteredWith(l2OneTry, accuracy, l4SelfEval)) {
        next = ChunkLevel.mastered;
      } else {
        next = ChunkLevel.review; // loop — never skip
      }
      final enteringReview =
          next == ChunkLevel.review && p.level != ChunkLevel.review;
      await db.upsertChunk(p.copyWith(
        level: next,
        failCount: failCount,
        // 展示用 lastScore：仅当本次有 STT 分才覆盖 L3 分。
        lastScore: accuracy > 0 ? accuracy : p.lastScore,
        l2OneTry: l2OneTry,
        l4SelfEval: l4SelfEval,
        dueDate: enteringReview
            ? ReviewScheduler.nextDue(DateTime.now(), 0).millisecondsSinceEpoch
            : p.dueDate,
      ));
      await db.insertSession(key, event.name, accuracy > 0 ? accuracy : p.lastScore);
      return;
    }

    await db.upsertChunk(p.copyWith(
      level: next,
      failCount: failCount,
      lastScore: lastScore,
      l2OneTry: l2OneTry,
      l4SelfEval: p.l4SelfEval,
    ));
    await db.insertSession(key, event.name, lastScore);
  }

  Future<List<String>> dueChunkKeys(int now) async {
    final rows = await db.dueChunks(now);
    return rows.map((r) => r.chunkKey).toList();
  }

  /// All chunk keys currently at the mastered level (scene-unlock / stats).
  Future<List<String>> allMasteredKeys() => db.allMasteredKeys();
}

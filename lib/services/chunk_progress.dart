import 'database.dart';
import 'state_machine.dart';
import 'review_scheduler.dart';

// Structured, per-chunk progress store. Wraps AppDatabase and applies the
// state-machine + scheduler rules, including the counter-driven demotion
// "L4 fail x2 -> back to L3" (M1 spec trigger).
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
    );
  }

  Future<void> applyEvent(String key, ChunkEvent event, {int accuracy = 0}) async {
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

    int lastScore = p.lastScore;
    if (event == ChunkEvent.accuracyPass || event == ChunkEvent.accuracyFail) {
      lastScore = accuracy;
    }

    // Entering review queues the first spaced repetition (1 day).
    int dueDate = p.dueDate;
    if (next == ChunkLevel.review && p.level != ChunkLevel.review) {
      dueDate =
          ReviewScheduler.nextDue(DateTime.now(), 0).millisecondsSinceEpoch;
    }

    await db.upsertChunk(p.copyWith(
      level: next,
      failCount: failCount,
      lastScore: lastScore,
      dueDate: dueDate,
    ));
    await db.insertSession(key, event.name, lastScore);
  }

  Future<List<String>> dueChunkKeys(int now) async {
    final rows = await db.dueChunks(now);
    return rows.map((r) => r.chunkKey).toList();
  }
}

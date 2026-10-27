import '../storage/records.dart';
import 'content.dart';
import 'review_rules.dart';
import 'vocab.dart';

/// 与 App 同值的每日上限：复习 20（`kDailyReviewCap`）、新学 6（六步管线每日新块）。
const int kDailyReviewCap = 20;
const int kDailyNewCap = 6;

int dayStartMs(int nowMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(nowMs);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// 今日已复习块数：按复习事件计数（与 App `countReviewedSince` 同口径）。
int reviewedTodayCount(List<EventRecord> events, int nowMs) {
  final start = dayStartMs(nowMs);
  return events.where((e) => e.name == 'review_eval' && e.at >= start).length;
}

bool isDue(ChunkRecord r, int nowMs) =>
    r.dueDate > 0 && r.dueDate <= nowMs && r.assetState != AssetState.learning;

/// 学习完成（Web 只有「认识了」一种完成态）：巩固中 @0，次日回访。
/// 与 App `completeLearning(fourStarsGreen: false)` 同值。
ChunkRecord startLearning(ChunkRecord? existing, Chunk chunk, int nowMs) {
  final base = existing ??
      ChunkRecord(
        id: chunk.id,
        tier: chunk.tier,
        assetState: AssetState.learning,
      );
  return base.copyWith(
    tier: chunk.tier,
    assetState: AssetState.consolidating,
    reviewStage: 0,
    correctStreak: 0,
    dueDate: nowMs + kDayMs,
    lastReviewAt: nowMs,
    updatedAt: nowMs,
    orphan: false,
  );
}

/// 复习队列：到期块，T0 先行（App `_dueTierFirst`），再按到期先后；上限截断在排序之后。
List<ChunkRecord> dueQueue(
  Iterable<ChunkRecord> rows,
  ContentBundle content,
  int nowMs, {
  required int reviewedToday,
  int cap = kDailyReviewCap,
}) {
  final remaining = (cap - reviewedToday).clamp(0, cap);
  if (remaining == 0) return const [];
  final due = [
    for (final r in rows)
      if (isDue(r, nowMs)) r,
  ]..sort((a, b) {
      final at = a.dueDate.compareTo(b.dueDate);
      return at != 0 ? at : a.id.compareTo(b.id);
    });
  final core = <ChunkRecord>[];
  final rest = <ChunkRecord>[];
  for (final r in due) {
    final tier = content.byId[r.id]?.tier ?? r.tier;
    (tier == 'T0' ? core : rest).add(r);
  }
  return [...core, ...rest].take(remaining).toList();
}

/// 新学队列：按内容包关卡顺序取尚未学过（无记录或仍为新学）的块，每日 ≤6。
/// 与 App 首页 `newChunks` 的选块顺序一致（关卡序 → 块序）。
List<Chunk> newLearnQueue(
  ContentBundle content,
  Map<String, ChunkRecord> rows, {
  int cap = kDailyNewCap,
}) {
  final out = <Chunk>[];
  for (final c in content.chunks) {
    if (out.length >= cap) break;
    final r = rows[c.id];
    if (r == null || r.assetState == AssetState.learning) out.add(c);
  }
  return out;
}

/// 词块库展示用：本机记录与内容包合并后的行。
class LibraryRow {
  final Chunk chunk;
  final ChunkRecord? record;

  const LibraryRow(this.chunk, this.record);

  AssetState get state => record?.assetState ?? AssetState.learning;

  /// 掌握口径与 App `isMasteredWith` 对齐：资产到已掌握，或档位走完 1/3/7/14。
  bool get mastered =>
      state == AssetState.mastered || (record?.reviewStage ?? 0) >= kMasteredStage;

  int get dueDate => record?.dueDate ?? 0;
  int get streak => record?.correctStreak ?? 0;
  int get stage => record?.reviewStage ?? 0;
}

List<LibraryRow> libraryRows(ContentBundle content, Map<String, ChunkRecord> rows) => [
      for (final c in content.chunks)
        if (!(rows[c.id]?.orphan ?? false)) LibraryRow(c, rows[c.id]),
    ];

Map<String, int> libraryStateCounts(List<LibraryRow> rows) {
  final out = <String, int>{for (final s in AssetState.values) s.wire: 0};
  for (final r in rows) {
    out[r.state.wire] = (out[r.state.wire] ?? 0) + 1;
  }
  return out;
}

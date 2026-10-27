import '../storage/records.dart';
import '../storage/schema.dart';
import 'vocab.dart';

/// 复习间隔（天），与 App `ReviewScheduler.intervalsDays` 同值。
const List<int> kIntervalsDays = [1, 3, 7, 14];

/// 已掌握档位，与 App `masteredStage` 同值。
const int kMasteredStage = 4;

const int kDayMs = 24 * 60 * 60 * 1000;

int nextStage(int stage) => (stage + 1).clamp(0, kMasteredStage);

int intervalDaysForStage(int stage) =>
    kIntervalsDays[stage.clamp(0, kIntervalsDays.length - 1)];

/// 自评 1-3 → 调度迁移（方案 v1.1 §六-2）。
/// 只产生 App 已有的三种迁移：档位不变 / +1，**不引入档位回退**。
ChunkRecord applyReviewGrade(ChunkRecord r, ReviewGrade grade, int nowMs) {
  switch (grade) {
    case ReviewGrade.retry:
      return r.copyWith(
        reviewStage: r.reviewStage,
        correctStreak: 0,
        dueDate: nowMs + kDayMs,
        lastReviewAt: nowMs,
        updatedAt: nowMs,
      );
    case ReviewGrade.keep:
      return r.copyWith(
        dueDate: nowMs + kDayMs,
        lastReviewAt: nowMs,
        updatedAt: nowMs,
      );
    case ReviewGrade.pass:
      final stage = nextStage(r.reviewStage);
      return r.copyWith(
        reviewStage: stage,
        correctStreak: r.correctStreak + 1,
        dueDate: nowMs + intervalDaysForStage(stage) * kDayMs,
        lastReviewAt: nowMs,
        updatedAt: nowMs,
      );
  }
}

/// 复习事件（进协议的事件流）：grade 用归一命名，不携带 1/2/3 原始按键。
EventRecord reviewEvent({
  required String eventId,
  required String chunkId,
  required ReviewGrade grade,
  required int stageAfter,
  required int nowMs,
}) =>
    EventRecord(
      eventId: eventId,
      at: nowMs,
      name: 'review_eval',
      props: {'chunk_id': chunkId, 'grade': grade.wire, 'stage_after': stageAfter},
    );

EventRecord statsEvent({
  required String eventId,
  required String name,
  required int nowMs,
  Map<String, Object?> props = const {},
}) =>
    EventRecord(eventId: eventId, at: nowMs, name: name, props: props);

/// 事件环形缓冲：按 at 升序保留最新 [kEventBufferLimit] 条。
List<EventRecord> trimEvents(List<EventRecord> events) {
  final sorted = [...events]..sort((a, b) => a.at.compareTo(b.at));
  if (sorted.length <= kEventBufferLimit) return sorted;
  return sorted.sublist(sorted.length - kEventBufferLimit);
}

/// 词块是否处于「需重修」并带着返回位（协议往返必须保住这两列）。
bool hasReturnPosition(ChunkRecord r) =>
    r.assetState == AssetState.relearning &&
    r.assetReturnStateIndex >= 0 &&
    r.assetReturnStage >= 0;

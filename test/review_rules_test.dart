import 'package:chunkspoke_web/data/review_rules.dart';
import 'package:chunkspoke_web/data/vocab.dart';
import 'package:chunkspoke_web/storage/records.dart';
import 'package:flutter_test/flutter_test.dart';

const int _now = 1730000000000;

ChunkRecord _row({
  int stage = 0,
  int streak = 0,
  AssetState state = AssetState.consolidating,
  int returnIndex = -1,
  int returnStage = -1,
}) =>
    ChunkRecord(
      id: 'get up',
      tier: 'T0',
      assetState: state,
      reviewStage: stage,
      correctStreak: streak,
      assetReturnStateIndex: returnIndex,
      assetReturnStage: returnStage,
    );

void main() {
  test('3 通过：档位 +1、streak +1、间隔取新档', () {
    final out = applyReviewGrade(_row(stage: 0), ReviewGrade.pass, _now);
    expect(out.reviewStage, 1);
    expect(out.correctStreak, 1);
    expect(out.dueDate, _now + 3 * kDayMs);
    expect(out.lastReviewAt, _now);
    expect(out.updatedAt, _now);
  });

  test('3 通过：档位到 4 即已掌握，封顶且不再排期', () {
    final out = applyReviewGrade(_row(stage: 3, streak: 3), ReviewGrade.pass, _now);
    expect(out.reviewStage, kMasteredStage);
    expect(out.assetState, AssetState.mastered);
    expect(out.dueDate, 0); // 与 App `nextDue` 一致：已掌握不排期
    final capped = applyReviewGrade(out, ReviewGrade.pass, _now);
    expect(capped.reviewStage, kMasteredStage);
    expect(capped.correctStreak, 5);
    expect(capped.dueDate, 0);
  });

  test('1 重学：档位不变、streak 归零、+1 天', () {
    final out = applyReviewGrade(_row(stage: 2, streak: 4), ReviewGrade.retry, _now);
    expect(out.reviewStage, 2);
    expect(out.correctStreak, 0);
    expect(out.dueDate, _now + kDayMs);
  });

  test('2 保留：档位与 streak 都不动、+1 天', () {
    final out = applyReviewGrade(_row(stage: 2, streak: 4), ReviewGrade.keep, _now);
    expect(out.reviewStage, 2);
    expect(out.correctStreak, 4);
    expect(out.dueDate, _now + kDayMs);
  });

  test('不引入档位回退：三种自评都产不出更小的 review_stage', () {
    for (final grade in ReviewGrade.values) {
      final out = applyReviewGrade(_row(stage: 2), grade, _now);
      expect(out.reviewStage, greaterThanOrEqualTo(2), reason: grade.wire);
    }
  });

  test('需重修返回位不被自评改写', () {
    final out = applyReviewGrade(
      _row(
        stage: 1,
        state: AssetState.relearning,
        returnIndex: AssetState.consolidated.index,
        returnStage: 2,
      ),
      ReviewGrade.retry,
      _now,
    );
    expect(out.assetState, AssetState.relearning);
    expect(out.assetReturnStateIndex, AssetState.consolidated.index);
    expect(out.assetReturnStage, 2);
    expect(hasReturnPosition(out), isTrue);
  });

  test('复习事件 grade 用归一命名，档位写 stage_after', () {
    final e = reviewEvent(
      eventId: 'evt-1',
      chunkId: 'get up',
      grade: ReviewGrade.pass,
      stageAfter: 2,
      nowMs: _now,
    );
    expect(e.name, 'review_eval');
    expect(e.props['grade'], 'pass');
    expect(e.props['stage_after'], 2);
    expect(e.props.containsKey('grade_raw'), isFalse);
  });
}

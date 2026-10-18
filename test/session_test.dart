import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/session.dart';
import 'package:chunkspoke_flutter/services/review_scheduler.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';

// 测试用最小 Chunk
Chunk _c(String id) => Chunk(
    id: id,
    text: id,
    type: 'content',
    meaningCN: id,
    sentence: ChunkSentence(text: id, slots: [], coreWords: [], swapSlotIndex: 0, swapOptions: []));

void main() {
  group('Sm2Scheduler', () {
    test('成功推进，失败回退', () {
      expect(Sm2Scheduler.advanceStage(0, true), 1);
      expect(Sm2Scheduler.advanceStage(1, true), 2);
      expect(Sm2Scheduler.advanceStage(2, true), 3);
      expect(Sm2Scheduler.advanceStage(3, true), 3); // 封顶
      expect(Sm2Scheduler.advanceStage(2, false), 0); // 回退两级
      expect(Sm2Scheduler.advanceStage(0, false), 0); // 不下探
    });
    test('nextDue 复用 1/3/7/14 阶梯', () {
      final base = DateTime(2026, 1, 1);
      expect(Sm2Scheduler.nextDue(base, 0), ReviewScheduler.nextDue(base, 0));
    });
  });

  group('PracticeSession', () {
    final all = List.generate(12, (i) => _c('c$i'));
    test('有到期复习 → 先练到期，不插新学', () {
      final due = all.take(6).toList();
      final plan = PracticeSession.buildPlan(due, all);
      expect(plan.length, 6);
      expect(plan.first.id, 'c0'); // 到期优先
    });
    test('到期仅 1 个 → 只练该到期，不补新学', () {
      final due = all.take(1).toList();
      final plan = PracticeSession.buildPlan(due, all);
      expect(plan.length, 1);
      expect(plan.first.id, 'c0');
    });
    test('到期超限（>12）→ 最多取 12', () {
      final due = all.take(20).toList();
      final plan = PracticeSession.buildPlan(due, all);
      expect(plan.length, 12);
    });
    test('无到期复习 → 推新学且每日 ≤5', () {
      final plan = PracticeSession.buildPlan([], all);
      expect(plan.length, 5); // 每日新学 ≤5
      expect(plan.first.id, 'c0');
    });
    test('hasContent', () {
      expect(PracticeSession.hasContent(0), isFalse);
      expect(PracticeSession.hasContent(3), isTrue);
    });
  });

  group('Migration', () {
    test('无版本标记需重置', () {
      expect(Migration.needsReset(null), isTrue);
    });
    test('旧版本需重置', () {
      expect(Migration.needsReset('1.0.2'), isTrue);
    });
    test('当前版本不重置', () {
      expect(Migration.needsReset('1.1.0'), isFalse);
    });
    test('更高版本不重置', () {
      expect(Migration.needsReset('2.0.0'), isFalse);
    });
  });
}

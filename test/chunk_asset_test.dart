import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';

/// 词块资产状态机全状态 × 全转换矩阵。
/// 任何非法转换必须抛 StateError，不允许「静默兜底」。
///
/// 指令 N 规格修订（2026-10-22）：四星全绿 → 已巩固，但**首次复习到期 = +1 天**
/// （原「直接 +3 天」作废，依据 24h 首检索窗口 + 指令 K 四档原文）；
/// 之后复习通过 +3d → +7d → +14d → 已掌握；任一可复习态失败 → 需重修且重置回 +1 天。
void main() {
  const learning = ChunkAssetSnapshot(state: ChunkAssetState.learning);
  const consolidating =
      ChunkAssetSnapshot(state: ChunkAssetState.consolidating, stage: 0);
  // 已巩固两档：stage 0 = 首到期 1 天窗口；stage 1 = 3 天档。
  const consolidated1d =
      ChunkAssetSnapshot(state: ChunkAssetState.consolidated, stage: 0);
  const consolidated3d =
      ChunkAssetSnapshot(state: ChunkAssetState.consolidated, stage: 1);
  const longTerm2 = ChunkAssetSnapshot(state: ChunkAssetState.longTerm, stage: 2);
  const longTerm3 = ChunkAssetSnapshot(state: ChunkAssetState.longTerm, stage: 3);
  const mastered =
      ChunkAssetSnapshot(state: ChunkAssetState.mastered, stage: 4);
  const relearnFromConsolidated = ChunkAssetSnapshot(
      state: ChunkAssetState.relearning,
      stage: 0,
      returnState: ChunkAssetState.consolidated,
      returnStage: 1);

  group('学习完成 completeLearning', () {
    test('新学 + 四星全绿 → 已巩固首档（stage 0，次日到期）', () {
      expect(
          ChunkAssetMachine.completeLearning(learning, fourStarsGreen: true),
          consolidated1d);
    });
    test('新学 + 未全绿 → 巩固中（1 天档）', () {
      expect(
          ChunkAssetMachine.completeLearning(learning, fourStarsGreen: false),
          consolidating);
    });
    test('非新学态一律非法', () {
      for (final s in [
        consolidating,
        consolidated1d,
        consolidated3d,
        longTerm2,
        longTerm3,
        mastered,
        relearnFromConsolidated,
      ]) {
        expect(
            () => ChunkAssetMachine.completeLearning(s, fourStarsGreen: true),
            throwsStateError,
            reason: s.toString());
      }
    });
  });

  group('学习延期 deferLearning', () {
    test('新学 → 巩固中', () {
      expect(ChunkAssetMachine.deferLearning(learning), consolidating);
    });
    test('非新学态非法', () {
      for (final s in [
        consolidating,
        consolidated1d,
        longTerm2,
        mastered,
        relearnFromConsolidated,
      ]) {
        expect(() => ChunkAssetMachine.deferLearning(s), throwsStateError,
            reason: s.toString());
      }
    });
  });

  group('复习通过 reviewPass', () {
    test('巩固中 → 已巩固(3d) → 长期(7) → 长期(14) → 已掌握', () {
      expect(ChunkAssetMachine.reviewPass(consolidating), consolidated3d);
      expect(ChunkAssetMachine.reviewPass(consolidated3d), longTerm2);
      expect(ChunkAssetMachine.reviewPass(longTerm2), longTerm3);
      expect(ChunkAssetMachine.reviewPass(longTerm3), mastered);
    });
    test('已巩固首档（+1d）通过 → 升到 3 天档', () {
      expect(ChunkAssetMachine.reviewPass(consolidated1d), consolidated3d);
    });
    test('需重修通过 → 精确回到失败前原位', () {
      expect(ChunkAssetMachine.reviewPass(relearnFromConsolidated), consolidated3d);
      const backLong3 = ChunkAssetSnapshot(
          state: ChunkAssetState.relearning,
          returnState: ChunkAssetState.longTerm,
          returnStage: 3);
      expect(ChunkAssetMachine.reviewPass(backLong3), longTerm3);
      const backConsolidating = ChunkAssetSnapshot(
          state: ChunkAssetState.relearning,
          returnState: ChunkAssetState.consolidating,
          returnStage: 0);
      expect(ChunkAssetMachine.reviewPass(backConsolidating), consolidating);
      const backConsolidated1d = ChunkAssetSnapshot(
          state: ChunkAssetState.relearning,
          returnState: ChunkAssetState.consolidated,
          returnStage: 0);
      expect(ChunkAssetMachine.reviewPass(backConsolidated1d), consolidated1d);
    });
    test('档位与状态不匹配 → 非法', () {
      for (final s in [
        const ChunkAssetSnapshot(state: ChunkAssetState.consolidating, stage: 1),
        const ChunkAssetSnapshot(state: ChunkAssetState.consolidated, stage: 2),
        const ChunkAssetSnapshot(state: ChunkAssetState.consolidated, stage: 3),
        const ChunkAssetSnapshot(state: ChunkAssetState.longTerm, stage: 0),
        const ChunkAssetSnapshot(state: ChunkAssetState.longTerm, stage: 1),
        const ChunkAssetSnapshot(state: ChunkAssetState.longTerm, stage: 4),
      ]) {
        expect(() => ChunkAssetMachine.reviewPass(s), throwsStateError,
            reason: s.toString());
      }
    });
    test('新学/已掌握 → 非法', () {
      expect(() => ChunkAssetMachine.reviewPass(learning), throwsStateError);
      expect(() => ChunkAssetMachine.reviewPass(mastered), throwsStateError);
    });
    test('需重修缺回退点 → 非法', () {
      const broken =
          ChunkAssetSnapshot(state: ChunkAssetState.relearning, stage: 0);
      expect(() => ChunkAssetMachine.reviewPass(broken), throwsStateError);
      const brokenStage = ChunkAssetSnapshot(
          state: ChunkAssetState.relearning,
          returnState: ChunkAssetState.consolidated,
          returnStage: -1);
      expect(() => ChunkAssetMachine.reviewPass(brokenStage), throwsStateError);
    });
  });

  group('复习失败 reviewFail', () {
    test('任一可复习态 → 需重修，记录回退点、档位重置为 0', () {
      for (final s in [
        consolidating,
        consolidated1d,
        consolidated3d,
        longTerm2,
        longTerm3
      ]) {
        final r = ChunkAssetMachine.reviewFail(s);
        expect(r.state, ChunkAssetState.relearning);
        expect(r.stage, 0);
        expect(r.returnState, s.state);
        expect(r.returnStage, s.stage);
      }
    });
    test('需重修再失败 → 保持需重修且保留原回退点', () {
      final r = ChunkAssetMachine.reviewFail(relearnFromConsolidated);
      expect(r, relearnFromConsolidated);
    });
    test('新学/已掌握 → 非法', () {
      expect(() => ChunkAssetMachine.reviewFail(learning), throwsStateError);
      expect(() => ChunkAssetMachine.reviewFail(mastered), throwsStateError);
    });
    test('需重修缺回退点 → 非法', () {
      const broken =
          ChunkAssetSnapshot(state: ChunkAssetState.relearning, stage: 0);
      expect(() => ChunkAssetMachine.reviewFail(broken), throwsStateError);
    });
  });

  group('排期 nextDue（首到期 1/3/7/14）', () {
    final from = DateTime(2026, 1, 1, 9);
    int? days(DateTime? d) => d?.difference(from).inDays;
    test('各状态间隔', () {
      expect(ChunkAssetMachine.nextDue(from, learning), isNull);
      expect(days(ChunkAssetMachine.nextDue(from, consolidating)), 1);
      expect(days(ChunkAssetMachine.nextDue(from, consolidated1d)), 1);
      expect(days(ChunkAssetMachine.nextDue(from, consolidated3d)), 3);
      expect(days(ChunkAssetMachine.nextDue(from, longTerm2)), 7);
      expect(days(ChunkAssetMachine.nextDue(from, longTerm3)), 14);
      expect(days(ChunkAssetMachine.nextDue(from, relearnFromConsolidated)), 1);
      expect(ChunkAssetMachine.nextDue(from, mastered), isNull);
    });
    test('规格修订硬断言：四星全绿当天学完 → 首到期 = +1 天（不是 +3 天）', () {
      final afterLearn =
          ChunkAssetMachine.completeLearning(learning, fourStarsGreen: true);
      expect(days(ChunkAssetMachine.nextDue(from, afterLearn)), 1);
      expect(ChunkAssetMachine.nextDue(from, afterLearn),
          isNot(from.add(const Duration(days: 3))));
    });
    test('规格修订硬断言：任一可复习态失败 → 到期重置回 +1 天', () {
      for (final s in [
        consolidating,
        consolidated1d,
        consolidated3d,
        longTerm2,
        longTerm3
      ]) {
        final failed = ChunkAssetMachine.reviewFail(s);
        expect(days(ChunkAssetMachine.nextDue(from, failed)), 1,
            reason: '$s 失败后必须次日回访');
      }
    });
    test('全周期：四星全绿 → 1d → 3d → 7d → 14d → 已掌握（共 4 次复习）', () {
      var s = ChunkAssetMachine.completeLearning(learning, fourStarsGreen: true);
      final ladder = <int>[];
      for (var i = 0; i < 4; i++) {
        ladder.add(ChunkAssetMachine.nextDue(from, s)!.difference(from).inDays);
        s = ChunkAssetMachine.reviewPass(s);
      }
      expect(ladder, [1, 3, 7, 14]);
      expect(s, mastered);
      expect(ChunkAssetMachine.nextDue(from, s), isNull);
    });
  });

  group('快照校验 validate', () {
    test('合法快照全部通过', () {
      for (final s in [
        learning,
        consolidating,
        consolidated1d,
        consolidated3d,
        longTerm2,
        longTerm3,
        mastered,
        relearnFromConsolidated,
      ]) {
        expect(() => ChunkAssetMachine.validate(s), returnsNormally,
            reason: s.toString());
      }
    });
    test('非法快照全部拒绝', () {
      for (final s in [
        const ChunkAssetSnapshot(state: ChunkAssetState.learning, stage: 1),
        const ChunkAssetSnapshot(state: ChunkAssetState.consolidating, stage: 1),
        const ChunkAssetSnapshot(state: ChunkAssetState.consolidated, stage: 2),
        const ChunkAssetSnapshot(state: ChunkAssetState.longTerm, stage: 1),
        const ChunkAssetSnapshot(state: ChunkAssetState.mastered, stage: 3),
        const ChunkAssetSnapshot(state: ChunkAssetState.relearning, stage: 0),
      ]) {
        expect(() => ChunkAssetMachine.validate(s), throwsStateError,
            reason: s.toString());
      }
    });
  });

  test('快照值语义：相等与哈希', () {
    expect(consolidated3d,
        const ChunkAssetSnapshot(state: ChunkAssetState.consolidated, stage: 1));
    expect(
        const ChunkAssetSnapshot(
            state: ChunkAssetState.relearning,
            returnState: ChunkAssetState.longTerm,
            returnStage: 2),
        ChunkAssetMachine.reviewFail(longTerm2));
    expect(learning.hashCode, ChunkAssetSnapshot.initial.hashCode);
  });

  test('状态文案与是否可复习', () {
    expect(ChunkAssetState.learning.label, '新学');
    expect(ChunkAssetState.consolidating.label, '巩固中');
    expect(ChunkAssetState.consolidated.label, '已巩固');
    expect(ChunkAssetState.longTerm.label, '长期');
    expect(ChunkAssetState.mastered.label, '已掌握');
    expect(ChunkAssetState.relearning.label, '需重修');
    expect(ChunkAssetState.learning.isReviewable, isFalse);
    expect(ChunkAssetState.mastered.isReviewable, isFalse);
    for (final s in [
      ChunkAssetState.consolidating,
      ChunkAssetState.consolidated,
      ChunkAssetState.longTerm,
      ChunkAssetState.relearning,
    ]) {
      expect(s.isReviewable, isTrue, reason: s.name);
    }
  });
}

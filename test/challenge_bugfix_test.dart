import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/speech_judge.dart';
import 'package:chunkspoke_flutter/steps/practice_loop.dart';

/// B1/B2 回归：锁死误判命中、切句状态复用、12/12 完成推进。
void main() {
  group('B1 判定硬门槛（四分支）', () {
    const target = "I'm fine, thank you.";

    test('分支①：正确句 → 命中', () {
      final r = judgeSpeech(target: target, recognized: 'I\'m fine thank you');
      expect(r.pass, isTrue);
      expect(r.reason, 'ok');
      expect(r.layer, 'exact');
    });

    test('分支②：无关句 → 始终 miss（不能靠虚词容错混过）', () {
      final r = judgeSpeech(
          target: target, recognized: 'Good morning, everyone.');
      expect(r.pass, isFalse);
      expect(r.coreHitRate, 0.0);
      expect(r.reason, 'lowCore');
    });

    test('分支③：近似句低于相似度硬门槛 → miss；放宽门槛才放行', () {
      // 3 个虚词全丢：核心词全中、加权相似度仍 ≥0.8，但词级相似度只有 0.4。
      final strict = judgeSpeech(
          target: 'I am fine thank you', recognized: 'fine thank');
      expect(strict.pass, isFalse);
      expect(strict.reason, 'lowSim');
      expect(strict.coreHitRate, 1.0);
      expect(strict.weightedSimilarity, greaterThanOrEqualTo(0.8));
      expect(strict.similarity, lessThan(kMinSimilarity));

      final lenient = judgeSpeech(
          target: 'I am fine thank you',
          recognized: 'fine thank',
          minSimilarity: 0.3);
      expect(lenient.pass, isTrue);
    });

    test('分支④：切句必须换 State key，上一句判定不复用', () {
      // 上一句的识别结果拿去判当前句 → miss（文本层）。
      final stale = judgeSpeech(
          target: target, recognized: 'Good morning, everyone.');
      expect(stale.pass, isFalse);

      // UI 层：句 id 不同 → key 必须不同，Flutter 才会重建 State。
      expect(challengeStepKey('a_s01'), isNot(challengeStepKey('a_s03')));
      expect(challengeStepKey('a_s03'), challengeStepKey('a_s03'));
    });
  });

  group('B2 闯关推进（12/12）', () {
    test('第 1→11 句逐句前进，第 12 句返回完成信号 -1', () {
      expect(nextChallengeIndex(0, 12), 1);
      expect(nextChallengeIndex(10, 12), 11);
      expect(nextChallengeIndex(11, 12), -1);
    });
  });

  group('X-4 句挑战归属（单一语义）', () {
    bool decide({bool full = true, bool mastered = true, int i = 0}) =>
        challengeAfterChunks(
            fullLevel: full,
            mastered: mastered,
            chunkIndex: i,
            chunkTotal: 1,
            sentenceTotal: 1);

    test('主线完整关卡：最后一块掌握且有关卡句 → 进句挑战', () {
      expect(decide(), isTrue);
    });

    test('收听收词/复习（显式 chunks）→ 不进句挑战', () {
      expect(decide(full: false), isFalse);
    });

    test('未掌握 / 非最后一块 / 无关卡句 → 不进', () {
      expect(decide(mastered: false), isFalse);
      expect(
          challengeAfterChunks(
              fullLevel: true,
              mastered: true,
              chunkIndex: 0,
              chunkTotal: 2,
              sentenceTotal: 1),
          isFalse);
      expect(
          challengeAfterChunks(
              fullLevel: true,
              mastered: true,
              chunkIndex: 0,
              chunkTotal: 1,
              sentenceTotal: 0),
          isFalse);
    });
  });
}

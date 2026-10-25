import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/learning_flow.dart';

Chunk _plain(String id, String text, {String type = 'content'}) =>
    Chunk.fromJson({
      'id': id,
      'text': text,
      'semantic': type,
      'meaningCN': text,
    });

Chunk _withSwap() => Chunk(
      id: 'c1',
      text: 'Good morning',
      semantic: 'content',
      meaningCN: '早上好',
      sentence: ChunkSentence(
        text: 'Good morning everyone',
        slots: [
          Slot(text: 'Good morning', type: 'content'),
          Slot(text: 'everyone', type: 'function'),
        ],
        coreWords: const ['good', 'morning', 'everyone'],
        swapSlotIndex: 1,
        swapOptions: const ['team', 'class'],
      ),
    );

TargetSentence _sentence(String text, List<String> chunkIds) => TargetSentence(
    id: 's1', text: text, meaningCN: '大家早上好', chunkIds: chunkIds);

void main() {
  group('听辨星阈值', () {
    test('新学 3 轮：首猜命中 ≥2 轮才点亮', () {
      expect(listenStar(0, 3), 0);
      expect(listenStar(1, 3), 0);
      expect(listenStar(2, 3), 1);
      expect(listenStar(3, 3), 1);
    });
    test('复习 2 轮：命中 ≥1 轮点亮', () {
      expect(listenStar(0, 2), 0);
      expect(listenStar(1, 2), 1);
      expect(listenStar(2, 2), 1);
    });
    test('零轮不出星', () => expect(listenStar(0, 0), 0));
  });

  group('断点续学 LearnResume', () {
    test('编码/解码保真（含四星）', () {
      const r = LearnResume(
        chunkIndex: 2,
        chunkId: 'a03',
        phase: LearnPhase.substitute,
        stars: StarBoard(listen: true, speak: true),
        savedAt: 1729500000000,
      );
      final back = LearnResume.tryDecode(r.encode());
      expect(back, isNotNull);
      expect(back!.chunkIndex, 2);
      expect(back.chunkId, 'a03');
      expect(back.phase, LearnPhase.substitute);
      expect(back.stars, const StarBoard(listen: true, speak: true));
      expect(back.savedAt, 1729500000000);
    });
    test('非法/缺字段/越界一律拒绝', () {
      expect(LearnResume.tryDecode(null), isNull);
      expect(LearnResume.tryDecode(''), isNull);
      expect(LearnResume.tryDecode('   '), isNull);
      expect(LearnResume.tryDecode('not json'), isNull);
      expect(LearnResume.tryDecode('[]'), isNull);
      expect(
          LearnResume.tryDecode(
              '{"chunkIndex":-1,"chunkId":"a","phase":0,"stars":{}}'),
          isNull);
      expect(
          LearnResume.tryDecode(
              '{"chunkIndex":0,"chunkId":"","phase":0,"stars":{}}'),
          isNull);
      expect(
          LearnResume.tryDecode(
              '{"chunkIndex":0,"chunkId":"a","phase":6,"stars":{}}'),
          isNull);
    });
    test('缺 stars 时回落为未点亮', () {
      final back = LearnResume.tryDecode(
          '{"chunkIndex":0,"chunkId":"a","phase":3,"savedAt":1}');
      expect(back, isNotNull);
      expect(back!.stars, StarBoard.empty);
    });
  });

  group('定向替换方案', () {
    test('显式替换槽：槽位词换成同类搭档', () {
      final plan = buildSubstitutionPlan(
        chunk: _withSwap(),
        sentence: _sentence('Good morning everyone', const ['c1']),
        allChunks: const [],
      );
      expect(plan.isFallback, isFalse);
      expect(plan.chunkText, 'everyone');
      expect(plan.replacement, 'team');
      expect(plan.replacedSentence, 'Good morning team');
      expect(plan.skeletonWords, ['good', 'morning']);
      expect(plan.replacementOptions, ['team', 'class']);
    });

    test('显式方案换一个替代项：骨架不变、目标句重算', () {
      final plan = buildSubstitutionPlan(
        chunk: _withSwap(),
        sentence: _sentence('Good morning everyone', const ['c1']),
        allChunks: const [],
      );
      final next = plan.withReplacement('class');
      expect(next.replacement, 'class');
      expect(next.replacedSentence, 'Good morning class');
      expect(next.skeletonWords, plan.skeletonWords);
    });

    test('无显式槽：取同场景同类词块替换', () {
      final chunk = _plain('c1', 'Good morning');
      final alt = _plain('c2', 'Good evening');
      final plan = buildSubstitutionPlan(
        chunk: chunk,
        sentence: _sentence('Good morning everyone', const ['c1']),
        allChunks: [chunk, alt],
      );
      expect(plan.isFallback, isFalse);
      expect(plan.replacement, 'Good evening');
      expect(plan.replacedSentence, 'Good evening everyone');
      expect(plan.skeletonWords, ['everyone']);
    });

    test('无可替换搭档：不伪造新句，退化为原句复述', () {
      final chunk = _plain('c1', 'Good morning');
      final plan = buildSubstitutionPlan(
        chunk: chunk,
        sentence: _sentence('Good morning everyone', const ['c1']),
        allChunks: [chunk],
      );
      expect(plan.isFallback, isTrue);
      expect(plan.replacedSentence, 'Good morning everyone');
      expect(plan.slotWords, ['good', 'morning']);
    });
  });

  group('定替双校验阈值', () {
    const plan = SubstitutionPlan(
      baseSentence: 'a b c d e',
      chunkText: 'x',
      replacement: 'x',
      replacedSentence: 'a b x d e',
      skeletonWords: ['a', 'b', 'c', 'd', 'e'],
      slotWords: ['x'],
    );

    test('骨架恰好 0.8 且替换词命中 → 通过', () {
      final v = judgeSubstitution(recognized: 'a b c d x', plan: plan);
      expect(v.skeletonCoverage, closeTo(0.8, 1e-9));
      expect(v.slotCoverage, 1.0);
      expect(v.pass, isTrue);
      expect(v.reason, 'ok');
    });
    test('骨架 0.6 → 不通过（lowSkeleton）', () {
      final v = judgeSubstitution(recognized: 'a b c x', plan: plan);
      expect(v.skeletonCoverage, closeTo(0.6, 1e-9));
      expect(v.pass, isFalse);
      expect(v.reason, 'lowSkeleton');
    });
    test('空识别 / 只说一个词 → 友好拒绝', () {
      expect(judgeSubstitution(recognized: '', plan: plan).reason, 'empty');
      expect(judgeSubstitution(recognized: 'x', plan: plan).reason, 'tooShort');
    });

    const multi = SubstitutionPlan(
      baseSentence: 'i am very good',
      chunkText: 'very good',
      replacement: 'very good',
      replacedSentence: 'i am very good',
      skeletonWords: ['i', 'am'],
      slotWords: ['very', 'good'],
    );
    test('多词替换槽：命中 0.5 不通过，命中 1.0 通过', () {
      final half = judgeSubstitution(recognized: 'i am very', plan: multi);
      expect(half.slotCoverage, closeTo(0.5, 1e-9));
      expect(half.pass, isFalse);
      expect(half.reason, 'missingSlot');
      final full = judgeSubstitution(recognized: 'i am very good', plan: multi);
      expect(full.slotCoverage, 1.0);
      expect(full.pass, isTrue);
    });
  });

  group('自由造句宽松校验', () {
    test('用上词块且比词块多内容 → 通过', () {
      final v = judgeFreeUse(input: 'I said good morning', chunkText: 'good morning');
      expect(v.pass, isTrue);
      expect(v.chunkUsed, isTrue);
      expect(v.wordCount, 4);
      expect(v.reason, 'ok');
    });
    test('恰好 3 词且多 1 词 → 通过（边界）', () {
      final v = judgeFreeUse(input: 'good morning all', chunkText: 'good morning');
      expect(v.pass, isTrue);
    });
    test('原样复述词块 → tooShort', () {
      final v = judgeFreeUse(input: 'good morning', chunkText: 'good morning');
      expect(v.chunkUsed, isTrue);
      expect(v.pass, isFalse);
      expect(v.reason, 'tooShort');
    });
    test('没用上词块 → noChunk', () {
      final v = judgeFreeUse(input: 'hello there friend', chunkText: 'good morning');
      expect(v.chunkUsed, isFalse);
      expect(v.reason, 'noChunk');
    });
    test('空输入 → empty', () {
      expect(judgeFreeUse(input: '  ', chunkText: 'good morning').reason, 'empty');
    });
  });

  test('单块超时预算为 8 分钟', () {
    expect(kLearnChunkTimeout, const Duration(minutes: 8));
    expect(kLearnPhaseCount, 6);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/pronunciation_score.dart';

/// 1.5.9 发音评测三档口径（见 `验收-v1.5.9/发音评测-口径-1.5.9.md`）。
void main() {
  test('完全一致：全绿、100 分、通过', () {
    final r = scorePronunciation(
      target: 'good morning everyone',
      recognized: 'good morning everyone',
    );
    expect(r.words.every((w) => w.tier == PronTier.good), isTrue);
    expect(r.overall, 100);
    expect(r.passed, isTrue);
    expect(r.noSpeech, isFalse);
    expect(r.band, '清楚');
  });

  test('虚词漏说：标黄不判错，整句仍通过', () {
    final r = scorePronunciation(
      target: 'i want to go home',
      recognized: 'i want go home',
    );
    final to = r.words.firstWhere((w) => w.word == 'to');
    expect(to.tier, PronTier.near, reason: '虚词漏说落黄档，不判错');
    expect(r.words.firstWhere((w) => w.word == 'want').tier, PronTier.good);
    expect(r.passed, isTrue);
    // 5 词（实词 3×3 + 虚词 2×1）共 11 权重；丢一个虚词只扣 0.4 → 96。
    expect(r.overall, inInclusiveRange(90, 99));
  });

  test('实词说错：标红、不通过', () {
    final r = scorePronunciation(
      target: 'i like coffee',
      recognized: 'i like tea',
    );
    expect(r.words.firstWhere((w) => w.word == 'coffee').tier, PronTier.miss);
    expect(r.passed, isFalse);
    expect(r.missCount, 1);
    expect(r.overall, lessThan(70));
    expect(r.band, '再练一次');
  });

  test('近似音（编辑距离 1）：标黄不算错', () {
    final r = scorePronunciation(
      target: 'i like coffee',
      recognized: 'i like coffe',
    );
    expect(r.words.firstWhere((w) => w.word == 'coffee').tier, PronTier.near);
    expect(r.passed, isTrue);
  });

  test('缩读连读：i\'m → im 标黄，不判错', () {
    final r = scorePronunciation(
      target: "i'm fine",
      recognized: 'im fine',
    );
    expect(r.words.firstWhere((w) => w.word == "i'm").tier, PronTier.near);
    expect(r.passed, isTrue);
  });

  test('空转写：noSpeech 为真，整体 0 分', () {
    final r = scorePronunciation(target: 'good morning', recognized: '');
    expect(r.noSpeech, isTrue);
    expect(r.overall, 0);
    expect(r.passed, isFalse);
  });

  test('录音过短：noSpeech 为真', () {
    final r = scorePronunciation(
      target: 'good morning',
      recognized: 'good morning',
      durationSec: 0.2,
    );
    expect(r.noSpeech, isTrue);
    expect(r.passed, isFalse);
  });

  test('整词被拆成两词：并回后判绿，不误标红', () {
    // Vosk 小模型常把 everyone 识别成 every one。
    final r = scorePronunciation(
      target: 'good morning everyone',
      recognized: 'good morning every one',
    );
    expect(r.words.firstWhere((w) => w.word == 'everyone').tier, PronTier.good,
        reason: '重新切词后等于原词，应为绿档');
    expect(r.missCount, 0);
    expect(r.overall, 100);
    expect(r.passed, isTrue);
  });

  test('拆分但不在目标里：不并词，仍按原样判定', () {
    final r = scorePronunciation(
      target: 'good morning',
      recognized: 'good morning every one',
    );
    // 多出来的 every one 不属于目标词 → 不影响目标三档。
    expect(r.words.every((w) => w.tier == PronTier.good), isTrue);
  });
}

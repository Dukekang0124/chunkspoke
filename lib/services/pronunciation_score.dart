/// 发音评测打分（1.5.9）：把一次跟读的判定结果转成「逐词三档 + 整体分」。
///
/// 口径见 `验收-v1.5.9/发音评测-口径-1.5.9.md`：
///   - 三档：绿 = 原词命中；黄 = 近似命中（编辑距离≤1/词干/混淆对/缩读连读），
///     以及虚词漏说——**都不判错**（§30.4-4）；红 = 实词没说到或说错。
///   - 整体分 = Σ(词权重 × 档位分) / Σ词权重 × 100；实词权重 3、虚词 1；
///     档位分 绿 1.0 / 黄 0.6 / 红 0。
///   - 是否通过沿用 [judgeSpeech] 的三层漏斗（与六步④同一判定，不另立标准）。
/// 纯逻辑、不落库、不联网，可单测。
library;

import 'speech_judge.dart';

enum PronTier { good, near, miss }

class PronWord {
  final String word;
  final PronTier tier;
  const PronWord(this.word, this.tier);

  @override
  String toString() => '$word(${tier.name})';
}

class PronScoreResult {
  final JudgeOutcome judge;
  final List<PronWord> words;
  final int overall; // 0..100
  final String recognized;

  const PronScoreResult({
    required this.judge,
    required this.words,
    required this.overall,
    required this.recognized,
  });

  bool get passed => judge.pass;

  /// 没听到有效语音（空转写或录音过短）：UI 显示提示，不展示着色。
  bool get noSpeech => judge.reason == 'empty' || judge.reason == 'tooShort';

  int get goodCount => words.where((w) => w.tier == PronTier.good).length;
  int get nearCount => words.where((w) => w.tier == PronTier.near).length;
  int get missCount => words.where((w) => w.tier == PronTier.miss).length;

  /// 文案档：≥85「清楚」/ ≥70「能听懂」/ 其余「再练一次」。
  String get band => overall >= 85
      ? '清楚'
      : overall >= 70
          ? '能听懂'
          : '再练一次';
}

/// 小模型常见的「整词被拆」（everyone → every one、tonight → to night）。
/// 若相邻 2–3 个识别词的拼接恰好等于目标里的某个词，就并回一个词再判定；
/// 只做重新切词、不改词形，避免一次正确朗读被误标红色。
/// 仅作用于本层（展示与打分），`judgeSpeech` 的判定口径不另立标准。
String _rejoinSplitWords(String target, String recognized) {
  final tgt = tokenizeSpeech(target).toSet();
  final rec = tokenizeSpeech(recognized);
  if (rec.isEmpty || tgt.isEmpty) return recognized;
  final out = <String>[];
  var i = 0;
  while (i < rec.length) {
    var merged = false;
    for (var k = 3; k >= 2; k--) {
      if (i + k <= rec.length) {
        final join = rec.sublist(i, i + k).join();
        if (tgt.contains(join)) {
          out.add(join);
          i += k;
          merged = true;
          break;
        }
      }
    }
    if (!merged) {
      out.add(rec[i]);
      i++;
    }
  }
  return out.join(' ');
}

PronScoreResult scorePronunciation({
  required String target,
  required String recognized,
  double? confidence,
  double? durationSec,
}) {
  final j = judgeSpeech(
    target: target,
    recognized: _rejoinSplitWords(target, recognized),
    confidence: confidence,
    durationSec: durationSec,
  );

  final words = <PronWord>[];
  var weightSum = 0.0;
  var scoreSum = 0.0;
  for (var i = 0; i < j.targetWords.length; i++) {
    final w = j.targetWords[i];
    final matched = i < j.targetMatched.length && j.targetMatched[i];
    final exact = i < j.targetExact.length && j.targetExact[i];
    final PronTier tier;
    if (exact) {
      tier = PronTier.good;
    } else if (matched) {
      tier = PronTier.near; // 近似音/缩读：命中但不完全相同，不判错
    } else if (isFunctionWord(w)) {
      tier = PronTier.near; // 虚词漏说：不判错（与判定漏斗同口径）
    } else {
      tier = PronTier.miss;
    }
    words.add(PronWord(w, tier));
    final weight = isFunctionWord(w) ? 1.0 : 3.0;
    final s = tier == PronTier.good
        ? 1.0
        : tier == PronTier.near
            ? 0.6
            : 0.0;
    weightSum += weight;
    scoreSum += weight * s;
  }

  final overall = weightSum == 0 ? 0 : (scoreSum / weightSum * 100).round();
  return PronScoreResult(
    judge: j,
    words: words,
    overall: overall,
    recognized: j.recognizedWords.join(' '),
  );
}

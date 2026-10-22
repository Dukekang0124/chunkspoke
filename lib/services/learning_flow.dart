import 'dart:convert';

import '../models/content_pack.dart';
import 'speech_judge.dart';

/// 六步学习管线（指令 M · 模块 B）纯逻辑层：无 I/O，供 UI 与单测共用。
///
///   ⓪ 锚定 → ① 拆解 → ② 听辨（2~3 档语速）→ ③ 影子跟读
///   → ④ 定向替换 → ⑤ 自由造句 + 场景应用
///
/// 四星映射：③听辨 / ④跟读 / ⑤替换 / ⑥开口（与旧四星一致，不废弃）。
/// 复习复用后四步（②~⑤），不再走锚定与拆解。
class LearnPhase {
  static const int anchor = 0;
  static const int breakdown = 1;
  static const int listen = 2;
  static const int shadow = 3;
  static const int substitute = 4;
  static const int freeUse = 5;
}

const int kLearnPhaseCount = 6;

/// 单块超时预算：5~8 分钟内可完成；到 8 分钟存档并暂停，断点续学。
const Duration kLearnChunkTimeout = Duration(minutes: 8);

/// 听辨三档语速（flutter_tts 的 Android 实速约 ×2）。
const double kListenSlowRate = 0.14;
const double kListenNormalRate = 0.22;
const double kListenFastRate = 0.32;

List<double> listenRates({required bool reviewMode}) =>
    reviewMode ? const [kListenSlowRate, kListenNormalRate] : const [
      kListenSlowRate,
      kListenNormalRate,
      kListenFastRate,
    ];

List<int> phaseOrder({required bool reviewMode}) => reviewMode
    ? const [
        LearnPhase.listen,
        LearnPhase.shadow,
        LearnPhase.substitute,
        LearnPhase.freeUse,
      ]
    : const [
        LearnPhase.anchor,
        LearnPhase.breakdown,
        LearnPhase.listen,
        LearnPhase.shadow,
        LearnPhase.substitute,
        LearnPhase.freeUse,
      ];

/// 返回 -1 表示本块最后一步（结算）。
int nextPhase(int cur, {required bool reviewMode}) {
  final order = phaseOrder(reviewMode: reviewMode);
  final i = order.indexOf(cur);
  if (i < 0 || i >= order.length - 1) return -1;
  return order[i + 1];
}

String phaseLabel(int phase, {bool reviewMode = false}) {
  switch (phase) {
    case LearnPhase.anchor:
      return '锚定';
    case LearnPhase.breakdown:
      return '拆解';
    case LearnPhase.listen:
      return reviewMode ? '复习·听辨' : '听辨';
    case LearnPhase.shadow:
      return reviewMode ? '复习·跟读' : '影子跟读';
    case LearnPhase.substitute:
      return reviewMode ? '复习·替换' : '定向替换';
    default:
      return reviewMode ? '复习·开口' : '自由造句';
  }
}

/// 四星状态（本次会话内）。与词块资产轴分开：星星只记录本次真实达成。
class StarBoard {
  final bool listen;
  final bool speak;
  final bool substitute;
  final bool free;

  const StarBoard({
    this.listen = false,
    this.speak = false,
    this.substitute = false,
    this.free = false,
  });

  static const StarBoard empty = StarBoard();

  int get count =>
      (listen ? 1 : 0) +
      (speak ? 1 : 0) +
      (substitute ? 1 : 0) +
      (free ? 1 : 0);

  bool get allGreen => listen && speak && substitute && free;

  StarBoard copyWith({
    bool? listen,
    bool? speak,
    bool? substitute,
    bool? free,
  }) =>
      StarBoard(
        listen: listen ?? this.listen,
        speak: speak ?? this.speak,
        substitute: substitute ?? this.substitute,
        free: free ?? this.free,
      );

  Map<String, dynamic> toJson() => {
        'listen': listen,
        'speak': speak,
        'substitute': substitute,
        'free': free,
      };

  factory StarBoard.fromJson(Map<String, dynamic>? j) => StarBoard(
        listen: j?['listen'] == true,
        speak: j?['speak'] == true,
        substitute: j?['substitute'] == true,
        free: j?['free'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is StarBoard &&
      other.listen == listen &&
      other.speak == speak &&
      other.substitute == substitute &&
      other.free == free;

  @override
  int get hashCode => Object.hash(listen, speak, substitute, free);

  @override
  String toString() =>
      'StarBoard(listen=$listen, speak=$speak, substitute=$substitute, free=$free)';
}

/// 听辨星：3 轮需首猜命中 ≥2 轮；2 轮（复习）需 ≥1 轮。
int listenStar(int hits, int rounds) {
  if (rounds <= 0) return 0;
  return hits >= (rounds >= 3 ? 2 : 1) ? 1 : 0;
}

/// 断点续学快照：按场景存 kv；完成后清除。
class LearnResume {
  final int chunkIndex;
  final String chunkId;
  final int phase;
  final StarBoard stars;
  final int savedAt;

  const LearnResume({
    required this.chunkIndex,
    required this.chunkId,
    required this.phase,
    required this.stars,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'v': 1,
        'chunkIndex': chunkIndex,
        'chunkId': chunkId,
        'phase': phase,
        'stars': stars.toJson(),
        'savedAt': savedAt,
      };

  String encode() => jsonEncode(toJson());

  static LearnResume? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      final index = j['chunkIndex'];
      final id = j['chunkId'];
      final phase = j['phase'];
      if (index is! int || index < 0) return null;
      if (id is! String || id.isEmpty) return null;
      if (phase is! int || phase < 0 || phase >= kLearnPhaseCount) return null;
      return LearnResume(
        chunkIndex: index,
        chunkId: id,
        phase: phase,
        stars: StarBoard.fromJson(j['stars'] as Map<String, dynamic>?),
        savedAt: (j['savedAt'] as int?) ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 定向替换方案：在目标句中把当前词块（或词块单句里的可替换槽）
/// 换成一个同类替代，再开口说出新句。
class SubstitutionPlan {
  final String baseSentence; // 原目标句
  final String chunkText; // 当前词块
  final String replacement; // 替代词块/替换词
  final String replacedSentence; // 替换后的目标句
  final List<String> skeletonWords; // 去掉被替换部分后的骨架词
  final List<String> slotWords; // 替代部分的词
  final List<String> replacementOptions; // 可选的替换项（不含原词）
  final bool isFallback; // 没有可替换搭档：退化为「把词块说进句子」

  const SubstitutionPlan({
    required this.baseSentence,
    required this.chunkText,
    required this.replacement,
    required this.replacedSentence,
    required this.skeletonWords,
    required this.slotWords,
    this.replacementOptions = const [],
    this.isFallback = false,
  });

  String get hintCN => isFallback
      ? '用「$chunkText」说完整这句话'
      : '把「$chunkText」换成「$replacement」，再说一遍';

  /// 选择另一个替换项：骨架不变，替换词与目标句重算。
  SubstitutionPlan withReplacement(String next) {
    if (next == replacement || isFallback) return this;
    return SubstitutionPlan(
      baseSentence: baseSentence,
      chunkText: chunkText,
      replacement: next,
      replacedSentence: _replacePhrase(baseSentence, chunkText, next),
      skeletonWords: skeletonWords,
      slotWords: tokenizeSpeech(next),
      replacementOptions: replacementOptions,
    );
  }
}

/// 构造替换方案（纯函数）。
/// 优先使用内容包为该块标注的 swapSlotIndex / swapOptions；
/// 没有标注时，从同场景同类词块中找替代；仍找不到则退化为原句复述。
SubstitutionPlan buildSubstitutionPlan({
  required Chunk chunk,
  required TargetSentence sentence,
  required List<Chunk> allChunks,
}) {
  final base = sentence.text.trim().isEmpty ? chunk.text : sentence.text;

  // 1) 显式替换槽（新场景 schema）：替换 chunk.sentence 中的槽位短语。
  final sent = chunk.sentence;
  if (sent.swapSlotIndex >= 0 &&
      sent.swapSlotIndex < sent.slots.length &&
      sent.swapOptions.isNotEmpty) {
    final slotText = sent.slots[sent.swapSlotIndex].text;
    final replacement = sent.swapOptions.first;
    if (slotText.trim().isNotEmpty && _containsPhrase(sent.text, slotText)) {
      return SubstitutionPlan(
        baseSentence: sent.text,
        chunkText: slotText,
        replacement: replacement,
        replacedSentence: _replacePhrase(sent.text, slotText, replacement),
        skeletonWords: _removePhraseTokens(tokenizeSpeech(sent.text), slotText),
        slotWords: tokenizeSpeech(replacement),
        replacementOptions: sent.swapOptions.take(3).toList(),
      );
    }
  }

  // 2) 同场景同类词块替代（旧场景无 schema 标注时的兜底）。
  final alternatives = <Chunk>[];
  for (final c in allChunks) {
    if (c.id == chunk.id) continue;
    if (c.text.trim().isEmpty || c.text == chunk.text) continue;
    if (c.type == chunk.type) alternatives.add(c);
  }
  if (alternatives.isEmpty) {
    for (final c in allChunks) {
      if (c.id == chunk.id || c.text == chunk.text) continue;
      alternatives.add(c);
    }
  }

  if (alternatives.isNotEmpty && _containsPhrase(base, chunk.text)) {
    final alt = alternatives.first;
    final replaced = _replacePhrase(base, chunk.text, alt.text);
    return SubstitutionPlan(
      baseSentence: base,
      chunkText: chunk.text,
      replacement: alt.text,
      replacedSentence: replaced,
      skeletonWords: _removePhraseTokens(tokenizeSpeech(base), chunk.text),
      slotWords: tokenizeSpeech(alt.text),
      replacementOptions: alternatives.take(3).map((c) => c.text).toList(),
    );
  }

  // 3) 无可替换搭档：不伪造新句，直接复述原句。
  return SubstitutionPlan(
    baseSentence: base,
    chunkText: chunk.text,
    replacement: chunk.text,
    replacedSentence: base,
    skeletonWords: _removePhraseTokens(tokenizeSpeech(base), chunk.text),
    slotWords: tokenizeSpeech(chunk.text),
    isFallback: true,
  );
}

class SubstitutionVerdict {
  final bool pass;
  final double skeletonCoverage;
  final double slotCoverage;
  final String reason; // ok | empty | lowSkeleton | missingSlot | tooShort
  const SubstitutionVerdict({
    required this.pass,
    required this.skeletonCoverage,
    required this.slotCoverage,
    required this.reason,
  });
}

/// 定替双校验：骨架词有序覆盖率 ≥0.8，且替代词命中（单词要求全中，多词 ≥0.6）。
SubstitutionVerdict judgeSubstitution({
  required String recognized,
  required SubstitutionPlan plan,
}) {
  final rec = tokenizeSpeech(recognized);
  if (rec.isEmpty) {
    return const SubstitutionVerdict(
        pass: false, skeletonCoverage: 0, slotCoverage: 0, reason: 'empty');
  }
  if (rec.length < 2 && plan.slotWords.length + plan.skeletonWords.length > 1) {
    return const SubstitutionVerdict(
        pass: false, skeletonCoverage: 0, slotCoverage: 0, reason: 'tooShort');
  }
  final skel = _orderedCoverage(rec, plan.skeletonWords);
  final slot = _unorderedCoverage(rec, plan.slotWords);
  final slotNeed = plan.slotWords.length <= 1 ? 1.0 : 0.6;
  final pass = skel >= 0.8 && slot >= slotNeed;
  return SubstitutionVerdict(
    pass: pass,
    skeletonCoverage: skel,
    slotCoverage: slot,
    reason: pass ? 'ok' : (skel < 0.8 ? 'lowSkeleton' : 'missingSlot'),
  );
}

String substitutionHint(SubstitutionVerdict v, SubstitutionPlan plan) {
  switch (v.reason) {
    case 'empty':
      return '没有听清，靠近麦克风再说一遍';
    case 'tooShort':
      return '整句说出来，别只说一个词';
    case 'lowSkeleton':
      return '句子骨架还差一点，听一遍参考再试';
    case 'missingSlot':
      return plan.isFallback
          ? '句子里还没听到「${plan.chunkText}」'
          : '替换的「${plan.replacement}」还没听到';
    default:
      return '替换成功，句子说完整了';
  }
}

class FreeUseVerdict {
  final bool pass;
  final bool chunkUsed;
  final int wordCount;
  final String reason; // ok | empty | noChunk | tooShort
  const FreeUseVerdict({
    required this.pass,
    required this.chunkUsed,
    required this.wordCount,
    required this.reason,
  });
}

/// 自由造句宽松校验：必须用上目标词块，且至少 3 个词、比词块本身多出内容。
/// 宁松勿错杀——这里只验证「用上了」，不评判语法优劣；参考句随后给出。
FreeUseVerdict judgeFreeUse({
  required String input,
  required String chunkText,
}) {
  final tokens = tokenizeSpeech(input);
  if (tokens.isEmpty) {
    return const FreeUseVerdict(
        pass: false, chunkUsed: false, wordCount: 0, reason: 'empty');
  }
  final chunkWords = tokenizeSpeech(chunkText);
  final used = _orderedCoverage(tokens, chunkWords) >= 1.0;
  final extra = tokens.length - chunkWords.length;
  if (!used) {
    return FreeUseVerdict(
        pass: false, chunkUsed: false, wordCount: tokens.length, reason: 'noChunk');
  }
  if (tokens.length < 3 || extra < 1) {
    return FreeUseVerdict(
        pass: false, chunkUsed: true, wordCount: tokens.length, reason: 'tooShort');
  }
  return FreeUseVerdict(
      pass: true, chunkUsed: true, wordCount: tokens.length, reason: 'ok');
}

String freeUseHint(FreeUseVerdict v, String chunkText) {
  switch (v.reason) {
    case 'empty':
      return '用英文写一句，或点「说出来」';
    case 'noChunk':
      return '句子里用上今天的词块「$chunkText」';
    case 'tooShort':
      return '再补一点内容，让它成为完整的一句话';
    default:
      return '用上了！对照参考句听听地道说法';
  }
}

// —— 内部文本工具 ——

bool _containsPhrase(String text, String phrase) =>
    normalizeSpeech(text).contains(normalizeSpeech(phrase));

String _replacePhrase(String text, String from, String to) {
  final idx = text.toLowerCase().indexOf(from.toLowerCase());
  if (idx < 0) return text;
  return '${text.substring(0, idx)}$to${text.substring(idx + from.length)}';
}

List<String> _removePhraseTokens(List<String> tokens, String phrase) {
  final p = tokenizeSpeech(phrase);
  if (p.isEmpty) return tokens;
  final out = <String>[];
  var pi = 0;
  for (final t in tokens) {
    if (pi < p.length && wordClose(t, p[pi])) {
      pi++;
      continue;
    }
    out.add(t);
  }
  return pi == p.length ? out : tokens;
}

double _orderedCoverage(List<String> rec, List<String> target) {
  if (target.isEmpty) return 1.0;
  var ti = 0;
  for (final w in rec) {
    if (ti < target.length && wordClose(w, target[ti])) ti++;
  }
  return ti / target.length;
}

double _unorderedCoverage(List<String> rec, List<String> target) {
  if (target.isEmpty) return 1.0;
  var hit = 0;
  for (final t in target) {
    if (rec.any((w) => wordClose(w, t))) hit++;
  }
  return hit / target.length;
}

import 'speech_judge.dart';

/// B5 红线守门器：展示层永远用 ASR 原始文本；校验只决定「过/不过」，不改写原文。
/// 纯逻辑、可单测；不依赖 Vosk/原生插件。
///
/// 三态：
///   ✓ 目标命中且识别可信；
///   ✗ 听清了但没用上目标块；
///   ⚠ 识别不可信（空/过短/重复堆叠/低置信）→ 要求重说，禁止硬解码通过。
enum AsrGuardState { ok, empty, tooShort, repeated, chunkStack, lowConf }

/// 置信度门槛（指令 P 三-1）：平均词置信度低于 0.6 → 判「没听清」。
const double kAsrConfThreshold = 0.6;

/// 低置信词判定：单词 < 0.4 视为低置信。
const double kAsrLowWordConf = 0.4;

/// 低置信词占比超过 40% → 判「没听清」。
/// 均值会被少数高置信词拉高（中文自由解码实测均值 0.737 仍混入 0.225/0.336），
/// 必须叠加分布指标。
const double kAsrLowWordRatio = 0.4;

/// 最低两个词的均值低于 0.45 → 判「没听清」（防均值掩盖烂尾）。
const double kAsrTwoLowestThreshold = 0.45;

/// 同词重复达到 3 次 → 判垃圾堆叠。
const int kAsrRepeatLimit = 3;

/// 目标块词占全部词的比例超过 60%，且句中没有块外实词、块词数量还被重复堆高
/// （超出目标块自身词频）→ 判目标块堆叠。
/// 恰好把目标块说对（词频一致）不算堆叠。
const double kAsrChunkRatio = 0.6;

class AsrGuardResult {
  final AsrGuardState state;
  final String raw;
  final int wordCount;
  final double? confidence;
  final double? twoLowestAvg;
  final double lowConfRatio;
  final double chunkRatio;

  const AsrGuardResult({
    required this.state,
    required this.raw,
    required this.wordCount,
    required this.confidence,
    required this.twoLowestAvg,
    required this.lowConfRatio,
    required this.chunkRatio,
  });

  bool get ok => state == AsrGuardState.ok;
}

/// 守门：文本启发式在前（强制解码也会给出 1.0 置信度，不能只信置信度），
/// 置信度门槛在后。
///
/// [wordConfidences] 为空/null 表示没有置信度字段（如 Azure）→ 跳过置信度门槛，
/// 只用文本启发式；Vosk 已开启词级置信度，正常不会为空。
AsrGuardResult guardAsr({
  required String raw,
  required List<double>? wordConfidences,
  String targetBlock = '',
  int minWords = 2,
  bool checkChunkStack = false,
  double confThreshold = kAsrConfThreshold,
  double twoLowestThreshold = kAsrTwoLowestThreshold,
  double lowWordRatio = kAsrLowWordRatio,
}) {
  final tokens = tokenizeSpeech(raw);
  final blockTokens = tokenizeSpeech(targetBlock);
  final blockSet = blockTokens.toSet();
  final chunkRatio = tokens.isEmpty || blockSet.isEmpty
      ? 0.0
      : tokens.where(blockSet.contains).length / tokens.length;

  double? mean;
  double? twoLowest;
  var lowRatio = 0.0;
  if (wordConfidences != null && wordConfidences.isNotEmpty) {
    final confs = [...wordConfidences]..sort();
    mean = confs.reduce((a, b) => a + b) / confs.length;
    twoLowest = confs.length >= 2
        ? (confs[0] + confs[1]) / 2
        : confs[0];
    lowRatio = confs.where((c) => c < kAsrLowWordConf).length / confs.length;
  }

  AsrGuardState state;
  if (tokens.isEmpty) {
    state = AsrGuardState.empty;
  } else if (tokens.length < minWords) {
    state = AsrGuardState.tooShort;
  } else if (_hasRepeatedToken(tokens)) {
    state = AsrGuardState.repeated;
  } else if (checkChunkStack &&
      blockSet.isNotEmpty &&
      chunkRatio > kAsrChunkRatio &&
      !_hasContentOutside(tokens, blockSet) &&
      _stacksBlockWords(tokens, blockTokens)) {
    state = AsrGuardState.chunkStack;
  } else if (mean != null &&
      (mean < confThreshold ||
          lowRatio > lowWordRatio ||
          twoLowest! < twoLowestThreshold)) {
    state = AsrGuardState.lowConf;
  } else {
    state = AsrGuardState.ok;
  }

  return AsrGuardResult(
    state: state,
    raw: raw,
    wordCount: tokens.length,
    confidence: mean,
    twoLowestAvg: twoLowest,
    lowConfRatio: lowRatio,
    chunkRatio: chunkRatio,
  );
}

bool _hasRepeatedToken(List<String> tokens) {
  final counts = <String, int>{};
  for (final t in tokens) {
    final n = (counts[t] ?? 0) + 1;
    if (n >= kAsrRepeatLimit) return true;
    counts[t] = n;
  }
  return false;
}

bool _hasContentOutside(List<String> tokens, Set<String> blockSet) =>
    tokens.any((t) => !blockSet.contains(t) && !isFunctionWord(t));

/// 块词被堆叠：某个块词在识别文本里出现的次数超过它在目标块里的词频。
/// 例：目标块「I'll get a coffee」，中文误识为「coffee i'll get a coffee get」
/// → coffee/get 各出现 2 次 > 1 次，判堆叠；而恰好说对目标块（词频一致）放行。
bool _stacksBlockWords(List<String> tokens, List<String> blockTokens) {
  final blockCounts = <String, int>{};
  for (final t in blockTokens) {
    blockCounts[t] = (blockCounts[t] ?? 0) + 1;
  }
  final seen = <String, int>{};
  for (final t in tokens) {
    if (!blockCounts.containsKey(t)) continue;
    final n = (seen[t] ?? 0) + 1;
    if (n > blockCounts[t]!) return true;
    seen[t] = n;
  }
  return false;
}

/// 三态判定结果（展示与校验分立：原文由 UI 单独一行展示，这里只给结论文案）。
enum AsrVerdictKind { pass, notUsed, retry }

class AsrVerdict {
  final AsrVerdictKind kind;
  final String text;
  const AsrVerdict(this.kind, this.text);
}

/// [chunkStyle] = true：自由用块（⑥/⑤/沙盒），失败文案含目标块；
/// false：闭合跟读/照读（④/SAY），失败只说与目标不一致。
AsrVerdict asrVerdictFor({
  required AsrGuardResult guard,
  required bool targetHit,
  required String targetLabel,
  bool chunkStyle = true,
  String passText = '✓ 目标块用上了',
}) {
  if (!guard.ok) {
    return const AsrVerdict(AsrVerdictKind.retry, '⚠ 没听清，再说一遍');
  }
  if (targetHit) return AsrVerdict(AsrVerdictKind.pass, passText);
  final raw = guard.raw.trim();
  final text = chunkStyle
      ? '✗ 听到了「$raw」，但没用上「$targetLabel」'
      : '✗ 听到了「$raw」，和目标句还不一致';
  return AsrVerdict(AsrVerdictKind.notUsed, text);
}

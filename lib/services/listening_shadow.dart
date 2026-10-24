import 'asr_guard.dart';
import 'speech_judge.dart';

/// 句级轻跟读的判定核（指令 S §二.4）。
///
/// 复用六步④的同一套阈值（judgeSpeech 三层漏斗 + guardAsr 守门），
/// 但这里**只产结论**：不写词块资产、不写会话轴、不计「平均准确度」，
/// 浸泡层因此不产出学习资产（红线：句级跟读仅记 attempt 事件）。
class ShadowVerdict {
  final bool passed;
  final String recognized;
  final double similarity;
  final AsrVerdict verdict;

  const ShadowVerdict({
    required this.passed,
    required this.recognized,
    required this.similarity,
    required this.verdict,
  });
}

/// [wordConfidences] 为空/null 视作「无置信度字段」（如 Azure），
/// 守门只走文本启发式，与六步④口径一致。
ShadowVerdict judgeShadowRead({
  required String target,
  required String recognized,
  double? confidence,
  double? durationSec,
  List<double>? wordConfidences,
}) {
  final tokens = tokenizeSpeech(target);
  final guard = guardAsr(
    raw: recognized,
    wordConfidences: wordConfidences,
    targetBlock: target,
    minWords: tokens.length <= 1 ? 1 : 2,
  );
  final outcome = judgeSpeech(
    target: target,
    recognized: recognized,
    confidence: confidence,
    durationSec: durationSec,
  );
  final passed = guard.ok && outcome.pass;
  return ShadowVerdict(
    passed: passed,
    recognized: recognized,
    similarity: outcome.similarity,
    verdict: asrVerdictFor(
      guard: guard,
      targetHit: passed,
      targetLabel: target,
      chunkStyle: false,
      passText: '✓ 说到位了',
    ),
  );
}

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Azure 发音评测结果（三项分数）。
class PronunciationResult {
  final double accuracy;
  final double fluency;
  final double completeness;
  final bool passed;
  final String? error;
  PronunciationResult({
    required this.accuracy,
    required this.fluency,
    required this.completeness,
    required this.passed,
    this.error,
  });
}

/// SAY 反馈结果。
/// level: 'L1' = Azure 发音评测；'L2' = 本地识别(Text Match)；'L3' = 自确认。
class SayOutcome {
  final bool passed;
  final String level;
  final String? recognized;
  final int? textMatchScore;
  final PronunciationResult? azure;
  final bool wrong;
  final bool noSpeech;
  SayOutcome({
    required this.passed,
    required this.level,
    this.recognized,
    this.textMatchScore,
    this.azure,
    this.wrong = false,
    this.noSpeech = false,
  });
}

class TextMatchResult {
  final String recognized;
  final int score;
  final double hitRate;
  final bool passed;
  TextMatchResult({
    required this.recognized,
    required this.score,
    required this.hitRate,
    required this.passed,
  });
}

const Set<String> _stopwords = {
  'a', 'an', 'the', 'is', 'am', 'are', 'was', 'were', 'be', 'been',
  'being', 'to', 'of', 'in', 'on', 'at', 'for', 'and', 'or', 'but',
  'with', 'that', 'this', 'it', 'you', 'i', 'he', 'she', 'we', 'they',
  'my', 'your', 'his', 'her', 'our', 'their', 'me', 'us', 'them', 'as',
  'by', 'from', 'into', 'about', 'over', 'up', 'down', 'out', 'so',
  'not', 'no', 'yes', 'do', 'did', 'does', 'have', 'has', 'had',
  'will', 'would', 'can', 'could', 'should', 'may', 'might', 'must',
  'there',
};

String _normalize(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9' ]"), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Set<String> _coreWords(String sentence) => _normalize(sentence)
    .split(' ')
    .where((w) => w.isNotEmpty && !_stopwords.contains(w))
    .toSet();

int _levenshtein(String a, String b) {
  a = a.toLowerCase();
  b = b.toLowerCase();
  final m = a.length, n = b.length;
  if (m == 0) return n;
  if (n == 0) return m;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) dp[i][0] = i;
  for (var j = 0; j <= n; j++) dp[0][j] = j;
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      dp[i][j] = [
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + cost
      ].reduce((x, y) => x < y ? x : y);
    }
  }
  return dp[m][n];
}

/// 词级容错：完全相等 / 编辑距离≤1 / 词干近似（短词为长词前缀且长度差≤1）。
bool _wordClose(String target, String cand) {
  target = _normalize(target);
  cand = _normalize(cand);
  if (target.isEmpty || cand.isEmpty) return false;
  if (target == cand) return true;
  if (_levenshtein(target, cand) <= 1) return true;
  final shorter = target.length <= cand.length ? target : cand;
  final longer = target.length <= cand.length ? cand : target;
  return longer.startsWith(shorter) && (longer.length - shorter.length) <= 1;
}

/// L4 开口判定结果：命中 / 缺失的目标核心词（用于琥珀高亮）。
class ChunkHitResult {
  final bool allHit;
  final List<String> hit;
  final List<String> missed;
  ChunkHitResult({required this.allHit, required this.hit, required this.missed});
}

/// L4 开口命中：expected 核心词（含 variants 候选）在 recognized 中以任意词序出现即命中；
/// 逐词编辑距离≤1 / 词干容错。stopwords 不参与判定。
ChunkHitResult chunkHit(String expected, String recognized,
    {List<String> variants = const []}) {
  final targets = _coreWords(expected).toList();
  final rec =
      _normalize(recognized).split(' ').where((w) => w.isNotEmpty).toSet();
  final hit = <String>[];
  final missed = <String>[];
  for (final t in targets) {
    final candidates = [t, ...variants];
    final ok = candidates.any((c) => rec.any((rw) => _wordClose(c, rw)));
    if (ok) {
      hit.add(t);
    } else {
      missed.add(t);
    }
  }
  return ChunkHitResult(allHit: missed.isEmpty, hit: hit, missed: missed);
}

/// 语音服务：L1 Azure 发音评测（真实三项分数）；L2 speech_to_text 本地识别 + Text Match 计分；
/// L4 Azure STT 转写（供开口题型容错命中）。
class SpeechService {
  final stt.SpeechToText _stt = stt.SpeechToText();

  /// L2：本地识别结果计分（Text Match）。
  /// 核心词命中率 ≥60% 判通过；分数 = 60 + 40×命中率。
  TextMatchResult textMatch(String expected, String recognized) {
    final core = _coreWords(expected);
    if (core.isEmpty) {
      return TextMatchResult(recognized: recognized, score: 100, hitRate: 1.0, passed: true);
    }
    final rec = _normalize(recognized).split(' ').where((w) => w.isNotEmpty).toSet();
    final hit = core.where((w) => rec.contains(w)).length;
    final hitRate = hit / core.length;
    final score = (60 + 40 * hitRate).round();
    return TextMatchResult(recognized: recognized, score: score, hitRate: hitRate, passed: hitRate >= 0.6);
  }

  /// L2：真实初始化 speech_to_text（仅当真实失败才允许落 L3）。
  Future<bool> initLocal() async {
    try {
      return await _stt.initialize();
    } catch (_) {
      return false;
    }
  }

  void startLocal(void Function(String) onResult) {
    _stt.listen(
      onResult: (r) => onResult(r.recognizedWords),
      localeId: 'en_US',
      listenMode: stt.ListenMode.dictation,
    );
  }

  Future<void> stopLocal() async {
    try {
      await _stt.stop();
    } catch (_) {}
  }

  /// L1：Azure Pronunciation Assessment（REST）。
  /// 参考文本 = 目标句，返回 Accuracy / Fluency / Completeness 三项分数。
  Future<PronunciationResult> assessAzure(
    String audioPath,
    String reference,
    String key,
    String region,
  ) async {
    try {
      final url = Uri.parse(
        'https://$region.stt.speech.microsoft.com/speech/recognition/assessment/p3.1?language=en-US&format=detailed',
      );
      final bytes = await File(audioPath).readAsBytes();
      final paHeader = jsonEncode({
        'ReferenceText': reference,
        'GradingSystem': 'HundredMark',
        'Granularity': 'Phoneme',
        'Dimension': 'Comprehensive',
      });
      final resp = await http
          .post(
            url,
            headers: {
              'Ocp-Apim-Subscription-Key': key,
              'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=16000',
              'Pronunciation-Assessment': paHeader,
              'Accept': 'application/json',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final nb = (data['NBest'] as List?)?.cast<Map<String, dynamic>>();
        final pa = nb != null && nb.isNotEmpty
            ? nb[0]['PronunciationAssessment'] as Map<String, dynamic>?
            : null;
        final acc = (pa?['AccuracyScore'] ?? 0).toDouble();
        final flu = (pa?['FluencyScore'] ?? 0).toDouble();
        final comp = (pa?['CompletenessScore'] ?? 0).toDouble();
        return PronunciationResult(
            accuracy: acc, fluency: flu, completeness: comp, passed: acc >= 60);
      }
      return PronunciationResult(
          accuracy: 0, fluency: 0, completeness: 0, passed: false, error: 'HTTP ${resp.statusCode}');
    } catch (e) {
      return PronunciationResult(
          accuracy: 0, fluency: 0, completeness: 0, passed: false, error: '$e');
    }
  }

  /// L4：Azure STT 转写（REST）。返回识别文本；失败/离线返回空串（交上层降级）。
  Future<String> transcribeAzure(String audioPath, String key, String region) async {
    try {
      final url = Uri.parse(
        'https://$region.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=en-US&format=detailed',
      );
      final bytes = await File(audioPath).readAsBytes();
      final resp = await http
          .post(
            url,
            headers: {
              'Ocp-Apim-Subscription-Key': key,
              'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=16000',
              'Accept': 'application/json',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return (data['DisplayText'] as String?) ?? '';
      }
      return '';
    } catch (_) {
      return '';
    }
  }
}

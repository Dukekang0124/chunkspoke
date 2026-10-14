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

/// 语音服务：L1 Azure 发音评测（真实三项分数）；L2 speech_to_text 本地识别 + Text Match 计分。
class SpeechService {
  final stt.SpeechToText _stt = stt.SpeechToText();

  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9' ]"), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Set<String> _coreWords(String sentence) => _normalize(sentence)
      .split(' ')
      .where((w) => w.isNotEmpty && !_stopwords.contains(w))
      .toSet();

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
}

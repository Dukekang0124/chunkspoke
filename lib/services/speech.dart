import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'vosk_engine.dart';

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
  final List<bool>? targetMatched; // 目标句逐词命中标记（用于错词标红）
  SayOutcome({
    required this.passed,
    required this.level,
    this.recognized,
    this.textMatchScore,
    this.azure,
    this.wrong = false,
    this.noSpeech = false,
    this.targetMatched,
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

/// 口语判定已迁移到 `speech_judge.dart` 的 [judgeSpeech]（P0-1 收紧：规范化 +
/// 词级序列比对 + 置信度门槛 + 空/静音拒绝），L4 开口与 SAY 照读共用。

/// 语音服务（识别优先级）：Vosk 离线（默认必通，随包内置）＞ Azure STT（用户配 Key 才启用的高精度增强）。
/// 已移除系统 SpeechRecognizer（speech_to_text）路径——无 GMS 国行机上是空壳，永不产出。
/// 保留：L1 Azure 发音评测（REST）、Azure STT 转写（增强）、文本匹配/开口命中计分。
class SpeechService {
  /// 仅 E2E 入口 main_e2e.dart 设置（脚本化识别）；生产入口保持 null，走真实 Vosk。
  static Transcriber? debugTranscriberOverride;

  final Transcriber _transcriber;

  SpeechService({Transcriber? transcriber})
      : _transcriber =
            transcriber ?? debugTranscriberOverride ?? SpeechEngine.instance;

  /// 加载 Vosk 离线识别引擎（默认必通）。成功/失败据此决定降级或报错。
  Future<bool> initVosk() => _transcriber.init();

  bool get voskReady => _transcriber.isReady;
  bool get voskFailed => _transcriber.failed;

  /// 用 Vosk 转写本地录音（16k 单声道 WAV）；phrases 限定识别范围，提升命中/评分精度。
  /// 返回文本 + 置信度（置信度可能为 null=字段缺失，判定层据此走文本相似度兜底）。
  Future<VoskResult> recognize(String wavPath, List<String> phrases) =>
      _transcriber.transcribe(wavPath, phrases);

  /// 录音时长（秒），供判定管线的「过短录音无效」防噪兜底。
  Future<double> durationSec(String wavPath) => wavDurationSec(wavPath);

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

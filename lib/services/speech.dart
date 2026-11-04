import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'audio_format.dart';
import 'speech_judge.dart'
    show wordClose, tokenizeSpeech, isFunctionWord;
import 'vosk_engine.dart';
import 'zipformer_asr.dart';

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
  final bool asrUnclear; // B5：识别不可信（空/低置信/垃圾堆叠），需重说
  final List<bool>? targetMatched; // 目标句逐词命中标记（用于错词标红）
  /// §30.3-5：这条结果来自「用户手改/打字」的文本，不是语音识别原文。
  /// 用于结果卡如实标注「按文本通过（未验证发音）」，不许伪装成语音命中。
  final bool edited;
  SayOutcome({
    required this.passed,
    required this.level,
    this.recognized,
    this.textMatchScore,
    this.azure,
    this.wrong = false,
    this.noSpeech = false,
    this.asrUnclear = false,
    this.targetMatched,
    this.edited = false,
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

/// M1（2026-11-03）：一次识别的来源。UI 必须如实标注，禁止静默换引擎。
enum AsrSource { vosk, enhanced, azure }

/// M1：降级重识结果（增强 zipformer / 云端 Azure）。[wordConfidences] 仅 Vosk 有，
/// 增强与云端都为 null（判定层按文本相似度走，见 speech_judge 既有口径）。
class AsrRetryResult {
  final String text;
  final List<String> alternatives;
  final List<double>? wordConfidences;
  final double? confidence;
  final AsrSource source;
  AsrRetryResult({
    required this.text,
    required this.source,
    this.alternatives = const [],
    this.wordConfidences,
    this.confidence,
  });
}

/// M1：识别文本是否「明显不对」——空 / 词数不足目标 60% / 关键词全缺。
/// 纯逻辑，供降级链路与单测共用；[keywords] 为空时自动取目标句内容词。
bool openTranscriptPoor({
  required String text,
  required String target,
  List<String> keywords = const [],
}) {
  final words = _normalize(text).split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return true;
  final targetWords =
      _normalize(target).split(' ').where((w) => w.isNotEmpty).toList();
  if (targetWords.isNotEmpty && words.length < targetWords.length * 0.6) {
    return true;
  }
  final kws = keywords.isNotEmpty
      ? keywords
      : targetWords.where((w) => !_stopwords.contains(w)).toList();
  if (kws.isEmpty) return false;
  return !kws.any((k) => words.any((w) => wordClose(w, k)));
}

/// 目标文本的内容词（去掉虚词），作为降级重识的「关键词」。
List<String> asrKeywords(String text) =>
    tokenizeSpeech(text).where((w) => !isFunctionWord(w)).toList(growable: false);

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

  /// M1：最近一次 [recognizeOpen] 实际用的后端（给降级链路判重，避免同一后端跑两遍）。
  AsrSource _lastOpenSource = AsrSource.vosk;
  AsrSource get lastOpenSource => _lastOpenSource;

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

  /// B5：开放输出统一走全模型（不传场景词表），展示层只认这个原始文本。
  /// [e2ePhrases] 有两个用途：① debugTranscriberOverride 脚本化识别；
  /// ② ASR-209 B 层：增强 zipformer 的**目标热词偏置**（生产路径里传进来的
  /// 就是当前目标句/词块；实测带热词后 20M 空结果 10/40 → 0/40，WER 0.43 → 0.19）。
  Future<VoskResult> recognizeOpen(String wavPath,
      {List<String>? e2ePhrases}) async {
    final override = debugTranscriberOverride;
    if (override != null && identical(_transcriber, override)) {
      _lastOpenSource = AsrSource.vosk;
      return override.transcribe(wavPath, e2ePhrases ?? const []);
    }
    // ASR-191 模式 B：用户显式开启增强引擎后，开放式识别优先用它；
    // 未开启/未就绪/任何异常返回 null → 立刻继续用默认 Vosk（不改变默认路径）。
    final hotwords = asrHotwordsFrom((e2ePhrases ?? const []).join(' '));
    final enhanced = await EnhancedAsrService.instance
        .transcribeOpen(wavPath, hotwords: hotwords);
    if (enhanced != null) {
      _lastOpenSource = AsrSource.enhanced;
      return enhanced;
    }
    _lastOpenSource = AsrSource.vosk;
    return _transcriber.transcribeOpen(wavPath);
  }

  /// M1（2026-11-03）：识别明显不对时的**本地优先降级重识**。
  ///
  /// 顺序固定：增强 zipformer（需用户已下载并开启）→ 云端 Azure（用户自备 Key）。
  /// 哪一步的结果不再「明显不对」就立刻返回；都不可用/都为空返回 null，
  /// 调用方保留原结果（绝不静默换引擎，来源由 [AsrRetryResult.source] 交给 UI 标注）。
  ///
  /// [skipEnhanced]：一过已经是增强识别时置 true，避免同一后端白跑一遍。
  Future<AsrRetryResult?> retryOpenWithFallback({
    required String wavPath,
    required String target,
    List<String> keywords = const [],
    bool skipEnhanced = false,
    String? azureKey,
    String? azureRegion,
  }) async {
    AsrRetryResult? best;
    if (!skipEnhanced) {
      try {
        final e = await EnhancedAsrService.instance.transcribeOpen(wavPath,
            hotwords: asrHotwordsFrom(target));
        if (e != null && e.text.trim().isNotEmpty) {
          final cand = AsrRetryResult(
            text: e.text.trim(),
            source: AsrSource.enhanced,
            alternatives: e.alternatives,
            wordConfidences: e.wordConfidences,
            confidence: e.confidence,
          );
          if (!openTranscriptPoor(
              text: cand.text, target: target, keywords: keywords)) {
            return cand;
          }
          best = cand;
        }
      } catch (e) {
        debugPrint('[M1] 增强重识失败，继续尝试云端：$e');
      }
    }
    final key = azureKey?.trim() ?? '';
    final region = azureRegion?.trim() ?? '';
    if (key.isNotEmpty && region.isNotEmpty) {
      final t = await transcribeAzure(wavPath, key, region);
      if (t.trim().isNotEmpty) {
        final cand =
            AsrRetryResult(text: t.trim(), source: AsrSource.azure);
        if (best == null ||
            !openTranscriptPoor(
                text: cand.text, target: target, keywords: keywords)) {
          return cand;
        }
      }
    }
    return best;
  }

  /// ASR-188 缓解版：**二过受限解码救回**（只在自由解码判不过之后追加一次）。
  ///
  /// 现状：所有生产跟读走 [recognizeOpen] = 无约束全模型，所以
  /// "I'll order the same" 会被自由解码拼成 "an old do the same" 这类同音漂移。
  /// 本方法用**目标句词表**跑一次 Vosk grammar（受限解码），词表由
  /// [voskGrammarWords] 从整句展开（保留缩写里的 `'`，如 `i'll`）。
  ///
  /// 三条硬约束：
  /// 1. **不替换一过**——一过的自由文本仍是展示口径（B5 展示与校验分立不破）；
  ///    只有二过同时通过 `guardAsr` + 判定层，调用方才允许改判「过」。
  /// 2. **不新增依赖**——grammar 通道早已存在
  ///    （`transcribe(phrases)` → `createRecognizer(grammar:)`），零结果时引擎内部
  ///    已回退自由解码（`vosk_engine.dart` 159–162），词表含 OOV 词也不会卡死。
  /// 3. **不放松守门**——强制解码会把噪声拼成目标句且置信度虚高，
  ///    所以调用方对二过必须额外开 `checkChunkStack: true`。
  ///
  /// 返回 null = 没有可用的二过结果（词表空 / 引擎未就绪 / 与一过文本相同），
  /// 调用方保持一过结论即可。
  Future<VoskResult?> recognizeWithTargetGrammarRetry({
    required String wavPath,
    required String targetSentence,
    required String firstText,
  }) async {
    if (voskGrammarWords([targetSentence]).isEmpty) return null;
    if (!_transcriber.isReady) return null;
    final r = await _transcriber.transcribe(wavPath, [targetSentence]);
    final text = r.text.trim();
    if (text.isEmpty || text == firstText.trim()) return null;
    return r;
  }

  /// 录音时长（秒），供判定管线的「过短录音无效」防噪兜底。
  Future<double> durationSec(String wavPath) => wavDurationSec(wavPath);

  /// L2：本地识别结果计分（Text Match）。
  /// 核心词命中率 ≥60% 判通过；分数 = 60 + 40×命中率。
  ///
  /// M2（2026-11-03）：命中从「纯字符串包含」升级为**词级近似**——
  /// 精确未中时用 [wordClose]（编辑距离 ≤1 / 短虚词放宽 / 词干 / 混淆对），
  /// 与 L4 开口同一套容错。沙盒不再因 `size↔sides`、`large↔lunch` 这类
  /// Vosk 同音近形误识直接判死；命中率口径与阈值不变，评分不注水。
  TextMatchResult textMatch(String expected, String recognized) {
    final core = _coreWords(expected);
    if (core.isEmpty) {
      return TextMatchResult(recognized: recognized, score: 100, hitRate: 1.0, passed: true);
    }
    final recTokens = _normalize(recognized)
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    final recSet = recTokens.toSet();
    final used = <int>{};
    var hit = 0;
    for (final w in core) {
      if (recSet.contains(w)) {
        hit++;
        continue;
      }
      // 一个识别词只抵一个目标词，防止同一 token 反复近配抬高命中率。
      for (var i = 0; i < recTokens.length; i++) {
        if (used.contains(i)) continue;
        if (wordClose(w, recTokens[i])) {
          used.add(i);
          hit++;
          break;
        }
      }
    }
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
              'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=$kCaptureSampleRate',
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
              'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=$kCaptureSampleRate',
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

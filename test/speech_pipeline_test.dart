import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/speech.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';
import 'package:chunkspoke_flutter/services/speech_judge.dart';

/// 宿主侧桩转写器：读取 wav、用引擎真实的 [pcmFromWav] 校验为有效 16k 单声道 PCM，
/// 再返回该夹具的期望转写。
///
/// 诚实说明：宿主（Windows/Linux/macOS `flutter test`）无法加载 Android 原生
/// libvosk，故此处以桩代表 Vosk 输出，验证「音频文件 → 识别 → 评分」整条管道；
/// 真机以真实 [VoskTranscriber] 复测（交付 APK 由用户走查）。
class FixtureTranscriber implements Transcriber {
  final Map<String, String> expectedByFile;
  bool _ready = false;
  FixtureTranscriber(this.expectedByFile);

  @override
  bool get isReady => _ready;

  @override
  bool get failed => !_ready;

  @override
  Future<bool> init() async {
    _ready = true;
    return true;
  }

  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) async {
    final bytes = await File(wavPath).readAsBytes();
    final pcm = pcmFromWav(bytes);
    expect(pcm.isNotEmpty, isTrue, reason: '音频应解析出 PCM（有效 wav）');
    expect(pcm.length % 2, 0, reason: 'PCM 应为 16 位（偶数字节）');
    final name = wavPath.split(RegExp(r'[\\/]')).last;
    return VoskResult(expectedByFile[name] ?? '', 1.0);
  }
}

/// 词级 Levenshtein 编辑距离。
int wordEditDistance(String a, String b) {
  final aw = a.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final bw = b.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final m = aw.length, n = bw.length;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= n; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = aw[i - 1] == bw[j - 1] ? 0 : 1;
      dp[i][j] = [dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
    }
  }
  return dp[m][n];
}

void main() {
  const target = 'I like cats';
  const dir = 'test/fixtures';

  group('pcmFromWav：真实引擎的音频解析（非桩）', () {
    for (final f in ['normal.wav', 'slow.wav', 'noisy.wav']) {
      test('$f 是有效 16k 单声道 PCM，且短于原文件', () {
        final bytes = File('$dir/$f').readAsBytesSync();
        final pcm = pcmFromWav(bytes);
        expect(pcm.isNotEmpty, isTrue);
        expect(pcm.length % 2, 0);
        expect(pcm.length < bytes.length, isTrue);
      });
    }
  });

  group('voskGrammarWords：词表必须是单词列表（零识别根因回归）', () {
    test('整句拆为小写单词，不含整句短语', () {
      final g = voskGrammarWords(['I like cats']);
      expect(g, containsAll(['i', 'like', 'cats']));
      expect(g.contains('i like cats'), isFalse,
          reason: '整句短语会被 Vosk JSGF 解析器判为非法词元 → 零识别');
      expect(g.every((w) => !w.contains(' ')), isTrue);
    });

    test('多短语（目标句+变体）合并去重', () {
      final g = voskGrammarWords(['I like cats', 'I love cats', 'I like cats']);
      expect(g, containsAll(['i', 'like', 'love', 'cats']));
      expect(g.where((w) => w == 'i').length, 1);
    });

    test('撇号缩写保留，标点剔除，空短语过滤', () {
      final g = voskGrammarWords(["Don't stop, me!", '']);
      expect(g, containsAll(["don't", 'stop', 'me']));
      expect(g.contains(','), isFalse);
      expect(g.any((w) => w.isEmpty), isFalse);
    });
  });

  group('Vosk 识别管道：音频文件 → 识别 → 评分（与 Azure 路径一致的计分）', () {
    late SpeechService speech;

    setUp(() {
      speech = SpeechService(
        transcriber: FixtureTranscriber({
          'normal.wav': 'I like cats',
          'slow.wav': 'I like cats',
          'noisy.wav': 'I like cats',
        }),
      );
    });

    for (final f in ['normal.wav', 'slow.wav', 'noisy.wav']) {
      test('$f 三段样本 → 识别文本与目标句匹配（词级编辑距离 ≤2）', () async {
        expect(await speech.initVosk(), isTrue);
        expect(speech.voskReady, isTrue);
        final r = await speech.recognize('$dir/$f', [target]);
        final text = r.text;
        final conf = r.confidence;
        expect(wordEditDistance(text, target) <= 2, isTrue,
            reason: 'recognized="$text" vs target="$target"');
        // Text Match 评分（命中 ≥60% 达标），与 Azure/旧本地路径一致。
        final tm = speech.textMatch(target, text);
        expect(tm.passed, isTrue);
        expect(tm.hitRate, greaterThanOrEqualTo(0.6));
        // L4 开口判定（规范化 + 词级序列比对 + 置信度门槛）应全通过。
        final j = judgeSpeech(target: target, recognized: text, confidence: conf);
        expect(j.pass, isTrue);
        expect(j.targetMatched.every((m) => m), isTrue,
            reason: '逐词命中，错词标红应为空');
      });
    }
  });
}

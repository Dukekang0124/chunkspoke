import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/speech.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';

/// M1：只实现 [Transcriber] 的最小桩。降级链路不会碰它（走增强/云端），
/// 这里只是为了不在单测里构造原生引擎。
class _NoopTranscriber implements Transcriber {
  @override
  bool get isReady => false;

  @override
  bool get failed => true;

  @override
  Future<bool> init() async => false;

  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) async =>
      const VoskResult('', null);

  @override
  Future<VoskResult> transcribeOpen(String wavPath) async =>
      const VoskResult('', null);
}

void main() {
  group('M2 沙盒 textMatch：词级模糊匹配（与 L4 wordClose 同一套容错）', () {
    late SpeechService speech;
    setUp(() => speech = SpeechService(transcriber: _NoopTranscriber()));

    test('精确命中仍按原口径给满分', () {
      final tm = speech.textMatch('I like coffee', 'I like coffee');
      expect(tm.hitRate, 1.0);
      expect(tm.score, 100);
      expect(tm.passed, isTrue);
    });

    test('内容词近形（编辑距离 ≤1）计入命中，不再一票否决', () {
      final tm = speech.textMatch('I like coffee', 'I like coffey');
      expect(tm.hitRate, 1.0);
      expect(tm.passed, isTrue);
    });

    test('词干近似（多一个尾音）计入命中', () {
      final tm = speech.textMatch('I need a suit', 'I need a suite');
      expect(tm.hitRate, 1.0);
      expect(tm.passed, isTrue);
    });

    test('无关句仍判不过（模糊不等于放水）', () {
      final tm = speech.textMatch('I like cats', 'I like dogs');
      expect(tm.hitRate, closeTo(0.5, 1e-9));
      expect(tm.passed, isFalse);
    });

    test('沙盒经典误识保留基线：UD A SIZE DO YOU WANT 判过', () {
      final tm = speech.textMatch(
          'What size do you want?', 'UD A SIZE DO YOU WANT');
      expect(tm.passed, isTrue);
      expect(tm.hitRate, greaterThanOrEqualTo(0.6));
    });
  });

  group('M1 降级判定：openTranscriptPoor / asrKeywords', () {
    test('空文本视为明显不对', () {
      expect(openTranscriptPoor(text: '', target: 'What size do you want?'),
          isTrue);
      expect(openTranscriptPoor(text: '   ', target: 'What size do you want?'),
          isTrue);
    });

    test('词数不足目标 60% 视为明显不对', () {
      expect(openTranscriptPoor(text: 'what size', target: 'What size do you want?'),
          isTrue);
    });

    test('目标关键词全部缺失视为明显不对', () {
      expect(
          openTranscriptPoor(
              text: 'hello there friend', target: 'What size do you want?'),
          isTrue);
    });

    test('内容词命中即不算差（虚词丢失不触发降级）', () {
      expect(
          openTranscriptPoor(
              text: 'UD A SIZE DO YOU WANT', target: 'What size do you want?'),
          isFalse);
    });

    test('asrKeywords 去掉虚词，只留内容词', () {
      expect(asrKeywords('What size do you want?'), ['size', 'want']);
      expect(asrKeywords('the a to'), isEmpty);
    });

    test('无增强包、无云端 Key → 不做无谓重识，返回 null', () async {
      final speech = SpeechService(transcriber: _NoopTranscriber());
      final r = await speech.retryOpenWithFallback(
        wavPath: 'does-not-exist.wav',
        target: 'What size do you want?',
      );
      expect(r, isNull);
    });
  });
}

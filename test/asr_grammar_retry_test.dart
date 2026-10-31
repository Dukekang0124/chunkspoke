import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/speech.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';

/// ASR-188 缓解版：二过受限解码（Vosk grammar 锁目标句词表）的行为契约。
///
/// 只测「什么时候允许采纳二过」，不测原生识别质量——原生 Vosk 在宿主不可用，
/// 救回效果必须真机取证（见 验收-v1.6.0/发版材料/ASR-188-*）。
class _Fake implements Transcriber {
  /// 自由解码（phrases 为空）返回的文本 —— 刻意用截图里那条同音漂移。
  final String freeText = 'an old do the same';

  /// 受限解码（phrases 非空）返回的文本。
  final String grammarText;

  /// 记录每次调用的词表，用于断言 grammar 通道确实被调用、且锁的是整句。
  final List<List<String>> calls = [];

  bool ready;

  _Fake({
    this.grammarText = "i'll order the same",
    this.ready = true,
  });

  @override
  Future<bool> init() async => ready;

  @override
  bool get isReady => ready;

  @override
  bool get failed => !ready;

  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) async {
    calls.add(phrases);
    final constrained = phrases.isNotEmpty;
    final text = constrained ? grammarText : freeText;
    return VoskResult(text, constrained ? 1.0 : 0.55,
        wordConfidences: const [0.9, 0.9, 0.9, 0.9]);
  }

  @override
  Future<VoskResult> transcribeOpen(String wavPath) => transcribe(wavPath, const []);
}

void main() {
  const target = "I'll order the same.";

  SpeechService svc(_Fake f) => SpeechService(transcriber: f);

  test('一过自由解码漂移 → 二过锁目标句词表，返回受限结果', () async {
    final f = _Fake();
    final r = await svc(f).recognizeWithTargetGrammarRetry(
      wavPath: 'a.wav',
      targetSentence: target,
      firstText: f.freeText,
    );
    expect(r, isNotNull);
    expect(r!.text, "i'll order the same");
    // 词表来源 = 整句（含缩写，保留撇号），且确实走的是受限通道（phrases 非空）
    expect(f.calls.last, [target]);
  });

  test('二过与一过文本相同 → 返回 null（没有新信息，不改判）', () async {
    final f = _Fake(grammarText: 'an old do the same');
    final r = await svc(f).recognizeWithTargetGrammarRetry(
      wavPath: 'a.wav',
      targetSentence: target,
      firstText: 'an old do the same',
    );
    expect(r, isNull);
  });

  test('二过空文本 → 返回 null（词表过严不得伪造结果）', () async {
    final f = _Fake(grammarText: '   ');
    final r = await svc(f).recognizeWithTargetGrammarRetry(
      wavPath: 'a.wav',
      targetSentence: target,
      firstText: f.freeText,
    );
    expect(r, isNull);
  });

  test('目标句无有效词（纯标点）→ 不发起二过', () async {
    final f = _Fake();
    final r = await svc(f).recognizeWithTargetGrammarRetry(
      wavPath: 'a.wav',
      targetSentence: '...!!',
      firstText: f.freeText,
    );
    expect(r, isNull);
    expect(f.calls, isEmpty, reason: '词表为空时不该再跑一次识别');
  });

  test('引擎未就绪 → 不发起二过', () async {
    final f = _Fake(ready: false);
    final r = await svc(f).recognizeWithTargetGrammarRetry(
      wavPath: 'a.wav',
      targetSentence: target,
      firstText: f.freeText,
    );
    expect(r, isNull);
    expect(f.calls, isEmpty);
  });

  test('一过仍走开放输出：recognizeOpen 不把目标句词表透传给原生（B5 口径不变）',
      () async {
    final f = _Fake();
    final r = await svc(f).recognizeOpen('a.wav', e2ePhrases: [target]);
    expect(r.text, f.freeText);
    expect(f.calls.last, isEmpty, reason: '生产路径（非覆写）二参必须为空 = 自由解码');
  });
}

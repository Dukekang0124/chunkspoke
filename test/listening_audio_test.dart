import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/listening_audio.dart';
import 'package:chunkspoke_flutter/services/wav_codec.dart';

/// 假音色：可配置两条合成通道的成败与句长，产物是真实可解析的 WAV。
class _FakeVoice implements ListeningVoice {
  _FakeVoice({
    this.preferHd = true,
    this.hdKey = 'hd:v1',
    this.hdMs = 1000,
    this.sysMs = 400,
    this.hdFail = false,
    this.sysFail = false,
    this.hdFailAt = -1,
  });

  @override
  bool preferHd;
  String hdKey;
  final String sysKey = 'sys:engine|voice|en-US';
  int hdMs;
  final int sysMs;
  bool hdFail;
  bool sysFail;
  int hdFailAt;

  int hdCalls = 0;
  int sysCalls = 0;

  @override
  String get voiceKey => hdKey;

  @override
  String get systemVoiceKey => sysKey;

  @override
  Future<bool> synthesizeToFile(String text, String fullPath,
      {required bool hd}) async {
    if (hd) {
      hdCalls++;
      if (hdFail || (hdFailAt >= 0 && hdCalls > hdFailAt)) return false;
    } else {
      sysCalls++;
      if (sysFail) return false;
    }
    final ms = hd ? hdMs : sysMs;
    const rate = 8000;
    await writeWavFile(
        File(fullPath), Float32List(rate * ms ~/ 1000), rate);
    return true;
  }
}

ListeningArticle _article(String id, List<String> texts) => ListeningArticle(
      id: id,
      title: id,
      scene: 'test',
      sceneLabel: '测试场景',
      summaryCN: '',
      updatedAt: '',
      audioUrl: '',
      collectLimit: 8,
      sentences: [
        for (var i = 0; i < texts.length; i++)
          ListeningSentence(
            id: '${id}_s$i',
            text: texts[i],
            meaningCN: '',
            chunks: const [],
          ),
      ],
    );

List<File> _wavs(Directory dir) => dir
    .listSync()
    .whereType<File>()
    .where((f) => f.path.endsWith('.wav'))
    .toList();

void main() {
  late Directory dir;
  late ListeningAudioPipeline pipeline;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('listen_audio');
    pipeline = ListeningAudioPipeline(
      cacheDir: () async => dir,
      clock: () => DateTime(2026, 10, 23, 9),
    );
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('精确模式：实测 WAV 时长回填句级时间轴，不用词数估算', () async {
    final voice = _FakeVoice(hdMs: 1200);
    final plan = await pipeline.prepare(
        _article('L01', ['Hello there.', 'This is a longer sentence.']), voice);

    expect(plan.source, ListeningAudioSource.hd);
    expect(plan.precise, isTrue);
    expect(plan.synthesized, 2);
    expect(plan.reused, 0);
    expect(plan.sentences[0].startMs, 0);
    expect(plan.sentences[0].endMs, 1200);
    expect(plan.sentences[1].startMs, 1200);
    expect(plan.sentences[1].endMs, 2400);
    expect(plan.totalMs, 2400);
    expect(plan.startMsOf(0), 0);
    expect(plan.startMsOf(1), 1200);
    expect(plan.startMsOf(99), 2400);
    expect(plan.indexForPositionMs(0), 0);
    expect(plan.indexForPositionMs(1199), 0);
    expect(plan.indexForPositionMs(1200), 1);
    expect(plan.indexForPositionMs(99999), 1);
    for (final s in plan.sentences) {
      expect(await File(s.path!).exists(), isTrue);
    }
    expect(await readWavDurationSeconds(File(plan.sentences[0].path!)),
        closeTo(1.2, 1e-9));
  });

  test('同音色二次打开整篇命中缓存，不重复合成且文件仍在（不回删）', () async {
    final voice = _FakeVoice();
    final article = _article('L01', ['One.', 'Two.']);

    final first = await pipeline.prepare(article, voice);
    expect(first.synthesized, 2);
    expect(voice.hdCalls, 2);

    final second = await pipeline.prepare(article, voice);
    expect(second.source, ListeningAudioSource.hd);
    expect(second.synthesized, 0);
    expect(second.reused, 2);
    expect(voice.hdCalls, 2, reason: '缓存命中不应触发任何合成');
    for (final s in second.sentences) {
      expect(await File(s.path!).exists(), isTrue,
          reason: '缓存命中后旧文件被误删，播放会失败');
    }
    expect(second.totalMs, first.totalMs);
  });

  test('音色变更 → 整篇缓存失效重合成，旧音色文件被清理', () async {
    final voice = _FakeVoice(hdKey: 'hd:v1');
    final article = _article('L01', ['One.', 'Two.']);
    final old = await pipeline.prepare(article, voice);

    voice
      ..hdKey = 'hd:v2'
      ..hdMs = 1500;
    final fresh = await pipeline.prepare(article, voice);
    expect(fresh.synthesized, 2);
    expect(fresh.reused, 0);
    expect(fresh.voiceKey, 'hd:v2');
    expect(fresh.totalMs, 3000);
    for (final s in old.sentences) {
      expect(await File(s.path!).exists(), isFalse);
    }
    expect(_wavs(dir).length, 2);
  });

  test('HD 不可用 → 整篇回落系统 TTS，不混音色', () async {
    final voice = _FakeVoice(hdFail: true, hdMs: 1000, sysMs: 400);
    final plan =
        await pipeline.prepare(_article('L01', ['One.', 'Two.']), voice);

    expect(plan.source, ListeningAudioSource.system);
    expect(plan.precise, isTrue);
    expect(plan.synthesized, 2);
    expect(plan.voiceKey, voice.sysKey);
    expect(plan.sentences.map((s) => s.durationMs), [400, 400]);
    expect(plan.totalMs, 800);
    expect(_wavs(dir).length, 2);
  });

  test('HD 中途失败 → 半成品清掉，整篇改用系统 TTS', () async {
    final voice = _FakeVoice(hdFailAt: 1, hdMs: 1000, sysMs: 400);
    final plan = await pipeline.prepare(
        _article('L01', ['One.', 'Two.', 'Three.']), voice);

    expect(plan.source, ListeningAudioSource.system);
    expect(plan.synthesized, 3);
    final names = _wavs(dir).map((f) => f.uri.pathSegments.last).toList();
    expect(names.length, 3, reason: 'HD 半成品文件应已清除');
    expect(voice.hdCalls, 2);
    expect(voice.sysCalls, 3);
  });

  test('两路都不可用 → 直播降级计划：无 WAV、时间轴明确标为估算', () async {
    final voice = _FakeVoice(hdFail: true, sysFail: true);
    final article = _article('L01', ['one two three', 'four five']);
    final plan = await pipeline.prepare(article, voice);

    expect(plan.source, ListeningAudioSource.live);
    expect(plan.precise, isFalse);
    expect(plan.live, isTrue);
    for (final s in plan.sentences) {
      expect(s.path, isNull);
    }
    expect(plan.sentences[0].durationMs, estimateLiveSentenceMs('one two three'));
    expect(plan.sentences[0].durationMs, 1200);
    expect(plan.sentences[1].durationMs, 800);
    expect(plan.totalMs, 2000);
    expect(_wavs(dir), isEmpty);
  });

  test('LRU：超过上限清理最久未听篇目，当前篇永不清理', () async {
    pipeline = ListeningAudioPipeline(
      cacheDir: () async => dir,
      maxBytes: 20000, // 单篇约 32KB（2 句 × 1 秒 @8kHz），两篇即超
      clock: () => DateTime(2026, 10, 23, 9),
    );
    final voice = _FakeVoice();
    final a = await pipeline.prepare(_article('LA', ['One.', 'Two.']), voice);
    expect(_wavs(dir).length, 2);

    final b = await pipeline.prepare(_article('LB', ['One.', 'Two.']), voice);
    expect(_wavs(dir).length, 2, reason: '超出上限应整篇清掉最久未听的 LA');
    for (final s in a.sentences) {
      expect(await File(s.path!).exists(), isFalse);
    }
    for (final s in b.sentences) {
      expect(await File(s.path!).exists(), isTrue);
    }

    // LA 已被清理，再次打开必须重新合成，而不是拿到失效缓存。
    final again = await pipeline.prepare(_article('LA', ['One.', 'Two.']), voice);
    expect(again.synthesized, 2);
    expect(again.reused, 0);
  });

  test('索引损坏 → 不炸，重建并重新合成', () async {
    await File('${dir.path}/index.json').writeAsString('{bad json');
    final plan = await pipeline.prepare(
        _article('L01', ['One.']), _FakeVoice());
    expect(plan.precise, isTrue);
    expect(plan.synthesized, 1);
    final index = await File('${dir.path}/index.json').readAsString();
    expect(index, contains('"version":1'));
  });

  test('系统音色直连（无 HD）也能出精确时间轴', () async {
    final voice = _FakeVoice(preferHd: false, sysMs: 600);
    final plan = await pipeline.prepare(
        _article('L01', ['One.', 'Two.']), voice);
    expect(plan.source, ListeningAudioSource.system);
    expect(plan.synthesized, 2);
    expect(voice.hdCalls, 0);
    expect(plan.totalMs, 1200);
  });

  test('句间静音/过短产物被拒绝 → 回落另一音源，不写入精确时间轴', () async {
    final voice = _FakeVoice(hdMs: 0, sysMs: 400);
    final plan = await pipeline.prepare(
        _article('L01', ['One.', 'Two.']), voice);
    expect(plan.source, ListeningAudioSource.system);
    expect(plan.totalMs, 800);
  });
}

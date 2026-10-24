import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/listening_audio.dart';
import 'package:chunkspoke_flutter/services/listening_explanation.dart';
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
    this.msFor,
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

  /// 按文本定制时长（同句多块合并段模拟超 8 秒）。
  final int Function(String text)? msFor;

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
    final ms = hd ? (msFor?.call(text) ?? hdMs) : sysMs;
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

  group('讲解版插入（指令 S+）', () {
    test('讲解段插在句尾：条目时间轴/句锚/条目锚一致', () async {
      final a = _chunk('a', 'alpha');
      final b = _chunk('b', 'beta', candidate: true);
      final article = _chunked('L01', [
        _line('s0', 'Alpha beta.', [a, b]),
        _line('s1', 'Plain one.', []),
      ]);
      final plan = await pipeline.prepare(
        article,
        _FakeVoice(),
        explanations: [
          _segment(0, [
            _explained(a, 'alpha. 甲'),
            _explained(b, 'beta. beta. 乙'),
          ]),
        ],
      );

      expect(plan.precise, isTrue);
      expect(plan.hasExplanations, isTrue);
      expect(plan.explanationSynthesized, 1);
      expect(plan.items.map((e) => e.isExplanation), [false, true, false]);
      expect(plan.items[1].startMs, 1000);
      expect(plan.items[1].endMs, 2000);
      expect(plan.items[1].chunkIds, ['a', 'b']);
      expect(plan.items[1].memoryKeys, ['i:a', 't:beta']);
      // 正文句时间轴被讲解段整体后移，但句锚仍是 1。
      expect(plan.sentences[1].startMs, 2000);
      expect(plan.sentences[1].endMs, 3000);
      expect(plan.totalMs, 3000);
      expect(plan.startMsOf(1), 2000);
      expect(plan.itemIndexForSentence(1), 2);
      expect(plan.indexForPositionMs(1500), 0);
      expect(plan.explanationForSentence(0)?.id, isNotEmpty);
      expect(plan.explanationForSentence(1), isNull);
      expect(await File(plan.items[1].path!).exists(), isTrue);
    });

    test('同音色二次打开讲解段整段命中缓存', () async {
      final article = _chunked('L01', [
        _line('s0', 'Alpha.', [_chunk('a', 'alpha')]),
      ]);
      final segments = [_segment(0, [_explained(_chunk('a', 'alpha'), 'alpha. 甲')])];
      final voice = _FakeVoice();

      final first = await pipeline.prepare(article, voice, explanations: segments);
      expect(first.explanationSynthesized, 1);
      expect(voice.hdCalls, 2); // 正文 1 + 讲解 1

      final second = await pipeline.prepare(article, voice, explanations: segments);
      expect(second.explanationSynthesized, 0);
      expect(second.explanationReused, 1);
      expect(voice.hdCalls, 2, reason: '讲解段缓存命中不应再合成');
      expect(await File(second.items[1].path!).exists(), isTrue);
    });

    test('切回原版保留讲解缓存；再开讲解版直接复用', () async {
      final article = _chunked('L01', [
        _line('s0', 'Alpha.', [_chunk('a', 'alpha')]),
      ]);
      final segments = [_segment(0, [_explained(_chunk('a', 'alpha'), 'alpha. 甲')])];
      final voice = _FakeVoice();

      final explained = await pipeline.prepare(
          article, voice, explanations: segments);
      final explPath = explained.items[1].path!;

      final original = await pipeline.prepare(article, voice);
      expect(original.hasExplanations, isFalse);
      expect(await File(explPath).exists(), isTrue,
          reason: '原版不应删掉讲解缓存，否则每次切模式都要重合成');

      final again = await pipeline.prepare(article, voice, explanations: segments);
      expect(again.explanationReused, 1);
      expect(again.explanationSynthesized, 0);
      expect(voice.hdCalls, 2);
    });

    test('换音色 → 正文与讲解一起失效重合成，旧讲解文件被清理', () async {
      final article = _chunked('L01', [
        _line('s0', 'Alpha.', [_chunk('a', 'alpha')]),
      ]);
      final segments = [_segment(0, [_explained(_chunk('a', 'alpha'), 'alpha. 甲')])];
      final voice = _FakeVoice(hdKey: 'hd:v1');

      final old = await pipeline.prepare(article, voice, explanations: segments);
      final oldExpl = old.items[1].path!;

      voice
        ..hdKey = 'hd:v2'
        ..hdMs = 900;
      final fresh =
          await pipeline.prepare(article, voice, explanations: segments);
      expect(fresh.explanationSynthesized, 1);
      expect(fresh.explanationReused, 0);
      expect(fresh.items[1].durationMs, 900);
      expect(await File(oldExpl).exists(), isFalse);
    });

    test('同句多块合并超 8 秒 → 从尾部丢块重合成', () async {
      final a = _chunk('a', 'alpha');
      final b = _chunk('b', 'betaX');
      final article = _chunked('L01', [
        _line('s0', 'Alpha betaX.', [a, b]),
      ]);
      // 合并段（含 beta）→ 9 秒；单块 alpha → 5 秒。
      final voice = _FakeVoice(
          msFor: (t) => t.contains('beta') ? 9000 : 5000);
      final plan = await pipeline.prepare(
        article,
        voice,
        explanations: [
          _segment(0, [_explained(a, 'alpha. 甲'), _explained(b, 'beta. 乙')]),
        ],
      );

      expect(plan.hasExplanations, isTrue);
      final expl = plan.items[1];
      expect(expl.durationMs, 5000);
      expect(expl.chunkIds, ['a'], reason: '超 8 秒应从尾部丢块');
      expect(expl.memoryKeys, ['i:a']);
      expect(_wavs(dir).length, 2, reason: '超限的合并段文件应已删除');
    });

    test('单块仍超 8 秒 → 整段优雅跳过，正文照常精确播放', () async {
      final article = _chunked('L01', [
        _line('s0', 'Alpha.', [_chunk('a', 'alpha')]),
      ]);
      final plan = await pipeline.prepare(
        article,
        _FakeVoice(msFor: (_) => 9000),
        explanations: [
          _segment(0, [_explained(_chunk('a', 'alpha'), 'alpha. 甲')]),
        ],
      );
      expect(plan.precise, isTrue);
      expect(plan.hasExplanations, isFalse);
      expect(plan.items, hasLength(1));
      expect(plan.explanationSynthesized, 0);
      expect(_wavs(dir), hasLength(1));
    });

    test('LRU 把讲解文件计入并随篇目整篇清理', () async {
      final voice = _FakeVoice();
      final a = _chunked('LA', [
        _line('s0', 'Alpha.', [_chunk('a', 'alpha')]),
      ]);
      final b = _chunked('LB', [
        _line('s0', 'Bravo.', [_chunk('b', 'bravo')]),
      ]);
      final segA = [_segment(0, [_explained(_chunk('a', 'alpha'), 'alpha. 甲')])];
      final segB = [_segment(0, [_explained(_chunk('b', 'bravo'), 'bravo. 乙')])];

      final first = await pipeline.prepare(a, voice, explanations: segA);
      final aBytes =
          _wavs(dir).fold<int>(0, (s, f) => s + f.lengthSync());
      final tight = ListeningAudioPipeline(
        cacheDir: () async => dir,
        maxBytes: aBytes + 1,
        clock: () => DateTime(2026, 10, 23, 9),
      );
      final second = await tight.prepare(b, voice, explanations: segB);

      expect(await File(first.items[1].path!).exists(), isFalse,
          reason: '讲解文件也计入上限，LA 应整篇清掉');
      expect(await File(first.items[0].path!).exists(), isFalse);
      expect(await File(second.items[1].path!).exists(), isTrue);
    });
  });

  test('16 篇全量讲解段合成无失败（真实内容包）', () async {
    final content = ContentPack.fromJson(jsonDecode(
            await File('assets/content_pack.json').readAsString())
        as Map<String, dynamic>);
    final pack = ListeningPack.fromJson(jsonDecode(
            await File('assets/listening_articles.json').readAsString())
        as Map<String, dynamic>);
    final voice = _FakeVoice(hdMs: 800);

    var segmentCount = 0;
    for (final a in pack.articles) {
      final segments = ListeningExplanationBuilder.build(
        article: a,
        states: const {},
        content: content,
      );
      segmentCount += segments.length;
      final plan =
          await pipeline.prepare(a, voice, explanations: segments);
      expect(plan.precise, isTrue, reason: a.id);
      expect(plan.items.where((e) => e.isExplanation).length, segments.length,
          reason: '${a.id} 有讲解段合成失败');
      for (final it in plan.items.where((e) => e.isExplanation)) {
        expect(it.durationMs, inInclusiveRange(1, 8000), reason: a.id);
        expect(it.chunkIds, isNotEmpty, reason: a.id);
        expect(it.memoryKeys.length, it.chunkIds.length, reason: a.id);
      }
    }
    expect(segmentCount, greaterThan(0));
  });
}

ListeningChunk _chunk(String id, String text,
        {bool candidate = false, String cn = ''}) =>
    ListeningChunk(
        id: id, text: text, meaningCN: cn, candidate: candidate);

ListeningSentence _line(
        String id, String text, List<ListeningChunk> chunks) =>
    ListeningSentence(id: id, text: text, meaningCN: '', chunks: chunks);

ListeningArticle _chunked(String id, List<ListeningSentence> sentences) =>
    ListeningArticle(
      id: id,
      title: id,
      scene: 'test',
      sceneLabel: '测试',
      summaryCN: '',
      updatedAt: '',
      audioUrl: '',
      collectLimit: 8,
      sentences: sentences,
    );

ListeningExplainedChunk _explained(ListeningChunk chunk, String text) =>
    ListeningExplainedChunk(
      chunk: chunk,
      kind: chunk.candidate
          ? ListeningExplanationKind.candidate
          : ListeningExplanationKind.learning,
      key: chunk.candidate
          ? 't:${chunk.text.trim().toLowerCase()}'
          : 'i:${chunk.id}',
      text: text,
    );

ListeningExplanationSegment _segment(
        int sentenceIndex, List<ListeningExplainedChunk> chunks) =>
    ListeningExplanationSegment(
      sentenceIndex: sentenceIndex,
      text: [for (final c in chunks) c.text].join(' '),
      chunks: chunks,
    );

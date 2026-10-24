import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/listening_explanation.dart';

ListeningChunk _chunk(
  String id,
  String text, {
  String cn = '',
  bool candidate = false,
}) =>
    ListeningChunk(id: id, text: text, meaningCN: cn, candidate: candidate);

ListeningSentence _sentence(String id, String text, List<ListeningChunk> chunks) =>
    ListeningSentence(id: id, text: text, meaningCN: '', chunks: chunks);

ListeningArticle _article(String id, List<ListeningSentence> sentences) =>
    ListeningArticle(
      id: id,
      title: id,
      scene: 'test',
      sceneLabel: '测试',
      summaryCN: '',
      updatedAt: '',
      audioUrl: '',
      collectLimit: 6,
      sentences: sentences,
    );

ContentPack _pack(Map<String, String> defs) => ContentPack(version: 't', levels: [
      Level(
        id: 'lv',
        theme: 't',
        sceneImage: '',
        chunks: [
          for (final e in defs.entries)
            Chunk.fromJson({
              'id': e.key,
              'text': e.key,
              'type': 'content',
              'meaningCN': e.value,
            }),
        ],
      ),
    ]);

void main() {
  group('讲解文本模板（指令 S+ §一.3/§一.4）', () {
    test('候选=块面×2+文中 gloss；在学=块面×1+库内释义；首遇去重', () {
      final article = _article('L01', [
        _sentence('s0', 'I drink oat milk every day.', [
          _chunk('lx_oat', 'oat milk', cn: '燕麦奶', candidate: true),
        ]),
        _sentence('s1', 'I have it for breakfast.', [
          _chunk('c_breakfast', 'for breakfast'),
        ]),
        // 同块再次出现：全篇只讲首遇。
        _sentence('s2', 'Oat milk is nice.', [
          _chunk('lx_oat', 'oat milk', cn: '燕麦奶', candidate: true),
        ]),
      ]);
      final pack = _pack({'c_breakfast': '早餐时吃的东西'});

      final segments = ListeningExplanationBuilder.build(
        article: article,
        states: const {},
        content: pack,
      );

      expect(segments.map((e) => e.sentenceIndex), [0, 1]);
      expect(segments[0].text, 'oat milk. oat milk. 燕麦奶');
      expect(segments[0].chunks.single.kind, ListeningExplanationKind.candidate);
      expect(segments[0].chunks.single.key, 't:oat milk');
      expect(segments[0].chunkIds, ['lx_oat']);

      expect(segments[1].text, 'for breakfast. 早餐时吃的东西');
      expect(segments[1].chunks.single.kind, ListeningExplanationKind.learning);
      expect(segments[1].chunks.single.key, 'i:c_breakfast');
    });

    test('金色已掌握跳过；候选块不受资产状态影响', () {
      final article = _article('L01', [
        _sentence('s0', 'Gold and blue.', [
          _chunk('c_gold', 'gold'),
          _chunk('lx_blue', 'blue', cn: '蓝色', candidate: true),
        ]),
      ]);
      final segments = ListeningExplanationBuilder.build(
        article: article,
        states: const {'c_gold': ChunkAssetState.mastered},
        content: _pack({'c_gold': '金色'}),
      );
      expect(segments.single.chunkIds, ['lx_blue']);
      expect(segments.single.text, 'blue. blue. 蓝色');
    });

    test('同句多块合并成一段，顺序按句内块序', () {
      final article = _article('L01', [
        _sentence('s0', 'A and B.', [
          _chunk('c_a', 'alpha'),
          _chunk('c_b', 'beta'),
        ]),
      ]);
      final segments = ListeningExplanationBuilder.build(
        article: article,
        states: const {},
        content: _pack({'c_a': '甲', 'c_b': '乙'}),
      );
      expect(segments, hasLength(1));
      expect(segments.single.chunks.map((e) => e.chunk.id), ['c_a', 'c_b']);
      expect(segments.single.text, 'alpha. 甲 beta. 乙');
    });

    test('缺释义优雅跳过：候选无 gloss、在学无库内释义/库内找不到', () {
      final article = _article('L01', [
        _sentence('s0', 'Missing gloss.', [
          _chunk('lx_nogloss', 'no gloss', candidate: true),
          _chunk('c_unknown', 'unknown'),
          _chunk('c_blank', 'blank'),
          _chunk('c_ok', 'ok'),
        ]),
      ]);
      final segments = ListeningExplanationBuilder.build(
        article: article,
        states: const {},
        content: _pack({'c_blank': '   ', 'c_ok': '好的'}),
      );
      expect(segments.single.chunkIds, ['c_ok']);
      expect(segments.single.text, 'ok. 好的');
    });

    test('库内释义按 15 字截断，且不把中文截成半个码点', () {
      const long = '一二三四五六七八九十一二三四五六七八九十';
      final segments = ListeningExplanationBuilder.build(
        article: _article('L01', [
          _sentence('s0', 'x', [_chunk('c_long', 'x')]),
        ]),
        states: const {},
        content: _pack({'c_long': long}),
      );
      expect(segments.single.text, 'x. 一二三四五六七八九十一二三四五');
      expect(ListeningExplanationBuilder.clipDefinition(long, 15).runes.length,
          15);
      expect(ListeningExplanationBuilder.clipDefinition('  短  ', 15), '短');
    });

    test('跨篇首遇记忆：候选按文本键、在学按块 id，互不误伤', () {
      final first = ListeningExplanationBuilder.build(
        article: _article('L01', [
          _sentence('s0', 'Oat milk and breakfast.', [
            _chunk('lx_oat', 'Oat  Milk', cn: '燕麦奶', candidate: true),
            _chunk('c_breakfast', 'breakfast'),
          ]),
        ]),
        states: const {},
        content: _pack({'c_breakfast': '早餐'}),
      );
      final memory = first.single.memoryKeys;
      expect(memory, ['t:oat milk', 'i:c_breakfast']);

      final second = ListeningExplanationBuilder.build(
        article: _article('L02', [
          _sentence('s0', 'More oat milk here.', [
            _chunk('lx_oat_2', 'oat milk', cn: '燕麦奶', candidate: true),
          ]),
          _sentence('s1', 'Another breakfast.', [
            _chunk('c_breakfast', 'breakfast'),
          ]),
          _sentence('s2', 'A fresh chunk.', [
            _chunk('c_fresh', 'fresh'),
          ]),
        ]),
        states: const {},
        content: _pack({'c_breakfast': '早餐', 'c_fresh': '新鲜的'}),
        alreadyExplained: memory.toSet(),
      );
      expect(second.map((e) => e.sentenceIndex), [2]);
      expect(second.single.chunkIds, ['c_fresh']);
    });

    test('空句/无块文章返回空列表，不炸', () {
      final segments = ListeningExplanationBuilder.build(
        article: _article('L01', [_sentence('s0', 'Plain.', const [])]),
        states: const {},
        content: _pack({}),
      );
      expect(segments, isEmpty);
    });
  });
}

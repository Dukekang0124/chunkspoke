import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/sandbox_store.dart';

Chunk _c(String id, String text, {String cn = ''}) => Chunk(
      id: id,
      text: text,
      semantic: 'content',
      meaningCN: cn,
      sentence: ChunkSentence(
          text: text,
          slots: const [],
          coreWords: const [],
          swapSlotIndex: -1,
          swapOptions: const []),
    );

Level _level(String id, String theme, List<Chunk> chunks) => Level(
      id: id,
      theme: theme,
      sceneImage: '',
      chunks: chunks,
      sentences: [
        TargetSentence(
            id: '${id}s1',
            text: chunks.map((c) => c.text).join(' '),
            meaningCN: '',
            chunkIds: chunks.map((c) => c.id).toList()),
      ],
    );

void main() {
  group('自动标点 polishSentence', () {
    test('首字母大写 + 补句号，不改词、不插逗号', () {
      expect(polishSentence('good morning'), 'Good morning.');
      expect(polishSentence('  i   am  fine  '), 'I am fine.');
    });
    test('已有句末标点不重复补', () {
      expect(polishSentence('How are you?'), 'How are you?');
      expect(polishSentence('Great!'), 'Great!');
      expect(polishSentence('Done.'), 'Done.');
    });
    test('空串原样返回', () {
      expect(polishSentence('   '), '');
    });
  });

  group('串联判定 isChain', () {
    final mastered = {'a1', 'a2', 'a3'};
    test('≥2 个不同已掌握块才算串联', () {
      expect(
          isChain([_c('a1', 'Good morning'), _c('a2', 'thank you')], mastered),
          isTrue);
      expect(
          isChain([_c('a1', 'Good morning'), _c('b9', 'very much')], mastered),
          isFalse);
    });
    test('同一块重复出现不凑数', () {
      expect(isChain([_c('a1', 'ok'), _c('a1', 'ok')], mastered), isFalse);
    });
  });

  group('块池去重合并 dedupePool', () {
    test('同表面形态（忽略大小写/标点）合并成一枚，释义与 id 都并进来', () {
      final pool = dedupePool([
        _c('a1', 'Good morning', cn: '早上好'),
        _c('b2', 'good morning!', cn: '早安'),
        _c('c3', 'Thank you', cn: '谢谢'),
      ]);
      expect(pool.length, 2);
      final merged = pool.firstWhere((m) => m.text == 'Good morning');
      expect(merged.mergedCount, 2);
      expect(merged.ids, ['a1', 'b2']);
      expect(merged.meanings, containsAll(['早上好', '早安']));
    });
    test('无释义的块不会造出空释义行', () {
      final pool = dedupePool([_c('a1', 'OK')]);
      expect(pool.single.meanings, isEmpty);
    });
  });

  group('搜索双匹配 matchesQuery', () {
    final pool = dedupePool([_c('a1', 'Good morning', cn: '早上好')]);
    final m = pool.single;
    test('英文表面形态（忽略大小写与标点）命中', () {
      expect(matchesQuery(m, 'good'), isTrue);
      expect(matchesQuery(m, 'MORNING'), isTrue);
      expect(matchesQuery(m, 'good morning'), isTrue);
    });
    test('中文释义命中', () {
      expect(matchesQuery(m, '早上'), isTrue);
    });
    test('不相关词不命中；空串放行', () {
      expect(matchesQuery(m, 'airport'), isFalse);
      expect(matchesQuery(m, '  '), isTrue);
    });
  });

  group('块池排序 orderPool', () {
    final pool = dedupePool([
      _c('a1', 'Good morning'),
      _c('a2', 'Thank you'),
      _c('b1', 'Excuse me'),
    ]);
    final sceneOf = {'a1': 'A', 'a2': 'A', 'b1': 'B'};

    test('最近使用置顶，其余按场景分组', () {
      final ordered = orderPool(
          pool: pool, lastUsed: {'b1': 2000, 'a2': 1000}, sceneOf: sceneOf);
      expect(ordered.map((c) => c.id).toList(), ['b1', 'a2', 'a1']);
    });
    test('没有任何使用记录时按场景顺序排', () {
      final ordered = orderPool(pool: pool, lastUsed: {}, sceneOf: sceneOf);
      expect(ordered.map((c) => c.id).toList(), ['a1', 'a2', 'b1']);
    });
    test('场景标签数据源＝内容 schema 的场景字段', () {
      final tags = sceneTags(
          ContentPack(version: 't', levels: [
            _level(
                'A', '打招呼', [_c('a1', 'Good morning'), _c('a2', 'Thank you')]),
            _level('B', '索取东西', [_c('b1', 'Excuse me')]),
          ]),
          sceneOf);
      expect(tags.map((t) => '${t.label}:${t.count}').toList(),
          ['打招呼:2', '索取东西:1']);
    });
  });

  group('内容 schema 重复表面形态警告（不阻断）', () {
    test('重复只出警告文案，不影响解析', () {
      final content = ContentPack(version: 't', levels: [
        _level('A', '打招呼', [_c('a1', 'Good morning'), _c('a2', 'Thank you')]),
        _level('B', '酒店', [_c('b1', 'good morning')]),
      ]);
      final w = duplicateSurfaceWarnings(content);
      expect(w.length, 1);
      expect(w.single, contains('good morning'));
      expect(w.single, contains('2 块'));
    });
    test('无重复时不产生噪音', () {
      final content = ContentPack(version: 't', levels: [
        _level('A', '打招呼', [_c('a1', 'Good morning'), _c('a2', 'Thank you')]),
      ]);
      expect(duplicateSurfaceWarnings(content), isEmpty);
    });
    test('真内容包查重：确实存在同形块，警告不是噪音（与内容报告同口径）', () {
      final pack = ContentPack.fromJson(jsonDecode(
              File('assets/content_pack.json').readAsStringSync())
          as Map<String, dynamic>);
      final w = duplicateSurfaceWarnings(pack);
      expect(w, isNotEmpty);
      expect(w.firstWhere((e) => e.contains('excuse me')), contains('3 块'));
    });
  });

  group('SandboxStore（KV 后端）', () {
    late Map<String, String> kv;
    late DateTime clockNow;
    late SandboxStore store;
    setUp(() {
      kv = {};
      clockNow = DateTime(2026, 10, 22, 9);
      store = SandboxStore(
        read: (k) => kv[k],
        write: (k, v) async => kv[k] = v,
        clock: () => clockNow,
      );
    });

    test('空态：统计全 0、句子为空、坏 JSON 不炸', () {
      expect(store.stats.visits, 0);
      expect(store.stats.sentences, isEmpty);
      kv[SandboxStore.kSentences] = '{不是数组';
      expect(store.sentences, isEmpty);
    });

    test('访问/搜索/筛选各自累加', () async {
      await store.recordVisit();
      await store.recordVisit();
      await store.recordSearch();
      await store.recordFilter();
      await store.recordFilter();
      final s = store.stats;
      expect(s.visits, 2);
      expect(s.searchUsed, 1);
      expect(s.filterUsed, 2);
    });

    test('存句：自动标点、倒序、串联计数、最近使用时间戳', () async {
      await store.addSentence(
          [_c('a1', 'good morning'), _c('a2', 'thank you')], {'a1', 'a2'});
      expect(store.sentences.single.text, 'Good morning thank you.');
      expect(store.sentences.single.chain, isTrue);
      expect(store.stats.chainCount, 1);
      expect(store.lastUsedAt['a1'], clockNow.millisecondsSinceEpoch);

      clockNow = clockNow.add(const Duration(minutes: 5));
      await store.addSentence([_c('b1', 'excuse me')], {'a1', 'a2'});
      expect(store.sentences.first.text, 'Excuse me.'); // 新的在前
      expect(store.stats.chainCount, 1); // 非串联句不加计数
      expect(store.lastUsedAt['b1'], isNotNull);
    });

    test('删除按创建时间定位，删不掉别的', () async {
      await store.addSentence([_c('a1', 'one')], {});
      clockNow = clockNow.add(const Duration(seconds: 1));
      final second = clockNow.millisecondsSinceEpoch;
      await store.addSentence([_c('a2', 'two')], {});
      await store.deleteSentence(second);
      expect(store.sentences.map((s) => s.text).toList(), ['One.']);
    });

    test('句子数封顶 200，最旧的被挤掉', () async {
      for (var i = 0; i < 205; i++) {
        clockNow = clockNow.add(const Duration(seconds: 1));
        await store.addSentence([_c('c$i', 'word$i')], {});
      }
      expect(store.sentences.length, SandboxStore.kMaxSentences);
      expect(store.sentences.first.text, 'Word204.');
    });

    test('句子里的块 id 一起存，重录时能还原', () async {
      await store.addSentence([_c('a1', 'Hi'), _c('a2', 'there')], {});
      final raw = jsonDecode(kv[SandboxStore.kSentences]!) as List;
      expect((raw.first as Map)['ids'], ['a1', 'a2']);
    });
  });

  group('资产轴取集合', () {
    ChunkRow row(String k, ChunkAssetState s) => ChunkRow(
          chunkKey: k,
          level: ChunkLevel.review,
          dueDate: 0,
          failCount: 0,
          lastScore: 0,
          assetState: s,
        );
    test('已掌握 / 需重修 分别取键集', () {
      final rows = [
        row('a1', ChunkAssetState.mastered),
        row('a2', ChunkAssetState.relearning),
        row('a3', ChunkAssetState.consolidated),
      ];
      expect(masteredIdsOf(rows), {'a1'});
      expect(relearningIdsOf(rows), {'a2'});
    });
  });
}

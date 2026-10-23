import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/listening_learn.dart';
import 'package:chunkspoke_flutter/services/listening_store.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

int _dbCounter = 0;

AppDatabase _newDb() {
  final p = '${Directory.systemTemp.path}/listen_learn_${_dbCounter++}.db';
  final f = File(p);
  if (f.existsSync()) f.deleteSync();
  return AppDatabase(path: p);
}

Chunk _chunk(String id, {String? text}) => Chunk.fromJson({
      'id': id,
      'text': text ?? id,
      'type': 'content',
      'meaningCN': '释义 $id',
    });

ListeningChunk _lc(String id, {bool candidate = false, String? text}) =>
    ListeningChunk.fromJson({
      'id': id,
      'text': text ?? 'text $id',
      'meaningCN': '释义 $id',
      'candidate': candidate,
    });

ContentPack _content({int count = 3}) {
  final chunks = [for (var i = 0; i < count; i++) _chunk('c$i')];
  return ContentPack(version: 'test', levels: [
    Level(
      id: 'A',
      theme: 'Greetings',
      sceneImage: 'scene.png',
      chunks: chunks,
      sentences: [
        TargetSentence(
          id: 's_independent',
          text: 'other sentence',
          meaningCN: '另一句',
          chunkIds: ['c1'],
        ),
        TargetSentence(
          id: 's_with_c0',
          text: 'text c0',
          meaningCN: '含 c0 的句子',
          chunkIds: ['c0', 'c1'],
        ),
      ],
    ),
  ]);
}

class _Harness {
  final AppDatabase db;
  final ChunkProgressStore store;
  final ListeningStore listening;
  final ContentPack content;
  final List<String> events = [];
  final List<Map<String, dynamic>?> params = [];
  late final ListeningLearnService service;

  _Harness._(this.db, this.store, this.listening, this.content, String articleId,
      {int limit = 8}) {
    service = ListeningLearnService(
      store: store,
      listening: listening,
      content: content,
      articleId: articleId,
      logEvent: (name, [p]) async {
        events.add(name);
        params.add(p);
      },
      articleCollectLimit: limit,
    );
  }

  static _Harness create(
      {int count = 3,
      String articleId = 'L01',
      int limit = 8,
      DateTime? now}) {
    final db = _newDb();
    final clock = now ?? DateTime(2026, 10, 23, 9);
    final store = ChunkProgressStore(db, clock: () => clock);
    final kv = <String, String>{};
    final listening = ListeningStore(
      read: (k) => kv[k],
      write: (k, v) async => kv[k] = v,
      clock: () => clock,
    );
    return _Harness._(db, store, listening, _content(count: count), articleId,
        limit: limit);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('状态分派四分支', () {
    test('无行/learning/consolidating/reviewable/mastered 各自落位', () {
      expect(
          ListeningLearnService.dispatchFor(
              hasRow: false,
              state: ChunkAssetState.learning,
              learned: false),
          ListeningChunkAction.join);
      expect(
          ListeningLearnService.dispatchFor(
              hasRow: true,
              state: ChunkAssetState.learning,
              learned: false),
          ListeningChunkAction.continueLearning);
      // 只落账未学完：即使 consolidating 也继续学习，不伪造复习资格。
      expect(
          ListeningLearnService.dispatchFor(
              hasRow: true,
              state: ChunkAssetState.consolidating,
              learned: false),
          ListeningChunkAction.continueLearning);
      expect(
          ListeningLearnService.dispatchFor(
              hasRow: true,
              state: ChunkAssetState.consolidating,
              learned: true),
          ListeningChunkAction.reviewNow);
      for (final state in [
        ChunkAssetState.consolidated,
        ChunkAssetState.longTerm,
        ChunkAssetState.relearning,
      ]) {
        expect(
            ListeningLearnService.dispatchFor(
                hasRow: true, state: state, learned: true),
            ListeningChunkAction.reviewNow);
      }
      expect(
          ListeningLearnService.dispatchFor(
              hasRow: true,
              state: ChunkAssetState.mastered,
              learned: true),
          ListeningChunkAction.mastered);
    });

    test('resolve：无行→加入学习；候选/未知 id 不落库', () async {
      final h = _Harness.create();
      final join = await h.service.resolve(_lc('c0'));
      expect(join.action, ListeningChunkAction.join);
      expect(join.primaryLabel, '加入学习');
      expect(join.primaryEnabled, isTrue);

      final candidate =
          await h.service.resolve(_lc('lx_new', candidate: true));
      expect(candidate.action, ListeningChunkAction.candidate);
      expect(candidate.primaryLabel, '记录想学');
      expect(candidate.collectedCount, 0);

      final unknown = await h.service.resolve(_lc('nope'));
      expect(unknown.action, ListeningChunkAction.unavailable);
      expect(unknown.primaryLabel, isNull);
      expect(await h.db.getChunk('nope'), isNull);
    });
  });

  group('加入学习与 8 块上限', () {
    test('加入学习只落账：巩固中/明日到期/一条 scheduleReview；不强制进六步', () async {
      final h = _Harness.create();
      expect(await h.service.collect(_lc('c0')),
          ListeningCollectOutcome.collected);

      final row = await h.db.getChunk('c0');
      expect(row, isNotNull);
      expect(row!.assetState, ChunkAssetState.consolidating);
      expect(row.level, ChunkLevel.review);
      expect(row.dueDate, DateTime(2026, 10, 24, 9).millisecondsSinceEpoch);
      expect(h.listening.isCollected('c0'), isTrue);
      expect(h.listening.isSixStarted('c0'), isFalse);
      expect(await h.db.countSessionEvent('scheduleReview'), 1);
      expect(h.events, ['article_collect']);

      final r = await h.service.resolve(_lc('c0'));
      expect(r.action, ListeningChunkAction.continueLearning);
      expect(r.primaryLabel, '继续学习');
      // 重复收词不再落第二条。
      expect(await h.service.collect(_lc('c0')),
          ListeningCollectOutcome.already);
      expect(await h.db.countSessionEvent('scheduleReview'), 1);
      expect(h.events, ['article_collect']);
    });

    test('每篇 8 块上限：第 9 块置灰且不落账', () async {
      final h = _Harness.create(count: 9);
      for (var i = 0; i < 8; i++) {
        expect(await h.service.collect(_lc('c$i')),
            ListeningCollectOutcome.collected);
      }
      expect(h.listening.collectedCountFor('L01'), 8);

      expect(await h.service.collect(_lc('c8')),
          ListeningCollectOutcome.capReached);
      expect(await h.db.getChunk('c8'), isNull);
      expect(h.listening.isCollected('c8'), isFalse);
      expect(await h.db.countSessionEvent('scheduleReview'), 8);

      final r = await h.service.resolve(_lc('c8'));
      expect(r.action, ListeningChunkAction.join);
      expect(r.capReached, isTrue);
      expect(r.primaryEnabled, isFalse);
    });

    test('内容层更小的收词上限生效', () async {
      final h = _Harness.create(limit: 2);
      expect(await h.service.collect(_lc('c0')),
          ListeningCollectOutcome.collected);
      expect(await h.service.collect(_lc('c1')),
          ListeningCollectOutcome.collected);
      expect(await h.service.collect(_lc('c2')),
          ListeningCollectOutcome.capReached);
      expect(h.service.collectCap, 2);
    });
  });

  group('候选块不落库', () {
    test('collect 无效、wish 只记意愿：无 chunks 行、无 sessions 事件', () async {
      final h = _Harness.create();
      final candidate =
          _lc('lx_oat_milk', candidate: true, text: 'oat milk');

      expect(await h.service.collect(candidate),
          ListeningCollectOutcome.invalid);
      expect(await h.db.getChunk('lx_oat_milk'), isNull);
      expect(await h.db.allChunks(), isEmpty);

      expect(await h.service.wish(candidate), isTrue);
      expect(await h.service.wish(candidate), isFalse);
      expect(h.listening.wishCount('L01', 'oat milk'), 1);
      expect(h.events, ['candidate_wish']);
      expect(h.params.single, {'article': 'L01', 'text': 'oat milk'});

      // 红线：候选块绝不建块、绝不写学习会话轴。
      expect(await h.db.getChunk('lx_oat_milk'), isNull);
      expect(await h.db.sessionOutcomeCounts(), isEmpty);

      final r = await h.service.resolve(candidate);
      expect(r.action, ListeningChunkAction.candidate);
      expect(r.wished, isTrue);
      expect(r.primaryLabel, '已记录');
      expect(r.primaryEnabled, isFalse);
    });
  });

  group('学习完成与复习路径', () {
    test('真正走完六步后分派立即复习；六步/完成事件各一条', () async {
      final h = _Harness.create();
      await h.service.collect(_lc('c0'));
      await h.service.beginSix('c0');
      await h.service.beginSix('c0');
      expect(
          h.events.where((e) => e == 'collect_six_start').length, 1);

      // 只有 onDone 但六步未真正通过（如自由造句跳过）不算推动。
      await h.service.finishSix('c0');
      expect(h.listening.stats.converted, 0);
      expect(h.events.where((e) => e == 'collect_six_done'), isEmpty);

      // 模拟六步真正走完：非复习 speakSuccess 才被认作 learned。
      await h.store.applyEvent('c0', ChunkEvent.assembleCorrect);
      await h.store.applyEvent('c0', ChunkEvent.dragCorrect);
      await h.store.applyEvent('c0', ChunkEvent.accuracyPass, accuracy: 90);
      await h.store.applyEvent('c0', ChunkEvent.speakSuccess,
          accuracy: 95, fourStarsGreen: true, enforceFourStars: true);
      expect(
          await h.db.hasSessionOutcome('c0', 'speakSuccess', review: false),
          isTrue);

      final r = await h.service.resolve(_lc('c0'));
      expect(r.action, ListeningChunkAction.reviewNow);
      expect(r.primaryLabel, '立即复习');

      await h.service.finishSix('c0');
      await h.service.finishSix('c0');
      expect(h.events.where((e) => e == 'collect_six_done').length, 1);
      expect(h.listening.stats.sixStarted, 1);
      expect(h.listening.stats.converted, 1);

      // 未收词块不产生转化事件。
      await h.service.finishSix('c1');
      expect(h.events.where((e) => e == 'collect_six_done').length, 1);
    });

    test('六步场景 id 独立，复习走 PracticeSession.reviewLevel 目标句', () async {
      final h = _Harness.create();
      final six = h.service.sixLevel(_chunk('c0'));
      expect(six.id, 'listen_c0');
      expect(six.sentences.single.text, 'text c0');
      expect(six.sentences.single.chunkIds, ['c0', 'c1']);

      final review = h.service.reviewLevel(_chunk('c0'));
      expect(review.id, 'review');
      expect(review.sentences.single.text, 'text c0');
      expect(review.chunks.single.id, 'c0');
    });

    test('复习结果文案按前后快照升档/失败/未变三分支', () {
      const before = ChunkAssetSnapshot(
          state: ChunkAssetState.consolidating, stage: 0);
      const promoted = ChunkAssetSnapshot(
          state: ChunkAssetState.consolidated, stage: 1);
      const failed = ChunkAssetSnapshot(
          state: ChunkAssetState.relearning,
          stage: 0,
          returnState: ChunkAssetState.consolidating,
          returnStage: 0);
      const mastered = ChunkAssetSnapshot(
          state: ChunkAssetState.mastered, stage: 4);

      expect(ListeningLearnService.reviewOutcomeText(before, promoted),
          contains('升档「已巩固」'));
      expect(ListeningLearnService.reviewOutcomeText(before, failed),
          contains('需重修'));
      expect(ListeningLearnService.reviewOutcomeText(before, before),
          contains('状态未变'));
      expect(ListeningLearnService.reviewOutcomeText(promoted, mastered),
          contains('升档「已掌握」'));
    });

    test('重逢计数按篇累加，复习开始/完成各记一条事件', () async {
      final h = _Harness.create();
      await h.service.markReunion();
      await h.service.markReunion();
      expect(h.listening.reunionsFor('L01'), 2);

      await h.service.beginReview('c0');
      await h.service.finishReview('c0',
          completed: true, outcome: '复习通过 · 升档「已巩固」');
      expect(h.events, ['reunion_review_start', 'reunion_review_done']);
      expect(h.params.last, {
        'article': 'L01',
        'chunk': 'c0',
        'completed': true,
        'outcome': '复习通过 · 升档「已巩固」',
      });
    });
  });
}

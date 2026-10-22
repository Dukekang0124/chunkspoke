import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

int _dbCounter = 0;

class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

Future<(AppDatabase, ChunkProgressStore, _Clock)> _setup(
    DateTime start) async {
  final p = '${Directory.systemTemp.path}/review_engine_${_dbCounter++}.db';
  final f = File(p);
  if (f.existsSync()) f.deleteSync();
  final clock = _Clock(start);
  final db = AppDatabase(path: p, clock: clock.call);
  await db.db;
  return (db, ChunkProgressStore(db, clock: clock.call), clock);
}

/// 学完一块（未四星全绿）→ 资产巩固中，次日到期。
Future<void> _learn(ChunkProgressStore s, String key, {bool green = false}) async {
  await s.applyEvent(key, ChunkEvent.assembleCorrect);
  await s.applyEvent(key, ChunkEvent.dragCorrect);
  await s.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 90);
  await s.applyEvent(key, ChunkEvent.speakSuccess,
      accuracy: 95, fourStarsGreen: green);
}

Future<void> _reviewPass(ChunkProgressStore s, String key) =>
    s.applyEvent(key, ChunkEvent.speakSuccess, accuracy: 95, review: true);

Future<void> _reviewFail(ChunkProgressStore s, String key) =>
    s.applyEvent(key, ChunkEvent.speakFail, review: true);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('全周期：1d → 3d → 7d → 14d → 已掌握', () async {
    final (db, s, c) = await _setup(DateTime(2026, 1, 1, 9));
    await _learn(s, 'k', green: false);

    var r = await s.get('k');
    expect(r.assetState, ChunkAssetState.consolidating);
    expect(r.reviewStage, 0);
    expect(r.dueDate, DateTime(2026, 1, 2, 9).millisecondsSinceEpoch);
    expect(r.firstLearnedAt, DateTime(2026, 1, 1, 9).millisecondsSinceEpoch);

    // 未到期不入队。
    var q = await s.reviewQueue(c.now);
    expect(q.items, isEmpty);

    c.advance(const Duration(days: 1));
    q = await s.reviewQueue(c.now);
    expect(q.items.map((e) => e.chunkKey), ['k']);
    await _reviewPass(s, 'k');
    r = await s.get('k');
    expect(r.assetState, ChunkAssetState.consolidated);
    expect(r.reviewStage, 1);
    // 间隔从本次复习通过时刻起算：1/2 + 3d。
    expect(r.dueDate, DateTime(2026, 1, 5, 9).millisecondsSinceEpoch);
    expect(r.reviewCount, 1);
    expect(r.correctStreak, 1);
    expect(r.lastReviewAt, DateTime(2026, 1, 2, 9).millisecondsSinceEpoch);

    c.advance(const Duration(days: 3));
    await _reviewPass(s, 'k');
    r = await s.get('k');
    expect(r.assetState, ChunkAssetState.longTerm);
    expect(r.reviewStage, 2);
    expect(r.dueDate, DateTime(2026, 1, 12, 9).millisecondsSinceEpoch);

    c.advance(const Duration(days: 7));
    await _reviewPass(s, 'k');
    r = await s.get('k');
    expect(r.assetState, ChunkAssetState.longTerm);
    expect(r.reviewStage, 3);
    expect(r.dueDate, DateTime(2026, 1, 26, 9).millisecondsSinceEpoch);

    c.advance(const Duration(days: 14));
    await _reviewPass(s, 'k');
    r = await s.get('k');
    expect(r.assetState, ChunkAssetState.mastered);
    expect(r.reviewStage, ChunkAssetMachine.masteredStage);
    expect(r.dueDate, 0);
    expect(r.reviewCount, 4);
    expect(r.correctStreak, 4);

    q = await s.reviewQueue(c.now);
    expect(q.items, isEmpty);
    expect(await s.nextDueTimestamp(c.now.millisecondsSinceEpoch), isNull);
    await (await db.db).close();
  });

  test('四星全绿进已巩固首档：首次到期 = 次日（+1d，指令 N 修订）', () async {
    final (db, s, c) = await _setup(DateTime(2026, 2, 1, 9));
    await _learn(s, 'k', green: true);
    final r = await s.get('k');
    expect(r.assetState, ChunkAssetState.consolidated);
    expect(r.reviewStage, 0);
    expect(r.dueDate, DateTime(2026, 2, 2, 9).millisecondsSinceEpoch);
    // 次日到期即入队，不必等到第 3 天。
    c.advance(const Duration(days: 1));
    expect((await s.reviewQueue(c.now)).items.map((e) => e.chunkKey),
        contains('k'));
    await _reviewPass(s, 'k');
    final next = await s.get('k');
    expect(next.reviewStage, 1);
    expect(next.dueDate, DateTime(2026, 2, 5, 9).millisecondsSinceEpoch);
    await (await db.db).close();
  });

  group('复习失败 → 需重修 → 通过回原位', () {
    test('从巩固中失败 → 重修通过回巩固中', () async {
      final (db, s, c) = await _setup(DateTime(2026, 3, 1, 9));
      await _learn(s, 'k');
      final rc = await s.get('k');
      expect(rc.assetState, ChunkAssetState.consolidating);
      c.advance(const Duration(days: 1)); // 到期待复习
      await _reviewFail(s, 'k');
      final rf = await s.get('k');
      expect(rf.assetState, ChunkAssetState.relearning);
      expect(rf.reviewStage, 0);
      expect(rf.assetReturnState, ChunkAssetState.consolidating);
      expect(rf.assetReturnStage, 0);
      expect(rf.dueDate, c.now.add(const Duration(days: 1)).millisecondsSinceEpoch);
      expect(rf.failCount, 1);
      expect(rf.reviewCount, 1);
      c.advance(const Duration(days: 1)); // 需重修次日回访
      expect((await s.reviewQueue(c.now)).items.map((e) => e.chunkKey),
          contains('k'));
      await _reviewPass(s, 'k');
      final back = await s.get('k');
      expect(back.assetState, ChunkAssetState.consolidating);
      expect(back.reviewStage, 0);
      expect(back.assetReturnState, isNull);
      expect(back.correctStreak, 1);
      await (await db.db).close();
    });

    test('从已巩固失败 → 重修通过回已巩固', () async {
      final (db, s, c) = await _setup(DateTime(2026, 3, 1, 9));
      await _learn(s, 'k', green: true);
      final before = await s.get('k');
      expect(before.assetState, ChunkAssetState.consolidated);
      await _reviewFail(s, 'k');
      final rf = await s.get('k');
      expect(rf.assetState, ChunkAssetState.relearning);
      expect(rf.assetReturnState, ChunkAssetState.consolidated);
      expect(rf.assetReturnStage, 0);
      expect(rf.dueDate, c.now.add(const Duration(days: 1)).millisecondsSinceEpoch);
      await _reviewPass(s, 'k');
      final back = await s.get('k');
      expect(back.assetState, ChunkAssetState.consolidated);
      expect(back.reviewStage, 0);
      expect(back.assetReturnState, isNull);
      await (await db.db).close();
    });

    test('从长期失败 → 重修通过回长期原档', () async {
      final (db, s, c) = await _setup(DateTime(2026, 3, 1, 9));
      await _learn(s, 'k', green: true);
      c.advance(const Duration(days: 1));
      await _reviewPass(s, 'k'); // 首到期通过 → 已巩固 3 天档
      c.advance(const Duration(days: 3));
      await _reviewPass(s, 'k'); // → longTerm stage2
      await _reviewFail(s, 'k');
      final rf = await s.get('k');
      expect(rf.assetState, ChunkAssetState.relearning);
      expect(rf.assetReturnState, ChunkAssetState.longTerm);
      expect(rf.assetReturnStage, 2);
      await _reviewPass(s, 'k');
      final back = await s.get('k');
      expect(back.assetState, ChunkAssetState.longTerm);
      expect(back.reviewStage, 2);
      await (await db.db).close();
    });

    test('需重修再失败：保持需重修并保留回退点', () async {
      final (db, s, c) = await _setup(DateTime(2026, 4, 1, 9));
      await _learn(s, 'k', green: true);
      await _reviewFail(s, 'k');
      c.advance(const Duration(days: 1));
      await _reviewFail(s, 'k');
      final r = await s.get('k');
      expect(r.assetState, ChunkAssetState.relearning);
      expect(r.assetReturnState, ChunkAssetState.consolidated);
      expect(r.assetReturnStage, 0);
      expect(r.failCount, 2);
      expect(r.reviewCount, 2);
      expect(r.correctStreak, 0);
      await (await db.db).close();
    });
  });

  group('每日上限 20 与顺延', () {
    test('25 块到期 → 只取 20、顺延 5；当日不再发新题，次日顺延补上', () async {
      final (db, s, c) = await _setup(DateTime(2026, 5, 1, 9));
      for (var i = 0; i < 25; i++) {
        await _learn(s, 'k$i');
      }
      c.advance(const Duration(days: 1));
      var q = await s.reviewQueue(c.now);
      expect(q.dueTotal, 25);
      expect(q.items.length, 20);
      expect(q.deferred, 5);
      expect(q.reviewedToday, 0);
      expect(q.capped, isFalse);

      for (final row in q.items) {
        await _reviewPass(s, row.chunkKey);
      }
      q = await s.reviewQueue(c.now);
      expect(q.reviewedToday, 20);
      expect(q.remainingToday, 0);
      expect(q.items, isEmpty);
      expect(q.dueTotal, 5);
      expect(q.capped, isTrue);

      c.advance(const Duration(days: 1));
      q = await s.reviewQueue(c.now);
      expect(q.reviewedToday, 0);
      expect(q.items.length, 5);
      expect(q.capped, isFalse);
      await (await db.db).close();
    });

    test('优先级：同为到期时错得多的先排', () async {
      final (db, s, c) = await _setup(DateTime(2026, 6, 1, 9));
      await _learn(s, 'ok');
      await _learn(s, 'bad');
      c.advance(const Duration(days: 1));
      await _reviewFail(s, 'bad'); // fail=1，明天再到期
      c.advance(const Duration(days: 1));
      await _reviewFail(s, 'bad'); // fail=2，明天再到期
      await _reviewFail(s, 'ok'); // fail=1，明天再到期
      c.advance(const Duration(days: 1));
      final q = await s.reviewQueue(c.now);
      expect(q.items.map((e) => e.chunkKey).toList(), ['bad', 'ok']);
      await (await db.db).close();
    });
  });

  group('进度保护', () {
    test('学习期重复 scheduleReview 不重置既有复习进度', () async {
      final (db, s, c) = await _setup(DateTime(2026, 7, 1, 9));
      await _learn(s, 'k');
      c.advance(const Duration(days: 1));
      await _reviewPass(s, 'k'); // 已巩固，3 天档
      final before = await s.get('k');
      expect(before.assetState, ChunkAssetState.consolidated);

      await s.applyEvent('k', ChunkEvent.scheduleReview); // 场景内再次跳过
      final after = await s.get('k');
      expect(after.assetState, ChunkAssetState.consolidated);
      expect(after.reviewStage, before.reviewStage);
      expect(after.dueDate, before.dueDate);
      await (await db.db).close();
    });

    test('复习中跳过 deferReview：不降档，只顺延一天', () async {
      final (db, s, c) = await _setup(DateTime(2026, 8, 1, 9));
      await _learn(s, 'k', green: true);
      c.advance(const Duration(days: 3));
      await s.applyEvent('k', ChunkEvent.deferReview);
      final r = await s.get('k');
      expect(r.assetState, ChunkAssetState.consolidated);
      expect(r.reviewStage, 0);
      expect(r.dueDate, c.now.add(const Duration(days: 1)).millisecondsSinceEpoch);
      await (await db.db).close();
    });
  });

  test('exportAssets 全量导出（状态/档位/回退点/计数）', () async {
    final (db, s, c) = await _setup(DateTime(2026, 9, 1, 9));
    await _learn(s, 'k', green: true);
    await _reviewFail(s, 'k');
    final rows = await s.exportAssets();
    final m = rows.singleWhere((e) => e['chunk_key'] == 'k');
    expect(m['asset_state'], 'relearning');
    expect(m['asset_label'], '需重修');
    expect(m['stage'], 0);
    expect(m['return_state'], 'consolidated');
    expect(m['return_stage'], 0);
    expect(m['review_count'], 1);
    expect(m['fail_count'], 1);
    expect(m['first_learned_at'], DateTime(2026, 9, 1, 9).millisecondsSinceEpoch);
    expect(m['last_review_at'], DateTime(2026, 9, 1, 9).millisecondsSinceEpoch);
    await (await db.db).close();
  });
}

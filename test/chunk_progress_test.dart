import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

int _dbCounter = 0;
// 每用例独立 temp 文件库（先删残留，避免跨运行复用旧数据互相污染）。
AppDatabase _newDb() {
  final p = '${Directory.systemTemp.path}/cp_test_${_dbCounter++}.db';
  final f = File(p);
  if (f.existsSync()) f.deleteSync();
  return AppDatabase(path: p);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('L1 -> L4 path, accuracy recorded, L4 fail no longer demotes (single exit)', () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);

    await store.applyEvent('k', ChunkEvent.assembleCorrect);
    expect((await store.get('k')).level, ChunkLevel.l2);

    await store.applyEvent('k', ChunkEvent.dragCorrect);
    expect((await store.get('k')).level, ChunkLevel.l3);

    await store.applyEvent('k', ChunkEvent.accuracyPass, accuracy: 80);
    expect((await store.get('k')).level, ChunkLevel.l4);
    expect((await store.get('k')).lastScore, 80);

    // 失败不再自动降级：保持 L4（单一出口=跳过/答案）。
    // failCount 记录失败次数，供 AI 周报 top-fail 统计（M7），与「是否降级」解耦。
    await store.applyEvent('k', ChunkEvent.speakFail);
    expect((await store.get('k')).level, ChunkLevel.l4);
    expect((await store.get('k')).failCount, 1);

    await store.applyEvent('k', ChunkEvent.speakFail);
    expect((await store.get('k')).level, ChunkLevel.l4);
    expect((await store.get('k')).failCount, 2);

    // 重新走通 → speakSuccess 达标即 mastered（关卡轴），同时资产进入巩固中，次日复访。
    await store.applyEvent('k', ChunkEvent.accuracyPass, accuracy: 90);
    await store.applyEvent('k', ChunkEvent.speakSuccess, accuracy: 95);
    final row = await store.get('k');
    expect(row.level, ChunkLevel.mastered);
    expect(row.assetState, ChunkAssetState.consolidating);
    expect(row.dueDate, greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

  test('P0-2 集成：掌握状态落盘，重开后仍保留（顶/底圆环同源）', () async {
    _dbCounter++;
    final p = '${Directory.systemTemp.path}/cp_persist_$_dbCounter.db';
    final f = File(p);
    if (f.existsSync()) f.deleteSync();

    final db1 = AppDatabase(path: p);
    await db1.db;
    final s1 = ChunkProgressStore(db1);
    // 走完 happy path → mastered（l2OneTry=1、accuracy≥80）。
    await s1.applyEvent('a', ChunkEvent.assembleCorrect);
    await s1.applyEvent('a', ChunkEvent.dragCorrect);
    await s1.applyEvent('a', ChunkEvent.accuracyPass, accuracy: 90);
    await s1.applyEvent('a', ChunkEvent.speakSuccess, accuracy: 95);
    expect(ChunkProgressStore.isMastered(await s1.get('a')), isTrue);

    // 杀进程重开：关闭原连接、用同路径新实例读取（模拟重启）。
    await (await db1.db).close();
    final db2 = AppDatabase(path: p);
    await db2.db;
    final s2 = ChunkProgressStore(db2);
    expect(ChunkProgressStore.isMastered(await s2.get('a')), isTrue);
    expect((await s2.allMasteredKeys()).length, 1); // 同数据源：重开圆环仍显示 1
  });

  test('due chunks query returns chunks in review past their due date', () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);

    await store.applyEvent('a', ChunkEvent.assembleCorrect);
    await store.applyEvent('a', ChunkEvent.dragCorrect);
    await store.applyEvent('a', ChunkEvent.accuracyPass, accuracy: 75);
    await store.applyEvent('a', ChunkEvent.speakSuccess);

    final due = await store.dueChunkKeys(
        DateTime.now().add(const Duration(days: 2)).millisecondsSinceEpoch);
    expect(due, contains('a'));
  });

  // —— M7 掌握硬门槛边界 ——
  Future<void> toL4(ChunkProgressStore store, String k,
      {bool oneTry = true, int l3acc = 90}) async {
    await store.applyEvent(k, ChunkEvent.assembleCorrect); // l1->l2
    if (!oneTry) {
      await store.applyEvent(k, ChunkEvent.dragWrong); // 拖错 → l2OneTry=0（随后 dragCorrect 补回 1，见 §4.3）
    }
    await store.applyEvent(k, ChunkEvent.dragCorrect); // l2->l3
    await store.applyEvent(k, ChunkEvent.accuracyPass, accuracy: l3acc); // l3->l4
  }

  test('L4 命中率 79% 未达门槛 → 进 review；80% → mastered', () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await toL4(store, 'k', oneTry: true);
    await store.applyEvent('k', ChunkEvent.speakSuccess, accuracy: 79);
    expect((await store.get('k')).level, ChunkLevel.review);
    expect(ChunkProgressStore.isMastered(await store.get('k')), isFalse);

    final db2 = AppDatabase(path: inMemoryDatabasePath);
    await db2.db;
    final store2 = ChunkProgressStore(db2);
    await toL4(store2, 'k', oneTry: true);
    await store2.applyEvent('k', ChunkEvent.speakSuccess, accuracy: 80);
    expect((await store2.get('k')).level, ChunkLevel.mastered);
    expect(ChunkProgressStore.isMastered(await store2.get('k')), isTrue);
  });

  test('L2 先错后对 → 拖对补回 l2OneTry=1 → L4 90% 可 mastered（§4.3 毒块已恢复）',
      () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await toL4(store, 'k', oneTry: false);
    expect((await store.get('k')).l2OneTry, 1); // 拖对即补回“一次过”
    await store.applyEvent('k', ChunkEvent.speakSuccess, accuracy: 95);
    expect((await store.get('k')).level, ChunkLevel.mastered);
    expect(ChunkProgressStore.isMastered(await store.get('k')), isTrue);
  });

  test('scheduleReview → 置 review + 次日到期（§4.2 真实出口）', () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await toL4(store, 'k', oneTry: true);
    await store.applyEvent('k', ChunkEvent.scheduleReview);
    final row = await store.get('k');
    expect(row.level, ChunkLevel.review);
    expect(row.dueDate, greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

  test('L4 无 Key 自评路径：l2OneTry=1 + selfEval → mastered；未自评 → review',
      () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await toL4(store, 'k', oneTry: true);
    await store.applyEvent('k', ChunkEvent.speakSuccess, selfEval: false);
    expect((await store.get('k')).level, ChunkLevel.review);

    final db2 = AppDatabase(path: inMemoryDatabasePath);
    await db2.db;
    final store2 = ChunkProgressStore(db2);
    await toL4(store2, 'k', oneTry: true);
    await store2.applyEvent('k', ChunkEvent.speakSuccess, selfEval: true);
    final r = await store2.get('k');
    expect(r.level, ChunkLevel.mastered);
    expect(r.l4SelfEval, isTrue);
    expect(ChunkProgressStore.isMastered(r), isTrue);
  });

  test('allMasteredKeys 仅返回 mastered 词块', () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await toL4(store, 'a', oneTry: true);
    await store.applyEvent('a', ChunkEvent.speakSuccess, accuracy: 90);
    await toL4(store, 'b', oneTry: true);
    await store.applyEvent('b', ChunkEvent.speakSuccess, accuracy: 79); // review
    final m = await store.allMasteredKeys();
    expect(m, contains('a'));
    expect(m, isNot(contains('b')));
  });

  test('N-4 到期队列：T0 先排，且日上限在排序之后才截断', () async {
    final db = _newDb();
    await db.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    Future<void> seed(String key, int dueAgoMs, {int fail = 0}) => db.upsertChunk(
          ChunkRow(
            chunkKey: key,
            level: ChunkLevel.l4,
            dueDate: now - dueAgoMs,
            failCount: fail,
            lastScore: 90,
            reviewStage: 1,
            assetState: ChunkAssetState.consolidating,
          ),
        );
    // 普通块欠账更多、排得更久，若按 DB 原序会先占满上限。
    await seed('n1', 9000, fail: 5);
    await seed('n2', 8000, fail: 4);
    await seed('t1', 3000);
    await seed('t2', 2000);

    final plain = await ChunkProgressStore(db).reviewQueue(DateTime.now(), cap: 2);
    expect(plain.items.map((r) => r.chunkKey), ['n1', 'n2']);

    final core = ChunkProgressStore(db, tierOf: (k) => k.startsWith('t') ? 'T0' : 'T2')
        .reviewQueue(DateTime.now(), cap: 2);
    final q = await core;
    expect(q.items.map((r) => r.chunkKey), ['t1', 't2'],
        reason: 'T0 到期块不能被普通块的欠账数挤出当日上限');
    expect(q.dueTotal, 4);
  });
}

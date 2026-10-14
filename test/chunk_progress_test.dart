import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('L1 -> L4 path, accuracy recorded, L4 fail x2 demotes to L3', () async {
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

    // First fail: stays L4, counts 1.
    await store.applyEvent('k', ChunkEvent.speakFail);
    expect((await store.get('k')).level, ChunkLevel.l4);
    expect((await store.get('k')).failCount, 1);

    // Second fail: demote to L3, counter reset.
    await store.applyEvent('k', ChunkEvent.speakFail);
    expect((await store.get('k')).level, ChunkLevel.l3);
    expect((await store.get('k')).failCount, 0);

    // Recover to L4 then succeed -> review with a due date queued.
    await store.applyEvent('k', ChunkEvent.accuracyPass, accuracy: 90);
    await store.applyEvent('k', ChunkEvent.speakSuccess);
    final row = await store.get('k');
    expect(row.level, ChunkLevel.review);
    expect(row.dueDate, greaterThan(0));
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
  Future<void> _toL4(ChunkProgressStore store, String k,
      {bool oneTry = true, int l3acc = 90}) async {
    await store.applyEvent(k, ChunkEvent.assembleCorrect); // l1->l2
    if (!oneTry) {
      await store.applyEvent(k, ChunkEvent.dragWrong); // l2 stays, l2OneTry=0
    }
    await store.applyEvent(k, ChunkEvent.dragCorrect); // l2->l3
    await store.applyEvent(k, ChunkEvent.accuracyPass, accuracy: l3acc); // l3->l4
  }

  test('L4 命中率 79% 未达门槛 → 进 review；80% → mastered', () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await _toL4(store, 'k', oneTry: true);
    await store.applyEvent('k', ChunkEvent.speakSuccess, accuracy: 79);
    expect((await store.get('k')).level, ChunkLevel.review);
    expect(ChunkProgressStore.isMastered(await store.get('k')), isFalse);

    final db2 = AppDatabase(path: inMemoryDatabasePath);
    await db2.db;
    final store2 = ChunkProgressStore(db2);
    await _toL4(store2, 'k', oneTry: true);
    await store2.applyEvent('k', ChunkEvent.speakSuccess, accuracy: 80);
    expect((await store2.get('k')).level, ChunkLevel.mastered);
    expect(ChunkProgressStore.isMastered(await store2.get('k')), isTrue);
  });

  test('L2 两次过（先错后对）→ l2OneTry=0 → 即使 L4 90% 也不 mastered', () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await _toL4(store, 'k', oneTry: false);
    final row = await store.get('k');
    expect(row.l2OneTry, 0);
    await store.applyEvent('k', ChunkEvent.speakSuccess, accuracy: 95);
    expect((await store.get('k')).level, ChunkLevel.review);
    expect(ChunkProgressStore.isMastered(await store.get('k')), isFalse);
  });

  test('L4 无 Key 自评路径：l2OneTry=1 + selfEval → mastered；未自评 → review',
      () async {
    final db = _newDb();
    await db.db;
    final store = ChunkProgressStore(db);
    await _toL4(store, 'k', oneTry: true);
    await store.applyEvent('k', ChunkEvent.speakSuccess, selfEval: false);
    expect((await store.get('k')).level, ChunkLevel.review);

    final db2 = AppDatabase(path: inMemoryDatabasePath);
    await db2.db;
    final store2 = ChunkProgressStore(db2);
    await _toL4(store2, 'k', oneTry: true);
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
    await _toL4(store, 'a', oneTry: true);
    await store.applyEvent('a', ChunkEvent.speakSuccess, accuracy: 90);
    await _toL4(store, 'b', oneTry: true);
    await store.applyEvent('b', ChunkEvent.speakSuccess, accuracy: 79); // review
    final m = await store.allMasteredKeys();
    expect(m, contains('a'));
    expect(m, isNot(contains('b')));
  });
}

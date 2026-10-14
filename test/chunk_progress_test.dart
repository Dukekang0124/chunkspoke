import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('L1 -> L4 path, accuracy recorded, L4 fail x2 demotes to L3', () async {
    final db = AppDatabase(path: inMemoryDatabasePath);
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
    final db = AppDatabase(path: inMemoryDatabasePath);
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
}

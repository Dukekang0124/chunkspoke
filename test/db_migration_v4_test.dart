import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

/// 波 1-A：v3 → v4 迁移只增列 + 幂等回填，绝不丢旧进度。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v3 旧库升级到 v4：资产状态回填、首学时间取最早会话、review 列默认 0', () async {
    final path = '${Directory.systemTemp.path}/mig_v4_${DateTime.now().microsecondsSinceEpoch}.db';
    final f = File(path);
    if (f.existsSync()) f.deleteSync();

    final old = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, v) async {
            await db.execute(
                'CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
            await db.execute('''
              CREATE TABLE chunks (
                chunk_key TEXT PRIMARY KEY,
                level INTEGER NOT NULL,
                due_date INTEGER NOT NULL,
                fail_count INTEGER NOT NULL,
                last_score INTEGER NOT NULL,
                l2_one_try INTEGER NOT NULL DEFAULT -1,
                l4_self_eval INTEGER NOT NULL DEFAULT 0,
                review_stage INTEGER NOT NULL DEFAULT 0
              )''');
            await db.execute('''
              CREATE TABLE sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chunk_key TEXT NOT NULL,
                ts INTEGER NOT NULL,
                outcome TEXT NOT NULL,
                score INTEGER NOT NULL
              )''');
          },
        ));
    Future<void> chunk(String key, ChunkLevel level, int stage) => old.insert(
        'chunks', {
          'chunk_key': key,
          'level': level.index,
          'due_date': 123,
          'fail_count': 0,
          'last_score': 88,
          'l2_one_try': 1,
          'l4_self_eval': 0,
          'review_stage': stage,
        });
    await chunk('m', ChunkLevel.mastered, 2);
    await chunk('r0', ChunkLevel.review, 0);
    await chunk('r2', ChunkLevel.review, 2);
    await chunk('l', ChunkLevel.l1, 0);
    Future<void> session(String key, int ts) => old.insert('sessions', {
          'chunk_key': key,
          'ts': ts,
          'outcome': 'assembleCorrect',
          'score': 0,
        });
    await session('m', 200);
    await session('m', 100);
    await session('r2', 300);
    await old.close();

    final db = AppDatabase(path: path);
    final store = ChunkProgressStore(db, clock: () => DateTime(2026, 1, 1));

    final m = await store.get('m');
    expect(m.level, ChunkLevel.mastered);
    expect(m.assetState, ChunkAssetState.mastered);
    expect(m.reviewStage, ChunkAssetMachine.masteredStage);
    expect(m.firstLearnedAt, 100);

    final r0 = await store.get('r0');
    expect(r0.assetState, ChunkAssetState.consolidating);
    expect(r0.reviewStage, 0);

    final r2 = await store.get('r2');
    expect(r2.assetState, ChunkAssetState.longTerm);
    expect(r2.reviewStage, 2);
    expect(r2.firstLearnedAt, 300);

    final l = await store.get('l');
    expect(l.assetState, ChunkAssetState.learning);
    expect(l.reviewStage, 0);
    expect(l.firstLearnedAt, 0);

    // 旧「已掌握」块不再涌入复习队列；旧 review 块按原档位继续排队。
    final due = await store.dueChunkKeys(1 << 40);
    expect(due, isNot(contains('m')));
    expect(due, containsAll(['r0', 'r2']));

    // sessions 新列默认 0，旧记录语义不变。
    final raw = await (await db.db).query('sessions', orderBy: 'id ASC');
    expect(raw.length, 3);
    expect(raw.every((r) => r['review'] == 0), isTrue);
    await (await db.db).close();
  });

  test('v4 全新建库：列齐全，默认值为新学', () async {
    final path =
        '${Directory.systemTemp.path}/mig_v4_fresh_${DateTime.now().microsecondsSinceEpoch}.db';
    final db = AppDatabase(path: path);
    await db.upsertChunk(const ChunkRow(
      chunkKey: 'k',
      level: ChunkLevel.l1,
      dueDate: 0,
      failCount: 0,
      lastScore: 0,
    ));
    final r = await db.getChunk('k');
    expect(r!.assetState, ChunkAssetState.learning);
    expect(r.assetReturnState, isNull);
    expect(r.assetReturnStage, -1);
    expect(r.firstLearnedAt, 0);
    expect(r.reviewCount, 0);
    expect(r.correctStreak, 0);
    expect(r.lastReviewAt, 0);
    await (await db.db).close();
    File(path).deleteSync();
  });
}

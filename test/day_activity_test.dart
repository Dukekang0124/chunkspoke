import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

/// 1.5.9 学习日历：三数口径（见 `验收-v1.5.9/学习日历-口径-1.5.9.md`）。
///
/// 只读既有 `chunks.first_learned_at` + `sessions(ts, outcome, review)`，
/// 不建新表；按**本地日**分桶。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(path: inMemoryDatabasePathForTest());
  });

  tearDown(() async {
    await (await db.db).close();
  });

  Future<void> chunk(String key, {int firstLearnedAt = 0}) async {
    await db.upsertChunk(ChunkRow(
      chunkKey: key,
      level: ChunkLevel.review,
      dueDate: 0,
      failCount: 0,
      lastScore: 0,
      firstLearnedAt: firstLearnedAt,
    ));
  }

  test('三数各自计数：新学块 / 复习次数 / 通过次数', () async {
    final d = DateTime(2026, 10, 29, 10);
    final ms = d.millisecondsSinceEpoch;

    await chunk('a', firstLearnedAt: ms);
    await chunk('b', firstLearnedAt: ms);
    await chunk('c'); // 未学完，不计

    await db.insertSession('a', 'speakSuccess', 0, ts: ms);
    await db.insertSession('a', 'accuracyPass', 0, ts: ms);
    await db.insertSession('a', 'assembleCorrect', 0, ts: ms);
    await db.insertSession('a', 'speakSuccess', 0, review: true, ts: ms);

    final map = await db.dayActivityBetween(
        DateTime(2026, 10, 1), DateTime(2026, 10, 31));
    final day = map['2026-10-29']!;
    expect(day.newChunks, 2);
    expect(day.reviews, 1, reason: '只有 review=1 的事件计入复习');
    expect(day.passes, 3, reason: 'speakSuccess ×2 + accuracyPass ×1');
  });

  test('按本地日分桶，跨日不串；无活动的日不出现', () async {
    final d1 = DateTime(2026, 10, 28, 23, 59);
    final d2 = DateTime(2026, 10, 29, 0, 1);
    await db.insertSession('a', 'speakSuccess', 0, ts: d1.millisecondsSinceEpoch);
    await db.insertSession('a', 'speakSuccess', 0, ts: d2.millisecondsSinceEpoch);

    final map = await db.dayActivityBetween(
        DateTime(2026, 10, 1), DateTime(2026, 10, 31));
    expect(map.keys.toSet(), {'2026-10-28', '2026-10-29'});
    expect(map['2026-10-28']!.passes, 1);
    expect(map['2026-10-29']!.passes, 1);
  });

  test('范围外的事件不返回（按本地日边界闭区间）', () async {
    final inside = DateTime(2026, 10, 1, 0, 0);
    final before = DateTime(2026, 9, 30, 23, 59);
    final after = DateTime(2026, 11, 1, 0, 0);
    for (final t in [before, inside, after]) {
      await db.insertSession(
          'a', 'speakSuccess', 0, ts: t.millisecondsSinceEpoch);
    }
    final map = await db.dayActivityBetween(
        DateTime(2026, 10, 1), DateTime(2026, 10, 31));
    expect(map.keys.toList(), ['2026-10-01']);
  });

  test('first_learned_at = 0（未完成）不计入新学', () async {
    await chunk('a');
    await db.insertSession('a', 'assembleCorrect', 0,
        ts: DateTime(2026, 10, 29, 9).millisecondsSinceEpoch);
    final map = await db.dayActivityBetween(
        DateTime(2026, 10, 29), DateTime(2026, 10, 29));
    expect(map['2026-10-29']!.newChunks, 0);
    expect(map['2026-10-29']!.passes, 0, reason: 'assembleCorrect 不算通过');
  });

  test('dayKey 补零且稳定', () {
    expect(dayKey(DateTime(2026, 1, 5)), '2026-01-05');
    expect(dayKey(DateTime(2026, 12, 31)), '2026-12-31');
  });
}

/// 测试用内存库路径（sqflite_ffi 约定）。
String inMemoryDatabasePathForTest() => inMemoryDatabasePath;

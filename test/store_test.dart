import 'package:chunkspoke_web/data/vocab.dart';
import 'package:chunkspoke_web/storage/records.dart';
import 'package:chunkspoke_web/storage/schema.dart';
import 'package:chunkspoke_web/storage/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema：四 store、version 1、chunks 四索引', () {
    expect(kDbVersion, 1);
    expect(kAllStores, ['chunks', 'kv', 'events', 'meta']);
    expect(kChunkKeyPath, 'id');
    expect(kChunkIndexes.keys, ['dueDate', 'tier', 'assetState', 'updatedAt']);
    expect(kEventKeyPath, 'event_id');
    expect(kEventIndexAt, 'at');
  });

  test('行往返：ChunkRecord.toMap/fromMap 逐字段不变', () {
    const row = ChunkRecord(
      id: 'get up',
      tier: 'T0',
      assetState: AssetState.relearning,
      assetReturnStateIndex: 2,
      assetReturnStage: 3,
      reviewStage: 1,
      dueDate: 1730000000000,
      lastReviewAt: 1729990000000,
      correctStreak: 2,
      updatedAt: 1729990000000,
      l4SelfEval: 1,
      l2OneTry: 1,
      lastScore: 88,
      orphan: true,
    );
    final back = ChunkRecord.fromMap(row.toMap());
    expect(back.toMap(), equals(row.toMap()));
    expect(back.assetReturnState, AssetState.consolidated);
  });

  test('内存仓储：读写、事件去重、清空不动 meta', () async {
    final store = MemoryProgressStore();
    await store.open();
    await store.putChunks(const [
      ChunkRecord(id: 'a', tier: 'T0', assetState: AssetState.learning),
    ]);
    expect((await store.loadChunks()).keys, ['a']);

    await store.setKv(kKvKeyStats, {'streak': 3});
    expect((await store.getKv(kKvKeyStats))['streak'], 3);

    await store.putEvents(const [
      EventRecord(eventId: 'e1', at: 1, name: 'review_eval'),
    ]);
    await store.putEvents(const [
      EventRecord(eventId: 'e1', at: 2, name: 'review_eval'),
    ]);
    final events = await store.loadEvents();
    expect(events.length, 1);
    expect(events.single.at, 2);

    await store.setMeta('deviceId', 'a1b2c3');
    await store.clearLearningData();
    expect(await store.loadChunks(), isEmpty);
    expect(await store.getKv(kKvKeyStats), isEmpty);
    expect(await store.loadEvents(), isEmpty);
    expect(await store.getMeta('deviceId'), 'a1b2c3');
  });
}

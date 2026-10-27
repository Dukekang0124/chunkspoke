import 'records.dart';

/// 本机进度仓储（Web 侧替代 App 的 sqflite）。
///
/// 实现必须满足：单次写操作一个事务；`clearLearningData` 只清 chunks/kv/events，
/// 不动 meta（导入前快照与设备别名要能留下来）。
abstract class ProgressStore {
  Future<void> open();

  Future<Map<String, ChunkRecord>> loadChunks();
  Future<void> putChunks(Iterable<ChunkRecord> rows);

  Future<Map<String, Object?>> getKv(String key);
  Future<void> setKv(String key, Map<String, Object?> value);

  Future<List<EventRecord>> loadEvents();
  Future<void> putEvents(Iterable<EventRecord> rows);

  Future<Object?> getMeta(String key);
  Future<void> setMeta(String key, Object? value);

  Future<void> clearLearningData();
}

/// 纯内存实现：单测与预置阶段的界面装配用，进程结束即丢。
class MemoryProgressStore implements ProgressStore {
  final Map<String, ChunkRecord> _chunks = {};
  final Map<String, Map<String, Object?>> _kv = {};
  final Map<String, EventRecord> _events = {};
  final Map<String, Object?> _meta = {};

  @override
  Future<void> open() async {}

  @override
  Future<Map<String, ChunkRecord>> loadChunks() async => Map.of(_chunks);

  @override
  Future<void> putChunks(Iterable<ChunkRecord> rows) async {
    for (final r in rows) {
      _chunks[r.id] = r;
    }
  }

  @override
  Future<Map<String, Object?>> getKv(String key) async => Map.of(_kv[key] ?? const {});

  @override
  Future<void> setKv(String key, Map<String, Object?> value) async {
    _kv[key] = Map.of(value);
  }

  @override
  Future<List<EventRecord>> loadEvents() async {
    final list = _events.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  @override
  Future<void> putEvents(Iterable<EventRecord> rows) async {
    for (final r in rows) {
      _events[r.eventId] = r;
    }
  }

  @override
  Future<Object?> getMeta(String key) async => _meta[key];

  @override
  Future<void> setMeta(String key, Object? value) async {
    _meta[key] = value;
  }

  @override
  Future<void> clearLearningData() async {
    _chunks.clear();
    _kv.clear();
    _events.clear();
  }
}

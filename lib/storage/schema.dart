/// IndexedDB 库结构与版本常量。与方案 v1.1 §六 schema 表一一对应。
const String kDbName = 'chunkspoke_web';
const int kDbVersion = 1;

const String kStoreChunks = 'chunks';
const String kStoreKv = 'kv';
const String kStoreEvents = 'events';
const String kStoreMeta = 'meta';

const List<String> kAllStores = [kStoreChunks, kStoreKv, kStoreEvents, kStoreMeta];

/// chunks: keyPath = id，索引 dueDate / tier / assetState / updatedAt
const String kChunkKeyPath = 'id';
const Map<String, String> kChunkIndexes = {
  'dueDate': 'dueDate',
  'tier': 'tier',
  'assetState': 'assetState',
  'updatedAt': 'updatedAt',
};

/// kv: keyPath = key，一条 stats、一条 settings（结构化对象）
const String kKvKeyPath = 'key';
const String kKvKeyStats = 'stats';
const String kKvKeySettings = 'settings';

/// events: keyPath = event_id，索引 at
const String kEventKeyPath = 'event_id';
const String kEventIndexAt = 'at';

/// meta: keyPath = key（installedContentPack / deviceId / lastImportAt / pre_import_snapshot）
const String kMetaKeyPath = 'key';

/// 事件环形缓冲上限，与 App analytics_events 的 500 条一致。
const int kEventBufferLimit = 500;

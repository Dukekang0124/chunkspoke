import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../data/review_rules.dart';
import 'records.dart';
import 'schema.dart';
import 'store.dart';

ProgressStore createProgressStore() => IdbProgressStore();

class IdbProgressStore implements ProgressStore {
  web.IDBDatabase? _db;

  @override
  Future<void> open() async {
    await _database();
  }

  Future<web.IDBDatabase> _database() async {
    final cached = _db;
    if (cached != null) return cached;
    final request = web.window.indexedDB.open(kDbName, kDbVersion);
    final done = Completer<web.IDBDatabase>();
    request.onupgradeneeded = ((web.Event _) {
      _installSchema(request.result as web.IDBDatabase);
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      _db = db;
      if (!done.isCompleted) done.complete(db);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('打开 IndexedDB 失败：${request.error?.message}'));
      }
    }).toJS;
    return done.future;
  }

  void _installSchema(web.IDBDatabase db) {
    if (!db.objectStoreNames.contains(kStoreChunks)) {
      final store = db.createObjectStore(
        kStoreChunks,
        web.IDBObjectStoreParameters(keyPath: kChunkKeyPath.toJS, autoIncrement: false),
      );
      for (final e in kChunkIndexes.entries) {
        store.createIndex(e.key, e.value.toJS);
      }
    }
    if (!db.objectStoreNames.contains(kStoreKv)) {
      db.createObjectStore(
        kStoreKv,
        web.IDBObjectStoreParameters(keyPath: kKvKeyPath.toJS, autoIncrement: false),
      );
    }
    if (!db.objectStoreNames.contains(kStoreEvents)) {
      final store = db.createObjectStore(
        kStoreEvents,
        web.IDBObjectStoreParameters(keyPath: kEventKeyPath.toJS, autoIncrement: false),
      );
      store.createIndex(kEventIndexAt, 'at'.toJS);
    }
    if (!db.objectStoreNames.contains(kStoreMeta)) {
      db.createObjectStore(
        kStoreMeta,
        web.IDBObjectStoreParameters(keyPath: kMetaKeyPath.toJS, autoIncrement: false),
      );
    }
  }

  Future<Object?> _await(web.IDBRequest request) {
    final done = Completer<Object?>();
    request.onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete(request.result.dartify());
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(StateError('IndexedDB 请求失败：${request.error?.message}'));
      }
    }).toJS;
    return done.future;
  }

  @override
  Future<Map<String, ChunkRecord>> loadChunks() async {
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreChunks.toJS].toJS, 'readonly');
    final rows = await _await(tx.objectStore(kStoreChunks).getAll());
    final out = <String, ChunkRecord>{};
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        final record = ChunkRecord.fromMap(row.map((k, v) => MapEntry(k.toString(), v)));
        out[record.id] = record;
      }
    }
    return out;
  }

  @override
  Future<void> putChunks(Iterable<ChunkRecord> rows) async {
    final list = rows.toList();
    if (list.isEmpty) return;
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreChunks.toJS].toJS, 'readwrite');
    final store = tx.objectStore(kStoreChunks);
    final pending = <Future<Object?>>[
      for (final r in list) _await(store.put(r.toMap().jsify())),
    ];
    await Future.wait(pending);
  }

  @override
  Future<Map<String, Object?>> getKv(String key) async {
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreKv.toJS].toJS, 'readonly');
    final row = await _await(tx.objectStore(kStoreKv).get(key.toJS));
    if (row is! Map) return {};
    final value = row['value'];
    if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
    return {};
  }

  @override
  Future<void> setKv(String key, Map<String, Object?> value) async {
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreKv.toJS].toJS, 'readwrite');
    await _await(
      tx.objectStore(kStoreKv).put(<String, Object?>{'key': key, 'value': value}.jsify()),
    );
  }

  @override
  Future<List<EventRecord>> loadEvents() async {
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreEvents.toJS].toJS, 'readonly');
    final rows = await _await(tx.objectStore(kStoreEvents).getAll());
    if (rows is! List) return const [];
    final events = <EventRecord>[
      for (final row in rows)
        if (row is Map) EventRecord.fromMap(row.map((k, v) => MapEntry(k.toString(), v))),
    ];
    return trimEvents(events);
  }

  @override
  Future<void> putEvents(Iterable<EventRecord> rows) async {
    final list = rows.toList();
    if (list.isEmpty) return;
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreEvents.toJS].toJS, 'readwrite');
    final store = tx.objectStore(kStoreEvents);
    await Future.wait([
      for (final e in list) _await(store.put(e.toMap().jsify())),
    ]);
  }

  @override
  Future<Object?> getMeta(String key) async {
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreMeta.toJS].toJS, 'readonly');
    final row = await _await(tx.objectStore(kStoreMeta).get(key.toJS));
    return row is Map ? row['value'] : null;
  }

  @override
  Future<void> setMeta(String key, Object? value) async {
    final db = await _database();
    final tx = db.transaction(<JSAny>[kStoreMeta.toJS].toJS, 'readwrite');
    await _await(
      tx.objectStore(kStoreMeta).put(<String, Object?>{'key': key, 'value': value}.jsify()),
    );
  }

  @override
  Future<void> clearLearningData() async {
    final db = await _database();
    final tx = db.transaction(
      <JSAny>[kStoreChunks.toJS, kStoreKv.toJS, kStoreEvents.toJS].toJS,
      'readwrite',
    );
    await Future.wait([
      _await(tx.objectStore(kStoreChunks).clear()),
      _await(tx.objectStore(kStoreKv).clear()),
      _await(tx.objectStore(kStoreEvents).clear()),
    ]);
  }
}

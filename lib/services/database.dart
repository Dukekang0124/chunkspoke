import 'package:sqflite/sqflite.dart';
import 'state_machine.dart';

// Per-chunk progress row (M1 data layer).
class ChunkRow {
  final String chunkKey;
  final ChunkLevel level;
  final int dueDate; // epoch ms; 0 = not scheduled
  final int failCount;
  final int lastScore; // 0..100

  const ChunkRow({
    required this.chunkKey,
    required this.level,
    required this.dueDate,
    required this.failCount,
    required this.lastScore,
  });

  ChunkRow copyWith({
    ChunkLevel? level,
    int? dueDate,
    int? failCount,
    int? lastScore,
  }) =>
      ChunkRow(
        chunkKey: chunkKey,
        level: level ?? this.level,
        dueDate: dueDate ?? this.dueDate,
        failCount: failCount ?? this.failCount,
        lastScore: lastScore ?? this.lastScore,
      );

  Map<String, Object> toMap() => {
        'chunk_key': chunkKey,
        'level': level.index,
        'due_date': dueDate,
        'fail_count': failCount,
        'last_score': lastScore,
      };

  factory ChunkRow.fromMap(Map<String, Object?> m) => ChunkRow(
        chunkKey: m['chunk_key'] as String,
        level: ChunkLevel.values[m['level'] as int],
        dueDate: m['due_date'] as int,
        failCount: m['fail_count'] as int,
        lastScore: m['last_score'] as int,
      );
}

// SQLite backend for the app. Owns three tables:
//   kv       — key/value for the legacy ProgressService surface (backward compatible)
//   chunks   — per-chunk progress (chunk_id/level/due_date/fail_count/last_score)
//   sessions — session history (one row per applyEvent)
// The database factory is injectable so tests can use an in-memory FFI database.
class AppDatabase {
  AppDatabase({String? path}) : _path = path;
  final String? _path;
  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final path = _path ?? await _defaultPath();
    _db = await openDatabase(path, version: 1, onCreate: _onCreate);
    return _db!;
  }

  static Future<String> _defaultPath() async {
    final dir = await getDatabasesPath();
    return '${dir}/chunkspoke.db';
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS kv (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chunks (
        chunk_key TEXT PRIMARY KEY,
        level INTEGER NOT NULL,
        due_date INTEGER NOT NULL,
        fail_count INTEGER NOT NULL,
        last_score INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chunk_key TEXT NOT NULL,
        ts INTEGER NOT NULL,
        outcome TEXT NOT NULL,
        score INTEGER NOT NULL
      )''');
  }

  // —— kv (legacy surface) ——
  Future<String?> getKv(String key) async {
    final rows =
        await (await db).query('kv', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> setKv(String key, String value) async {
    await (await db).insert('kv', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> getAllKv() async {
    final rows = await (await db).query('kv');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  // —— chunks (structured progress) ——
  Future<ChunkRow?> getChunk(String key) async {
    final rows = await (await db)
        .query('chunks', where: 'chunk_key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return ChunkRow.fromMap(rows.first);
  }

  Future<void> upsertChunk(ChunkRow row) async {
    await (await db).insert('chunks', row.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ChunkRow>> dueChunks(int now) async {
    final rows = await (await db).query('chunks',
        where: 'due_date <= ? AND level = ?',
        whereArgs: [now, ChunkLevel.review.index]);
    return rows.map(ChunkRow.fromMap).toList();
  }

  // —— sessions (history) ——
  Future<void> insertSession(String key, String outcome, int score) async {
    await (await db).insert('sessions', {
      'chunk_key': key,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'outcome': outcome,
      'score': score,
    });
  }
}

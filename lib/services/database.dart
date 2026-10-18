import 'package:sqflite/sqflite.dart';
import 'state_machine.dart';

// Per-chunk progress row (M1 data layer + M7 mastered-hard-threshold fields).
//
// New fields (M7):
//   l2OneTry  : -1 = unknown (hasn't reached L2 cleanly), 0 = needed >1 drag try,
//               1 = passed L2 on the first drag attempt.
//   l4SelfEval: set true on the no-Key/offline L4 path when the user self-rates
//               "said correct" — substitutes for an STT hit-rate score.
//
// A chunk is `mastered` only when BOTH hold: l2OneTry == 1 AND
// (lastScore >= 80 OR l4SelfEval). See ChunkProgressStore.isMastered.
class ChunkRow {
  final String chunkKey;
  final ChunkLevel level;
  final int dueDate; // epoch ms; 0 = not scheduled
  final int failCount;
  final int lastScore; // 0..100 (L4 STT hit-rate or L3 accuracy)
  final int l2OneTry; // -1 unknown | 0 no | 1 yes
  final bool l4SelfEval;
  final int reviewStage; // SRS 阶梯序号（0=+1天, 1=+3, 2=+7, 3=+14）；仅 review 态有意义

  const ChunkRow({
    required this.chunkKey,
    required this.level,
    required this.dueDate,
    required this.failCount,
    required this.lastScore,
    this.l2OneTry = -1,
    this.l4SelfEval = false,
    this.reviewStage = 0,
  });

  ChunkRow copyWith({
    ChunkLevel? level,
    int? dueDate,
    int? failCount,
    int? lastScore,
    int? l2OneTry,
    bool? l4SelfEval,
    int? reviewStage,
  }) =>
      ChunkRow(
        chunkKey: chunkKey,
        level: level ?? this.level,
        dueDate: dueDate ?? this.dueDate,
        failCount: failCount ?? this.failCount,
        lastScore: lastScore ?? this.lastScore,
        l2OneTry: l2OneTry ?? this.l2OneTry,
        l4SelfEval: l4SelfEval ?? this.l4SelfEval,
        reviewStage: reviewStage ?? this.reviewStage,
      );

  Map<String, Object> toMap() => {
        'chunk_key': chunkKey,
        'level': level.index,
        'due_date': dueDate,
        'fail_count': failCount,
        'last_score': lastScore,
        'l2_one_try': l2OneTry,
        'l4_self_eval': l4SelfEval ? 1 : 0,
        'review_stage': reviewStage,
      };

  factory ChunkRow.fromMap(Map<String, Object?> m) => ChunkRow(
        chunkKey: m['chunk_key'] as String,
        level: ChunkLevel.values[m['level'] as int],
        dueDate: m['due_date'] as int,
        failCount: m['fail_count'] as int,
        lastScore: m['last_score'] as int,
        l2OneTry: (m['l2_one_try'] as int?) ?? -1,
        l4SelfEval: (m['l4_self_eval'] as int?) == 1,
        reviewStage: (m['review_stage'] as int?) ?? 0,
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
    _db = await openDatabase(path,
        version: 3, onCreate: _onCreate, onUpgrade: _onUpgrade);
    return _db!;
  }

  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    // M7: add mastered-hard-threshold columns without losing progress.
    if (oldV < 2) {
      await db.execute('ALTER TABLE chunks ADD COLUMN l2_one_try INTEGER NOT NULL DEFAULT -1');
      await db.execute('ALTER TABLE chunks ADD COLUMN l4_self_eval INTEGER NOT NULL DEFAULT 0');
    }
    // SRS 阶梯：新增 review_stage 列（M9），失败升级、成功回退。
    if (oldV < 3) {
      await db.execute('ALTER TABLE chunks ADD COLUMN review_stage INTEGER NOT NULL DEFAULT 0');
    }
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
        last_score INTEGER NOT NULL,
        l2_one_try INTEGER NOT NULL DEFAULT -1,
        l4_self_eval INTEGER NOT NULL DEFAULT 0,
        review_stage INTEGER NOT NULL DEFAULT 0
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
        whereArgs: [now, ChunkLevel.review.index],
        // 错因驱动：错得多、久未练的优先（弱点先排）。
        orderBy: 'fail_count DESC, due_date ASC');
    return rows.map(ChunkRow.fromMap).toList();
  }

  // 旧数据重置（M4）：清空进度表，保留 kv 设置。
  Future<void> resetChunks() async {
    await (await db).delete('chunks');
  }

  // 全部已掌握词块 key（用于场景解锁 ≥80% 与首页统计）。
  Future<List<String>> allMasteredKeys() async {
    final rows = await (await db).query('chunks',
        columns: ['chunk_key'],
        where: 'level = ?',
        whereArgs: [ChunkLevel.mastered.index]);
    return rows.map((r) => r['chunk_key'] as String).toList();
  }

  // 最近一次未来的复习到期时间（epoch ms；无则 null），供会话战报「下次复习时间」。
  Future<int?> nextDueTimestamp(int now) async {
    final rows = await (await db).query('chunks',
        columns: ['due_date'],
        where: 'due_date > ? AND level = ?',
        whereArgs: [now, ChunkLevel.review.index],
        orderBy: 'due_date ASC',
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['due_date'] as int;
  }

  // —— M7 AI 周报统计（绝不读录音原文，仅聚合数字 + 词块 ID）—— //
  Future<int> countSessionEvent(String name) async {
    final r = await (await db).rawQuery(
        'SELECT COUNT(*) c FROM sessions WHERE outcome = ?', [name]);
    return (r.first['c'] as int?) ?? 0;
  }

  Future<double> avgSessionScore() async {
    final r = await (await db).rawQuery(
        'SELECT AVG(score) a FROM sessions WHERE score > 0');
    final v = r.first['a'];
    return v == null ? 0.0 : (v as num).toDouble();
  }

  Future<List<ChunkRow>> topFailChunks(int n) async {
    final rows = await (await db).query('chunks',
        where: 'fail_count > 0', orderBy: 'fail_count DESC', limit: n);
    return rows.map((m) => ChunkRow.fromMap(m)).toList();
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

import 'package:sqflite/sqflite.dart';
import 'chunk_asset.dart';
import 'state_machine.dart';

// Per-chunk progress row (M1 data layer + M7 mastered-hard-threshold fields
// + 1.5 词块资产制字段).
//
// 两条并行轴：
//   level      — 关卡内进度/场景解锁硬门槛（旧口径，继续供解锁与续练使用）。
//                mastered 需 l2OneTry == 1 且 (lastScore >= 80 或 l4SelfEval)。
//   assetState — 跨会话资产生命周期（新学→巩固中→已巩固→长期→已掌握/需重修），
//                复习引擎、词块库与度量的唯一真源。
//
// assetReturnState/assetReturnStage 仅在需重修态有效：记录失败前的原位，
// 重修通过后回到该状态/档位。
class ChunkRow {
  final String chunkKey;
  final ChunkLevel level;
  final int dueDate; // epoch ms; 0 = 不排期
  final int failCount;
  final int lastScore; // 0..100 (L4 STT hit-rate or L3 accuracy)
  final int l2OneTry; // -1 unknown | 0 no | 1 yes
  final bool l4SelfEval;
  final int reviewStage; // 资产复习档位（0/1/2/3；已掌握=4）
  final ChunkAssetState assetState;
  final ChunkAssetState? assetReturnState;
  final int assetReturnStage;
  final int firstLearnedAt; // 首次完成学习的 epoch ms；0 = 未完成
  final int reviewCount; // 复习会话完成次数（通过+失败）
  final int correctStreak; // 当前连续复习通过次数
  final int lastReviewAt; // 最近一次复习的 epoch ms；0 = 从未复习

  const ChunkRow({
    required this.chunkKey,
    required this.level,
    required this.dueDate,
    required this.failCount,
    required this.lastScore,
    this.l2OneTry = -1,
    this.l4SelfEval = false,
    this.reviewStage = 0,
    this.assetState = ChunkAssetState.learning,
    this.assetReturnState,
    this.assetReturnStage = -1,
    this.firstLearnedAt = 0,
    this.reviewCount = 0,
    this.correctStreak = 0,
    this.lastReviewAt = 0,
  });

  ChunkAssetSnapshot get assetSnapshot => ChunkAssetSnapshot(
        state: assetState,
        stage: reviewStage,
        returnState: assetReturnState,
        returnStage: assetReturnStage,
      );

  Map<String, Object?> toMap() => {
        'chunk_key': chunkKey,
        'level': level.index,
        'due_date': dueDate,
        'fail_count': failCount,
        'last_score': lastScore,
        'l2_one_try': l2OneTry,
        'l4_self_eval': l4SelfEval ? 1 : 0,
        'review_stage': reviewStage,
        'asset_state': assetState.index,
        'asset_return_state': assetReturnState?.index ?? -1,
        'asset_return_stage': assetReturnStage,
        'first_learned_at': firstLearnedAt,
        'review_count': reviewCount,
        'correct_streak': correctStreak,
        'last_review_at': lastReviewAt,
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
        assetState: _assetState(m['asset_state'] as int?),
        assetReturnState: _assetStateOrNull(m['asset_return_state'] as int?),
        assetReturnStage: (m['asset_return_stage'] as int?) ?? -1,
        firstLearnedAt: (m['first_learned_at'] as int?) ?? 0,
        reviewCount: (m['review_count'] as int?) ?? 0,
        correctStreak: (m['correct_streak'] as int?) ?? 0,
        lastReviewAt: (m['last_review_at'] as int?) ?? 0,
      );

  static ChunkAssetState _assetState(int? i) =>
      (i == null || i < 0 || i >= ChunkAssetState.values.length)
          ? ChunkAssetState.learning
          : ChunkAssetState.values[i];

  static ChunkAssetState? _assetStateOrNull(int? i) =>
      (i == null || i < 0 || i >= ChunkAssetState.values.length)
          ? null
          : ChunkAssetState.values[i];
}

// SQLite backend for the app. Owns three tables:
//   kv       — key/value for the legacy ProgressService surface (backward compatible)
//   chunks   — per-chunk progress (chunk_id/level/due_date/fail_count/last_score)
//   sessions — session history (one row per applyEvent)
// The database factory is injectable so tests can use an in-memory FFI database.
class AppDatabase {
  AppDatabase({String? path, DateTime Function()? clock})
      : _path = path,
        _clock = clock ?? DateTime.now;
  final String? _path;
  final DateTime Function() _clock;
  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final path = _path ?? await _defaultPath();
    _db = await openDatabase(path,
        version: 4, onCreate: _onCreate, onUpgrade: _onUpgrade);
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
    // v4（1.5 词块资产制）：只增列 + 幂等回填，绝不删改既有进度。
    // 旧数据映射：
    //   level mastered → asset mastered
    //   level review   → stage 0=巩固中 / 1=已巩固 / ≥2=长期
    //   其余           → 新学
    // first_learned_at 取该块最早一条 session 时间（无则 0）。
    if (oldV < 4) {
      await db.execute(
          'ALTER TABLE chunks ADD COLUMN asset_state INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE chunks ADD COLUMN asset_return_state INTEGER NOT NULL DEFAULT -1');
      await db.execute(
          'ALTER TABLE chunks ADD COLUMN asset_return_stage INTEGER NOT NULL DEFAULT -1');
      await db.execute(
          'ALTER TABLE chunks ADD COLUMN first_learned_at INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE chunks ADD COLUMN review_count INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE chunks ADD COLUMN correct_streak INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE chunks ADD COLUMN last_review_at INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE sessions ADD COLUMN review INTEGER NOT NULL DEFAULT 0');
      final review = ChunkLevel.review.index;
      final mastered = ChunkLevel.mastered.index;
      final aLearning = ChunkAssetState.learning.index;
      final aConsolidating = ChunkAssetState.consolidating.index;
      final aConsolidated = ChunkAssetState.consolidated.index;
      final aLongTerm = ChunkAssetState.longTerm.index;
      final aMastered = ChunkAssetState.mastered.index;
      const aMasteredStage = ChunkAssetMachine.masteredStage;
      await db.execute('''
        UPDATE chunks SET asset_state = CASE
          WHEN level = $mastered THEN $aMastered
          WHEN level = $review THEN CASE
            WHEN review_stage <= 0 THEN $aConsolidating
            WHEN review_stage = 1 THEN $aConsolidated
            ELSE $aLongTerm
          END
          ELSE $aLearning
        END''');
      await db.execute('''
        UPDATE chunks SET review_stage = CASE
          WHEN level = $mastered THEN $aMasteredStage
          WHEN level = $review THEN
            CASE WHEN review_stage < 0 THEN 0
                 WHEN review_stage > 3 THEN 3
                 ELSE review_stage END
          ELSE review_stage
        END''');
      await db.execute('''
        UPDATE chunks SET first_learned_at = COALESCE(
          (SELECT MIN(s.ts) FROM sessions s
           WHERE s.chunk_key = chunks.chunk_key), 0)''');
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
        review_stage INTEGER NOT NULL DEFAULT 0,
        asset_state INTEGER NOT NULL DEFAULT 0,
        asset_return_state INTEGER NOT NULL DEFAULT -1,
        asset_return_stage INTEGER NOT NULL DEFAULT -1,
        first_learned_at INTEGER NOT NULL DEFAULT 0,
        review_count INTEGER NOT NULL DEFAULT 0,
        correct_streak INTEGER NOT NULL DEFAULT 0,
        last_review_at INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chunk_key TEXT NOT NULL,
        ts INTEGER NOT NULL,
        outcome TEXT NOT NULL,
        score INTEGER NOT NULL,
        review INTEGER NOT NULL DEFAULT 0
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

  /// 到期复习队列（资产轴）：巩固中/已巩固/长期/需重修且到期。
  /// [limit] 用于每日上限截断；超出部分保持到期，次日自然顺延。
  Future<List<ChunkRow>> dueChunks(int now, {int? limit}) async {
    final rows = await (await db).query('chunks',
        where: 'due_date > 0 AND due_date <= ? AND asset_state IN (?, ?, ?, ?)',
        whereArgs: [
          now,
          ChunkAssetState.consolidating.index,
          ChunkAssetState.consolidated.index,
          ChunkAssetState.longTerm.index,
          ChunkAssetState.relearning.index,
        ],
        // 错因驱动：错得多、久未练的优先（弱点先排）。
        orderBy: 'fail_count DESC, due_date ASC',
        limit: limit);
    return rows.map(ChunkRow.fromMap).toList();
  }

  Future<int> countDueChunks(int now) async {
    final r = await (await db).rawQuery(
        'SELECT COUNT(*) c FROM chunks WHERE due_date > 0 AND due_date <= ? '
        'AND asset_state IN (?, ?, ?, ?)',
        [
          now,
          ChunkAssetState.consolidating.index,
          ChunkAssetState.consolidated.index,
          ChunkAssetState.longTerm.index,
          ChunkAssetState.relearning.index,
        ]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// 今日已复习块数（按每块最近一次复习时间统计，天然去重）。
  Future<int> countReviewedSince(int sinceMs) async {
    final r = await (await db).rawQuery(
        'SELECT COUNT(*) c FROM chunks WHERE last_review_at >= ?', [sinceMs]);
    return (r.first['c'] as int?) ?? 0;
  }

  Future<List<ChunkRow>> allChunks() async {
    final rows = await (await db).query('chunks', orderBy: 'chunk_key ASC');
    return rows.map(ChunkRow.fromMap).toList();
  }

  /// 资产轴分组计数（词块库 / W2-1 口径唯一真源）。
  Future<Map<ChunkAssetState, int>> assetStateCounts() async {
    final rows = await (await db).rawQuery(
        'SELECT asset_state, COUNT(*) c FROM chunks GROUP BY asset_state');
    final out = <ChunkAssetState, int>{
      for (final s in ChunkAssetState.values) s: 0,
    };
    for (final r in rows) {
      final i = r['asset_state'] as int? ?? 0;
      if (i >= 0 && i < ChunkAssetState.values.length) {
        out[ChunkAssetState.values[i]] = (r['c'] as int?) ?? 0;
      }
    }
    return out;
  }

  /// 已掌握（资产轴）= 走完 1/3/7/14 天复习的块数。
  Future<int> countAssetMastered() async {
    final r = await (await db).rawQuery(
        'SELECT COUNT(*) c FROM chunks WHERE asset_state = ?',
        [ChunkAssetState.mastered.index]);
    return (r.first['c'] as int?) ?? 0;
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

  // 最近一次未来的复习到期时间（epoch ms；无则 null），供战报/首页「下次复习」。
  Future<int?> nextDueTimestamp(int now) async {
    final rows = await (await db).query('chunks',
        columns: ['due_date'],
        where: 'due_date > ? AND asset_state IN (?, ?, ?, ?)',
        whereArgs: [
          now,
          ChunkAssetState.consolidating.index,
          ChunkAssetState.consolidated.index,
          ChunkAssetState.longTerm.index,
          ChunkAssetState.relearning.index,
        ],
        orderBy: 'due_date ASC',
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['due_date'] as int;
  }

  /// 最早一个到期时间（含已到期），供到期提醒排期。
  Future<int?> earliestDueTimestamp() async {
    final rows = await (await db).query('chunks',
        columns: ['due_date'],
        where: 'due_date > 0 AND asset_state IN (?, ?, ?, ?)',
        whereArgs: [
          ChunkAssetState.consolidating.index,
          ChunkAssetState.consolidated.index,
          ChunkAssetState.longTerm.index,
          ChunkAssetState.relearning.index,
        ],
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

  /// 事件计数（可按复习/学习会话过滤），供导出与漏斗口径使用。
  Future<Map<String, int>> sessionOutcomeCounts({bool? review}) async {
    final rows = await (await db).rawQuery(
      'SELECT outcome, COUNT(*) c FROM sessions'
      '${review == null ? '' : ' WHERE review = ?'} GROUP BY outcome',
      review == null ? null : [review ? 1 : 0],
    );
    return {
      for (final r in rows)
        (r['outcome'] as String? ?? ''): (r['c'] as int?) ?? 0,
    };
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
  // review=true 标记复习会话事件（供「7 天后首次复习通过率」等度量口径使用）。
  Future<void> insertSession(String key, String outcome, int score,
      {bool review = false, int? ts}) async {
    await (await db).insert('sessions', {
      'chunk_key': key,
      'ts': ts ?? _clock().millisecondsSinceEpoch,
      'outcome': outcome,
      'score': score,
      'review': review ? 1 : 0,
    });
  }
}

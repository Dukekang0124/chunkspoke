import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'chunk_progress.dart';
import 'legacy_gate.dart';
import 'license_state.dart';
import 'user_package.dart';
import 'user_package_store.dart';

/// 1.5.10（#209 通道版）· 整机数据 JSON 导出 / 导入。
///
/// 只做通道，不改任何判定阈值与推进语义：
///   · 导出 = 读 `kv` / `chunks` / `sessions` 三张表 + `legacy.flag` 原样带上；
///   · 导入 = **合并**（不覆盖本机更新的进度、不重复追加会话、不覆盖已有设置）；
///   · 全程本机，不联网、不上传。
///
/// 为什么导出件要带 legacy 标记：`legacy.flag` 在库外，清数据会一起抹掉；
/// 1.6.0 判「老用户」只看这个文件。导出件带不上，清过数据的爷爷就再也回不来（D1）。
///
/// ASR-233 两条边界：
///   · 授权态（`license.` 命名空间）**不进备份件、也不从备份件写回**：备份是明文
///     JSON，谁拿到都能粘进来，随件走等于白送 PRO。换机重输一次自己的码即可，
///     老用户身份仍走库外标记，不受这条影响。
///   · 自定义词块的**档案**随 kv 走、**块行**走官方口径被库层排除，所以合并完要按
///     档案补齐缺行，否则自检立刻判红「档案有、台账无」。只补缺行、不覆盖任何进度；
///     如实说明：user 块的学习进度不在备份件里，补回来的行按「未开始学习」记。
const int kChannelSchema = 1;

/// ASR-233：自定义词表档案的 kv 前缀（付费门的第二条通道）。
///
/// 导出照带（件是用户自己的数据）；**导入侧按门决定收不收**。未授权机器合并
/// 一份别人的备份 = 白拿自定义包，所以这里与 `license.*` 同一套心智：
/// 前缀判据单源、跳过 + 如实计数。
bool isUserPackageArchiveKv(String key) =>
    key.startsWith(AppDatabase.kUserPkgKvPrefix);

/// 导出头里的 App 版本：发版时与 pubspec / 包内清单同 bump。
const String kChannelAppVersion = '1.9.1';

const List<String> _chunkKeys = [
  'chunk_key',
  'level',
  'due_date',
  'fail_count',
  'last_score',
  'l2_one_try',
  'l4_self_eval',
  'review_stage',
  'asset_state',
  'asset_return_state',
  'asset_return_stage',
  'first_learned_at',
  'review_count',
  'correct_streak',
  'last_review_at',
];

const List<String> _sessionKeys = [
  'chunk_key',
  'ts',
  'outcome',
  'score',
  'review',
];

class ChannelFormatError implements Exception {
  ChannelFormatError(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class ChannelExport {
  const ChannelExport({
    required this.json,
    required this.filename,
    required this.chunkCount,
    required this.sessionCount,
    required this.kvCount,
    required this.legacyFlag,
  });
  final String json;
  final String filename;
  final int chunkCount;
  final int sessionCount;
  final int kvCount;
  final String legacyFlag;
}

class ChannelImportPlan {
  const ChannelImportPlan({
    required this.newChunks,
    required this.updatedChunks,
    required this.keptChunks,
    required this.newSessions,
    required this.dupSessions,
    required this.newKv,
    required this.legacyFlag,
    required this.payload,
    this.ignoredLicenseKv = 0,
    this.ignoredUserChunks = 0,
    this.ignoredUserArchives = 0,
    this.rebuiltUserRows = 0,
    this.acceptedUserArchives = const {},
    this.skippedUserArchives = 0,
    this.skippedUserEntries = 0,
  });
  final int newChunks;
  final int updatedChunks;
  final int keptChunks; // 本机更新 → 保留本机
  final int newSessions;
  final int dupSessions;
  final int newKv;
  final String legacyFlag;
  final Map<String, dynamic> payload;

  /// ASR-233：件里带了授权键（旧版备份或手改件）→ 一律忽略，且要如实告诉用户。
  final int ignoredLicenseKv;

  /// ASR-233：件里带了 `user:` 块行（手改件）→ 不走这条路。
  /// 自定义块只能由档案重建，否则绕过名额闸、还会留下没人认领的孤儿行。
  final int ignoredUserChunks;

  /// ASR-233：件里带了 `userpkg.*` 词表档案、但本机没解锁 → 不写、不补行，只计数。
  final int ignoredUserArchives;

  /// 合并后按档案补回的自定义块行数（预览恒为 0；执行后才有值）。
  final int rebuiltUserRows;

  /// ASR-233 深度自查：licensed 恢复时通过消毒闸的档案（kvKey → canonical JSON）。
  /// 通道只写这些；手改件里超名额/脏字段/撞名的档案不在其中。预览/执行共用同一份结论。
  final Map<String, String> acceptedUserArchives;

  /// 整份拒收的自定义档案数（解析失败/模块键不自洽/超 200/名额满/撞名/全坏）。
  final int skippedUserArchives;

  /// 被收档案里剔除的坏条目数（字段闸不过，整份仍收其余好条目）。
  final int skippedUserEntries;

  bool get nothingToDo =>
      newChunks == 0 &&
      updatedChunks == 0 &&
      newSessions == 0 &&
      newKv == 0 &&
      rebuiltUserRows == 0;

  int get adoptedLegacy => LegacyGate.isLegacy(legacyFlag) ? 1 : 0;

  ChannelImportPlan withRebuiltUserRows(int n) => ChannelImportPlan(
        newChunks: newChunks,
        updatedChunks: updatedChunks,
        keptChunks: keptChunks,
        newSessions: newSessions,
        dupSessions: dupSessions,
        newKv: newKv,
        legacyFlag: legacyFlag,
        payload: payload,
        ignoredLicenseKv: ignoredLicenseKv,
        ignoredUserChunks: ignoredUserChunks,
        ignoredUserArchives: ignoredUserArchives,
        rebuiltUserRows: n,
        acceptedUserArchives: acceptedUserArchives,
        skippedUserArchives: skippedUserArchives,
        skippedUserEntries: skippedUserEntries,
      );
}

/// 组导出 JSON。纯函数：不读 IO、不看时钟，便于单测逐字段断言。
Map<String, dynamic> buildChannelMap({
  required Map<String, String> kv,
  required List<Map<String, Object?>> chunks,
  required List<Map<String, Object?>> sessions,
  required String legacyFlag,
  required DateTime now,
}) {
  // 「首迹」= 最早的正面证据：优先 first_learned_at，其次最早会话。
  var since = 0;
  for (final c in chunks) {
    final t = (c['first_learned_at'] as int?) ?? 0;
    if (t > 0 && (since == 0 || t < since)) since = t;
  }
  if (since == 0) {
    for (final s in sessions) {
      final t = (s['ts'] as int?) ?? 0;
      if (t > 0 && (since == 0 || t < since)) since = t;
    }
  }
  if (since == 0) since = now.millisecondsSinceEpoch;

  // ASR-233：授权态整段不进件。这里是导出件成形前的最后一道，
  // 单测直接调本函数也拿不到 license.*（不许只在 IO 层过滤）。
  final safeKv = {
    for (final e in kv.entries)
      if (!isLicenseKv(e.key)) e.key: e.value,
  };

  return {
    'schema_version': kChannelSchema,
    'app_version': kChannelAppVersion,
    'exported_at': now.millisecondsSinceEpoch,
    'legacy': {
      // 原样带上标记本体：1.6.0 导入时按这个字符串写回，不做二次解释。
      'flag': legacyFlag,
      'eligible': LegacyGate.isLegacy(legacyFlag),
      'since': since,
    },
    'counts': {
      'kv': safeKv.length,
      'chunks': chunks.length,
      'sessions': sessions.length,
    },
    'kv': safeKv,
    'chunks': [
      for (final c in chunks)
        {for (final k in _chunkKeys) k: c[k]},
    ],
    'sessions': [
      for (final s in sessions)
        {for (final k in _sessionKeys) k: s[k]},
    ],
  };
}

/// 解析 + 校验。失败一律抛 [ChannelFormatError]，文案直接给用户看。
Map<String, dynamic> decodeChannel(String text) {
  final t = text.trim();
  if (t.isEmpty) throw ChannelFormatError('内容为空，先把导出的 JSON 完整复制过来');
  Object? root;
  try {
    root = jsonDecode(t);
  } catch (_) {
    throw ChannelFormatError('不是合法的 JSON（常见原因：复制被截断，或选错了文件）');
  }
  if (root is! Map) throw ChannelFormatError('顶层不是对象，这不是本 App 的导出件');
  final m = Map<String, dynamic>.from(root);
  final schema = m['schema_version'];
  if (schema is! int) throw ChannelFormatError('缺 schema_version，不是本 App 的导出件');
  if (schema < 1) throw ChannelFormatError('schema_version 非法：$schema');
  if (schema > kChannelSchema) {
    throw ChannelFormatError(
        '这份备份来自更新的版本（schema $schema），当前版本读不了，请先升级');
  }
  final kv = m['kv'];
  if (kv is! Map) throw ChannelFormatError('缺 kv，导出件不完整');
  final chunks = m['chunks'];
  if (chunks is! List) throw ChannelFormatError('缺 chunks，导出件不完整');
  final sessions = m['sessions'];
  if (sessions is! List) throw ChannelFormatError('缺 sessions，导出件不完整');
  // 只有三表全空才判「导出件坏了」。
  // 早期写法在 chunks/sessions 空时就拒——那会把「只用过设置、还没开始学」的
  // 老用户挡在门外：他的 legacy 标记在备份里，却整份被拒，清过一次数据就回不来（D1）。
  if (chunks.isEmpty && sessions.isEmpty && kv.isEmpty) {
    throw ChannelFormatError('这份备份是空的（词块 / 学习记录 / 设置都没有），可能导出时出错了');
  }
  return m;
}

/// 导出：读三表 + 标记 → JSON 字符串 + 文件名。
Future<ChannelExport> buildChannelExport({
  required AppDatabase db,
  required LegacyGate gate,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final kv = await db.getAllKv();
  final chunks = [
    for (final r in await db.allChunks()) r.toMap(),
  ];
  final sessions = [
    for (final s in await db.allSessionRows())
      if (!isUserChunkKey((s['chunk_key'] ?? '').toString())) s,
  ];
  final flag = (await gate.readRaw()) ?? kLegacyFlagNo;
  final map = buildChannelMap(
    kv: kv,
    chunks: chunks,
    sessions: sessions,
    legacyFlag: flag,
    now: at,
  );
  final stamp = '${at.year}'
      '${at.month.toString().padLeft(2, '0')}'
      '${at.day.toString().padLeft(2, '0')}-'
      '${at.hour.toString().padLeft(2, '0')}'
      '${at.minute.toString().padLeft(2, '0')}';
  return ChannelExport(
    json: const JsonEncoder.withIndent('  ').convert(map),
    filename: 'chunkspoke_backup_$stamp.json',
    chunkCount: chunks.length,
    sessionCount: sessions.length,
    // 数以件里真有的为准：授权键已在成形时剔除，不能报库里的原始条数。
    kvCount: (map['kv'] as Map).length,
    legacyFlag: flag,
  );
}

Future<File> saveChannelExport(ChannelExport export) async {
  final dir = await getApplicationDocumentsDirectory();
  final f = File('${dir.path}/${export.filename}');
  return f.writeAsString(export.json, flush: true);
}

String _sessionId(Map<String, Object?> s) =>
    '${s['chunk_key']}|${s['ts']}|${s['outcome']}|${(s['review'] as int?) ?? 0}';

/// 合并预览：只读本机，不写任何东西。
///
/// ASR-233：`allowUserPackages` 必填——未授权机器的件里 `userpkg.*` 档案一律
/// 不算「新增设置」、也不在合并时写入（与 `license.*` 同一套跳过 + 诚实计数）。
Future<ChannelImportPlan> previewChannelImport({
  required AppDatabase db,
  required String text,
  required bool allowUserPackages,
}) async {
  final payload = decodeChannel(text);
  final current = {for (final r in await db.allChunks()) r.chunkKey: r};
  final seen = {
    for (final s in await db.allSessionRows()) _sessionId(s),
  };
  final currentKv = await db.getAllKv();

  var newChunks = 0, updatedChunks = 0, keptChunks = 0, ignoredUserChunks = 0;
  for (final raw in (payload['chunks'] as List)) {
    final incoming = Map<String, Object?>.from(raw as Map);
    final key = (incoming['chunk_key'] ?? '').toString();
    if (key.isEmpty) continue;
    if (isUserChunkKey(key)) {
      ignoredUserChunks++;
      continue;
    }
    final local = current[key];
    if (local == null) {
      newChunks++;
    } else if (_incomingWins(incoming, local)) {
      updatedChunks++;
    } else {
      keptChunks++;
    }
  }

  var newSessions = 0, dupSessions = 0;
  for (final raw in (payload['sessions'] as List)) {
    final s = Map<String, Object?>.from(raw as Map);
    if (isUserChunkKey((s['chunk_key'] ?? '').toString())) continue;
    if (seen.contains(_sessionId(s))) {
      dupSessions++;
    } else {
      newSessions++;
    }
  }

  var newKv = 0, ignoredLicenseKv = 0, ignoredUserArchives = 0;
  // 本批「新」自定义档案（本机已有的不覆盖、不算新）先收齐，交给消毒闸统一判
  // 名额/撞名/字段——licensed 机器也不许把明文备份件里的档案原样写回（手改件能绕闸）。
  final incomingArchives = <String, String>{};
  final kvMap = payload['kv'] as Map;
  for (final k in kvMap.keys) {
    final key = k.toString();
    if (isLicenseKv(key)) {
      ignoredLicenseKv++;
      continue;
    }
    if (isUserPackageArchiveKv(key)) {
      if (!allowUserPackages) {
        ignoredUserArchives++;
      } else if (!currentKv.containsKey(key)) {
        incomingArchives[key] = kvMap[k].toString();
      }
      continue; // 档案的新增数由消毒闸结果决定，不在这里逐条加
    }
    if (!currentKv.containsKey(key)) newKv++;
  }
  var acceptedUserArchives = <String, String>{};
  var skippedUserArchives = 0, skippedUserEntries = 0;
  if (incomingArchives.isNotEmpty) {
    final adoption = await UserPackageStore(db).adoptUserArchives(incomingArchives);
    acceptedUserArchives = adoption.accepted;
    skippedUserArchives = adoption.skippedArchives;
    skippedUserEntries = adoption.skippedEntries;
    newKv += adoption.accepted.length;
  }

  final legacy = payload['legacy'];
  final flag = (legacy is Map ? legacy['flag'] : null)?.toString() ??
      kLegacyFlagNo;
  return ChannelImportPlan(
    newChunks: newChunks,
    updatedChunks: updatedChunks,
    keptChunks: keptChunks,
    newSessions: newSessions,
    dupSessions: dupSessions,
    newKv: newKv,
    legacyFlag: flag,
    payload: payload,
    ignoredLicenseKv: ignoredLicenseKv,
    ignoredUserChunks: ignoredUserChunks,
    ignoredUserArchives: ignoredUserArchives,
    acceptedUserArchives: acceptedUserArchives,
    skippedUserArchives: skippedUserArchives,
    skippedUserEntries: skippedUserEntries,
  );
}

/// 合并执行：**先写身份标记（库外），再动库**——顺序反了老用户就回不来（D1）。
Future<ChannelImportPlan> applyChannelImport({
  required AppDatabase db,
  required LegacyGate gate,
  required String text,
  ChunkProgressStore? store,
  required bool allowUserPackages,
}) async {
  final plan = await previewChannelImport(
      db: db, text: text, allowUserPackages: allowUserPackages);
  // D1：这一行必须在任何 DB 写入之前。
  await gate.adoptFromImport(plan.legacyFlag);

  final currentKv = await db.getAllKv();
  for (final e in (plan.payload['kv'] as Map).entries) {
    final k = e.key.toString();
    // ASR-233：授权键一律不写回。旧版备份件里带着它，合并一份别人的件
    // 就等于白拿 PRO——这条必须在写库前挡住，不能只靠导出侧不带。
    if (isLicenseKv(k)) continue;
    if (isUserPackageArchiveKv(k)) {
      // ASR-233：没解锁就不写词表档案（否则合并一份别人的备份 = 白拿自定义包）。
      if (!allowUserPackages) continue;
      // 深度自查：只写消毒闸通过的 canonical 档案；超名额/脏字段/撞名的一律不写。
      final canonical = plan.acceptedUserArchives[k];
      if (canonical == null) continue;
      if (currentKv.containsKey(k)) continue;
      await db.setKv(k, canonical);
      continue;
    }
    if (currentKv.containsKey(k)) continue; // 本机已有设置优先，绝不覆盖
    await db.setKv(k, e.value.toString());
  }

  final current = {for (final r in await db.allChunks()) r.chunkKey: r};
  final writes = <ChunkRow>[];
  for (final raw in (plan.payload['chunks'] as List)) {
    final m = Map<String, Object?>.from(raw as Map);
    final key = (m['chunk_key'] ?? '').toString();
    if (key.isEmpty) continue;
    if (isUserChunkKey(key)) continue; // 自定义块只由档案重建，不走块行合并
    final local = current[key];
    if (local != null && !_incomingWins(m, local)) continue;
    writes.add(_rowFrom(m));
  }
  // ASR-206 §二：导入也是台账写入点——块行与受影响关卡的锚点必须同事务落盘，
  // 否则「导入后台账前进、锚点停在旧块」就是第三案。无关卡索引时退回逐条写。
  if (store != null) {
    await store.applyImportedRows(writes);
  } else {
    for (final r in writes) {
      await db.upsertChunk(r);
    }
  }

  for (final raw in (plan.payload['sessions'] as List)) {
    final s = Map<String, Object?>.from(raw as Map);
    if (isUserChunkKey((s['chunk_key'] ?? '').toString())) continue;
    await db.insertSessionIfMissing(s);
  }

  // ASR-233：档案随 kv 回来了、块行没有（官方口径在库层排除自定义键）。
  // 按档案补齐缺行，否则合并完自检立刻判红「档案有、台账无」、分区点进去是空的。
  // 没解锁时档案根本没写进来，补行同样不许跑：那是「恢复已有档案」，不是新导入。
  if (!allowUserPackages) return plan;
  final rebuilt = await UserPackageStore(db).rebuildMissingRows();
  return rebuilt == 0 ? plan : plan.withRebuiltUserRows(rebuilt);
}

/// 同一条块：资产状态更靠后者胜；再比复习次数、最近复习时间。
/// 平手保留本机（导入是「补」，不是「覆盖」）。
bool _incomingWins(Map<String, Object?> incoming, ChunkRow local) {
  int i(String k) => (incoming[k] as int?) ?? 0;
  final a = i('asset_state'), b = local.assetState.index;
  if (a != b) return a > b;
  final rc = i('review_count'), lr = local.reviewCount;
  if (rc != lr) return rc > lr;
  final la = i('last_review_at'), lb = local.lastReviewAt;
  if (la != lb) return la > lb;
  return false;
}

ChunkRow _rowFrom(Map<String, Object?> m) {
  int i(String k, [int d = 0]) {
    final v = m[k];
    return v is int ? v : d;
  }

  return ChunkRow.fromMap({
    'chunk_key': m['chunk_key'],
    'level': i('level'),
    'due_date': i('due_date'),
    'fail_count': i('fail_count'),
    'last_score': i('last_score'),
    'l2_one_try': i('l2_one_try', -1),
    'l4_self_eval': i('l4_self_eval'),
    'review_stage': i('review_stage'),
    'asset_state': i('asset_state'),
    'asset_return_state': i('asset_return_state', -1),
    'asset_return_stage': i('asset_return_stage', -1),
    'first_learned_at': i('first_learned_at'),
    'review_count': i('review_count'),
    'correct_streak': i('correct_streak'),
    'last_review_at': i('last_review_at'),
  });
}

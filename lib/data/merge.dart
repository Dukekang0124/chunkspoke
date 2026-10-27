import 'dart:math' as math;

import '../storage/records.dart';
import 'protocol.dart';
import 'review_rules.dart';
import 'vocab.dart';

class MergeReport {
  int added = 0;
  int updated = 0;
  int skipped = 0;
  int orphan = 0;
  bool packsMismatch = false;
  final List<String> warnings = [];

  bool get isEmpty => added == 0 && updated == 0 && skipped == 0 && orphan == 0;

  @override
  String toString() =>
      '新增 $added / 更新 $updated / 跳过 $skipped / 孤儿 $orphan'
      '${packsMismatch ? '（内容包版本不一致）' : ''}';
}

class MergeOutcome {
  final Map<String, ChunkRecord> chunks;
  final Map<String, Object?> stats;
  final Map<String, Object?> settings;
  final List<EventRecord> events;
  final MergeReport report;

  const MergeOutcome({
    required this.chunks,
    required this.stats,
    required this.settings,
    required this.events,
    required this.report,
  });
}

/// 导入合并（方案 v1.1 §四-3）：LWW + 派生补齐 + 两条硬保护 + 孤儿保留。
///
/// 纯函数：不读写数据库、不改入参；调用方负责单事务落库与快照回滚。
MergeOutcome mergePackage({
  required DataPackage incoming,
  required Map<String, ChunkRecord> localChunks,
  required Set<String> knownChunkIds,
  Map<String, Object?> localStats = const {},
  Map<String, Object?> localSettings = const {},
  List<EventRecord> localEvents = const [],
  Map<String, String> localPacks = const {},
}) {
  final report = MergeReport()..warnings.addAll(incoming.warnings);
  final chunks = <String, ChunkRecord>{...localChunks};

  for (final inc in incoming.chunks) {
    final base = chunks[inc.id];
    final isOrphan = base?.orphan ?? !knownChunkIds.contains(inc.id);

    if (base != null && inc.updatedAt <= base.updatedAt) {
      report.skipped++;
      continue;
    }

    final derivedPass = inc.reviewStage >= kMasteredStage || inc.assetState == AssetState.mastered;
    final merged = inc.toRecord(orphan: isOrphan).copyWith(
      // 硬保护：协议不携带本机痕迹，只允许由派生规则升到「通过」语义
      l4SelfEval: derivedPass ? 1 : (base?.l4SelfEval ?? 0),
      l2OneTry: derivedPass ? 1 : (base?.l2OneTry ?? -1),
      lastScore: base?.lastScore ?? 0,
      // 硬保护：streak 只增不减
      correctStreak: base == null
          ? inc.correctStreak
          : math.max(base.correctStreak, inc.correctStreak),
    );

    chunks[inc.id] = merged;
    if (isOrphan) {
      report.orphan++;
    } else if (base == null) {
      report.added++;
    } else {
      report.updated++;
    }
  }

  final stats = <String, Object?>{...localStats};
  for (final e in incoming.stats.entries) {
    if (e.value == null) continue; // null 与缺键 = 不覆盖
    stats[e.key] = e.value;
  }

  final settings = <String, Object?>{...localSettings};
  for (final e in incoming.settings.entries) {
    if (e.value == null) continue;
    settings[e.key] = e.value;
  }

  final byId = <String, EventRecord>{for (final e in localEvents) e.eventId: e};
  for (final e in incoming.events) {
    byId.putIfAbsent(e.eventId, () => e);
  }
  final events = trimEvents(byId.values.toList());

  for (final e in incoming.packs.entries) {
    final local = localPacks[e.key];
    if (local != null && local != e.value) report.packsMismatch = true;
  }

  return MergeOutcome(
    chunks: chunks,
    stats: stats,
    settings: settings,
    events: events,
    report: report,
  );
}

/// 导出：本机行 → 交换协议（只带调度态与复习事件，不带本机痕迹）。
/// 孤儿块原样带回，不静默丢弃。
List<ChunkExchange> exportChunks(Iterable<ChunkRecord> rows) =>
    rows.map(ChunkExchange.fromRecord).toList();

DataPackage buildPackage({
  required Iterable<ChunkRecord> chunks,
  required List<EventRecord> events,
  required Map<String, Object?> stats,
  required Map<String, Object?> settings,
  required String origin,
  required String originVersion,
  required String exportedAt,
  required String deviceTag,
  Map<String, String> packs = const {},
}) =>
    DataPackage(
      origin: origin,
      originVersion: originVersion,
      exportedAt: exportedAt,
      deviceTag: deviceTag,
      packs: packs,
      chunks: exportChunks(chunks),
      stats: stats,
      events: events,
      settings: settings,
    );

/// 未知块校验：入站 id 是否属于本机内容包。
Set<String> unknownChunkIds(DataPackage incoming, Set<String> knownChunkIds) =>
    incoming.chunks.map((c) => c.id).where((id) => !knownChunkIds.contains(id)).toSet();

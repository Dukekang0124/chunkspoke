import '../models/content_pack.dart';
import 'learning_flow.dart';
import 'loaders.dart';

/// ASR-203：进度对账层。
///
/// 口径钉死为一句话：**台账（chunks 表）是唯一事实源，断点快照只是缓存**。
/// 之前详情页把 kv 快照当事实源（快照指向哪块就从哪块开始、环也按快照画），
/// 列表页按台账算，于是出现「台账 25/25、详情页还写着接着上次练 第 21 块」。
/// 本层把两者收敛：块号、环、完成态一律由台账派生；快照只允许保留「块内相位」，
/// 且一旦与台账不符就当场自愈。
class ModuleAudit {
  const ModuleAudit({
    required this.levelId,
    required this.theme,
    required this.total,
    required this.ledgerMastered,
    required this.ledgerNextIndex,
    required this.snapshotIndex,
    required this.snapshotChunkId,
    required this.snapshotValid,
    required this.wrongChunkIds,
    required this.pendingChunkIds,
    required this.masteredScores,
  });

  final String levelId;
  final String theme;

  /// 模块块数
  final int total;

  /// 台账：已掌握块数（与列表页同一口径：allMasteredKeys）
  final int ledgerMastered;

  /// 台账：首个未掌握块下标（== total 表示整模块已掌握）
  final int ledgerNextIndex;

  /// 断点快照里的块号；-1 = 无快照
  final int snapshotIndex;
  final String? snapshotChunkId;

  /// 快照是否指向本模块的真实块（伪 level / 串块的快照一律视为无效）
  final bool snapshotValid;

  /// 错块：已掌握但留痕不合格（一次没过 或 分数 <80）
  final List<String> wrongChunkIds;

  /// 未掌握块
  final List<String> pendingChunkIds;

  /// 已掌握块的开口分留痕（自检页「分数」列）
  final List<int> masteredScores;

  bool get complete => total > 0 && ledgerMastered >= total;

  /// 陈旧断点：**未完成的模块**里，快照与台账不同位（落后=双源分歧，超前/串块=脏数据）。
  ///
  /// 整模块已掌握时不看快照：那时快照只是「从头开始」重练留下的书签，
  /// 页面一律走完成态门（已完成 N/N + 环 100%），它既不会指错路，也不该把设备判红。
  /// 真机回执里「台账 12/12 · 断点第 1 块」被算进红名单，就是旧口径把书签当分歧了。
  bool get staleSnapshot =>
      snapshotIndex >= 0 &&
      !complete &&
      !(snapshotValid && snapshotIndex == ledgerNextIndex);

  bool get consistent => !staleSnapshot;

  /// 进度环一律由台账算：整模块掌握时就是 100%，不再被陈旧快照拖成 80%。
  double get ringRatio => total <= 0 ? 0 : ledgerMastered / total;

  /// 详情页应该从哪一块开始（完成态回到 0，交给「从头开始」）。
  int get startIndex => complete ? 0 : ledgerNextIndex.clamp(0, total - 1);

  /// 是否该弹「接着上次练」：只在台账确实停在中间某块时。
  bool get shouldOfferResume =>
      !complete && ledgerNextIndex > 0 && ledgerNextIndex < total;

  /// 分数留痕：已掌握块里的最低开口分（无数据 = -1）。
  int get minMasteredScore =>
      masteredScores.isEmpty ? -1 : masteredScores.reduce(_min);

  /// 分数留痕：已掌握块的平均开口分（无数据 = -1）。
  double get avgMasteredScore => masteredScores.isEmpty
      ? -1
      : masteredScores.reduce((a, b) => a + b) / masteredScores.length;

  static int _min(int a, int b) => a < b ? a : b;

  Map<String, Object?> toJson() => {
        'levelId': levelId,
        'theme': theme,
        'total': total,
        'ledgerMastered': ledgerMastered,
        'ledgerNextIndex': ledgerNextIndex,
        'snapshotIndex': snapshotIndex,
        'snapshotChunkId': snapshotChunkId,
        'snapshotValid': snapshotValid,
        'wrongChunks': wrongChunkIds.length,
        'wrongChunkIds': wrongChunkIds,
        'pendingChunks': pendingChunkIds.length,
        'minMasteredScore': minMasteredScore,
        'avgMasteredScore': avgMasteredScore,
        'consistent': consistent,
        'complete': complete,
      };
}

class ProgressIntegrity {
  /// 断点快照的 kv key（与 PracticeLoop 保持同一把 key）。
  static String resumeKey(String levelId) => 'learnResume_$levelId';

  static Future<ModuleAudit> audit(ProgressService p, Level level,
      {List<Chunk>? chunks}) async {
    final list = chunks ?? level.chunks;
    final keys = [for (final c in list) c.id];
    // 与列表页同一事实源：关卡轴的 mastered 键集合。
    final mastered = (await p.chunkStore.allMasteredKeys()).toSet();

    var next = keys.length;
    for (var i = 0; i < keys.length; i++) {
      if (!mastered.contains(keys[i])) {
        next = i;
        break;
      }
    }

    final snap =
        LearnResume.tryDecode(await p.learnResumeFromDb(level.id));
    final snapshotIndex = snap?.chunkIndex ?? -1;
    final snapshotValid = snap != null &&
        snapshotIndex >= 0 &&
        snapshotIndex < keys.length &&
        keys[snapshotIndex] == snap.chunkId;

    final wrong = <String>[];
    final pending = <String>[];
    final scores = <int>[];
    for (final k in keys) {
      final row = await p.chunkStore.get(k);
      if (!mastered.contains(k)) {
        pending.add(k);
        continue;
      }
      scores.add(row.lastScore);
      if (row.l2OneTry != 1 || row.lastScore < 80) wrong.add(k);
    }

    return ModuleAudit(
      levelId: level.id,
      theme: level.theme,
      total: keys.length,
      ledgerMastered: keys.where(mastered.contains).length,
      ledgerNextIndex: next,
      snapshotIndex: snapshotIndex,
      snapshotChunkId: snap?.chunkId,
      snapshotValid: snapshotValid,
      wrongChunkIds: wrong,
      pendingChunkIds: pending,
      masteredScores: scores,
    );
  }

  static Future<List<ModuleAudit>> auditAll(
      ProgressService p, ContentPack content) async {
    return [
      for (final lv in content.levels)
        if (lv.chunks.isNotEmpty) await audit(p, lv),
    ];
  }

  /// 自愈：陈旧快照一律清除（块号本来就由台账派生，留着只会指错）。
  /// 下一次进入模块时，PracticeLoop 会从台账位置重新落一份快照。
  static Future<ModuleAudit> heal(
      ProgressService p, Level level, ModuleAudit a) async {
    if (a.consistent) return a;
    await p.clearLearnResume(a.levelId);
    return audit(p, level);
  }

  /// 一键修复：对红名单逐模块自愈，返回修复后的最新审计。
  static Future<List<ModuleAudit>> healAll(
      ProgressService p, ContentPack content, List<ModuleAudit> audits) async {
    final byId = {for (final l in content.levels) l.id: l};
    final out = <ModuleAudit>[];
    for (final a in audits) {
      final lv = byId[a.levelId];
      if (lv == null || a.consistent) {
        out.add(a);
        continue;
      }
      out.add(await heal(p, lv, a));
    }
    return out;
  }

  /// 断点快照与台账同事务落盘用的 kv 对（ASR-203 修复 2）。
  /// 块完成后把快照直接写到位（下一块 / 整模块做完则清空）。
  static Map<String, String> resumeKvAfterChunkDone({
    required String levelId,
    required List<String> keys,
    required int doneIndex,
    required int nowMs,
  }) {
    final next = doneIndex + 1;
    return {
      resumeKey(levelId): next >= keys.length
          ? ''
          : LearnResume(
              chunkIndex: next,
              chunkId: keys[next],
              phase: 0,
              stars: StarBoard.empty,
              savedAt: nowMs,
            ).encode(),
    };
  }

  /// 红名单：所有「台账与快照不符」的模块（自检页与发版扫描共用）。
  static List<ModuleAudit> reds(List<ModuleAudit> audits) =>
      audits.where((a) => !a.consistent).toList();
}

import 'progress_integrity.dart';

/// ASR-211 修复 4/6：进度「渲染值」单源。
///
/// 案三的教训不是某个数算错，而是**两个定义并排显示**：
/// 地图卡片读台账集合计数（已掌握 21/25），练习页读位置缺口（第 10 块），
/// 自检又拿台账去比台账 → 内部恒等，永远零红。
///
/// 本文件把用户能看到的每个进度数字收成唯一渲染模型：数字一律由 [ModuleAudit]
/// （台账派生）算出，UI 只准渲染它，自检只准比对它。跳块时不再只报块号，
/// 而是同时报「第 X 块待通过 · 已掌握 N/M」，两个数各自有名字，不会被读成一回事。
class LevelDisplay {
  const LevelDisplay({
    required this.theme,
    required this.total,
    required this.mastered,
    required this.gapIndex,
    required this.skipped,
    required this.complete,
  });

  /// 由台账审计构造（UI 的唯一入口）。
  factory LevelDisplay.of(ModuleAudit a) => LevelDisplay(
        theme: a.theme,
        total: a.total,
        mastered: a.ledgerMastered,
        gapIndex: a.ledgerNextIndex,
        skipped: a.skippedChunkIds,
        complete: a.complete,
      );

  static Map<String, LevelDisplay> mapFromAudits(List<ModuleAudit> audits) => {
        for (final a in audits) a.levelId: LevelDisplay.of(a),
      };

  final String theme;
  final int total;

  /// 已掌握块数（台账集合计数，与地图卡片同一个数）
  final int mastered;

  /// 首个未掌握块的下标（位置缺口；整关完成时 == total）
  final int gapIndex;

  /// 跳块清单（缺口之前仍未通过的块）
  final List<String> skipped;
  final bool complete;

  /// 跳块态：缺口 ≠ 连续末端，且确实有块被跳过。
  bool get gapAhead =>
      !complete && skipped.isNotEmpty && mastered != gapIndex;

  /// 进度环一律用集合计数（整关完成 = 100%）。
  double get ring => total <= 0 ? 0 : (mastered / total).clamp(0.0, 1.0);

  String get counter => '$mastered/$total';

  /// 块号那一行的文案。跳块时说清是「待通过」，不再写「上次学到」。
  ///
  /// 未开始也带上 `0/total`：自检按「渲染值必须含台账计数」判一致性，
  /// 少字体的「未开始」会让一块没碰过的模块被误判成口径分歧。
  String get anchorLine {
    if (complete) return '已完成 $total/$total';
    if (gapAhead) return '第 ${gapIndex + 1} 块待通过 · 已掌握 $counter';
    if (mastered == 0) return '未开始 · 0/$total';
    return '第 ${gapIndex + 1} 块 · $counter';
  }

  /// 自检比对用：把两个定义写成可断言的字符串（渲染值 ⇄ 台账）。
  String get ledgerLine => '台账 已掌握 $counter · 缺口 第 ${gapIndex + 1} 块'
      '${gapAhead ? ' · 跳块 ${skipped.length}' : ''}';

  @override
  String toString() => '$theme: $anchorLine';
}

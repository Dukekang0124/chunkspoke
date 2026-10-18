/// 会话收尾战报数据（B6）：本次会话的真实统计，供收尾页展示。
class SessionReport {
  /// 本次新掌握的块数。
  final int newMastered;
  /// 本次开口判定通过的次数（与「今日开口」同源）。
  final int spoken;
  /// 本次最高连对（连续掌握块数）。
  final int maxCombo;
  /// 本次复习的块数（复习会话 > 0）。
  final int reviewed;
  const SessionReport({
    this.newMastered = 0,
    this.spoken = 0,
    this.maxCombo = 0,
    this.reviewed = 0,
  });
}

import 'review_scheduler.dart';

/// 词块资产生命周期（指令 K · 模块 A）。
///
/// 正向五态：新学 → 巩固中 → 已巩固 → 长期 → 已掌握；
/// 回归态：需重修（任一可复习态失败后进入，记录回退点，重修通过回到原位）。
/// 与 [ChunkLevel] 分属两条轴：
///   - ChunkLevel 是关卡内进度/场景解锁的硬门槛（旧口径，继续供解锁使用）；
///   - ChunkAssetState 是跨会话的长期资产状态（词块库/复习引擎/度量的唯一真源）。
enum ChunkAssetState {
  learning, // 新学
  consolidating, // 巩固中（1 天档）
  consolidated, // 已巩固（首到期 1 天，通过后 3 天档）
  longTerm, // 长期（7/14 天档）
  mastered, // 已掌握（完成全部间隔）
  relearning, // 需重修（复习失败后的回归态）
}

extension ChunkAssetStateInfo on ChunkAssetState {
  String get label {
    switch (this) {
      case ChunkAssetState.learning:
        return '新学';
      case ChunkAssetState.consolidating:
        return '巩固中';
      case ChunkAssetState.consolidated:
        return '已巩固';
      case ChunkAssetState.longTerm:
        return '长期';
      case ChunkAssetState.mastered:
        return '已掌握';
      case ChunkAssetState.relearning:
        return '需重修';
    }
  }

  /// 会进入复习队列的状态（需重修也按 1 天档回访）。
  bool get isReviewable =>
      this == ChunkAssetState.consolidating ||
      this == ChunkAssetState.consolidated ||
      this == ChunkAssetState.longTerm ||
      this == ChunkAssetState.relearning;
}

/// 状态机快照（纯数据，便于单测与落库/导出）。
/// stage 复用 1/3/7/14 天档序号：巩固中=0、已巩固=0/1（0=首到期 1 天窗口，1=3 天档）、
/// 长期=2/3、已掌握=4；需重修态 stage 恒为 0，回退点存 returnState/returnStage。
class ChunkAssetSnapshot {
  final ChunkAssetState state;
  final int stage;
  final ChunkAssetState? returnState;
  final int returnStage;

  const ChunkAssetSnapshot({
    required this.state,
    this.stage = 0,
    this.returnState,
    this.returnStage = -1,
  });

  static const ChunkAssetSnapshot initial =
      ChunkAssetSnapshot(state: ChunkAssetState.learning);

  @override
  bool operator ==(Object other) =>
      other is ChunkAssetSnapshot &&
      other.state == state &&
      other.stage == stage &&
      other.returnState == returnState &&
      other.returnStage == returnStage;

  @override
  int get hashCode => Object.hash(state, stage, returnState, returnStage);

  @override
  String toString() =>
      'ChunkAssetSnapshot(${state.name}, stage=$stage, return=${returnState?.name}@$returnStage)';
}

/// 词块资产状态机（纯函数，无 I/O）。
/// 非法转换一律抛 [StateError]，由测试锁定全状态 × 全事件矩阵。
class ChunkAssetMachine {
  static const int masteredStage = 4;

  /// 学习完成：仅新学态可触发。
  /// 四星全绿 → 已巩固（stage 0，首次到期 +1 天，卡进 24h 首检索窗口）；
  /// 未全绿 → 巩固中（stage 0，同样 +1 天）。两者只在档位标签上分岔，
  /// 首次复习通过后才各自升档（指令 N 规格修订：原「四星全绿直接 +3 天」作废）。
  static ChunkAssetSnapshot completeLearning(
    ChunkAssetSnapshot s, {
    required bool fourStarsGreen,
  }) {
    _require(s.state == ChunkAssetState.learning, '学习完成', s);
    return fourStarsGreen
        ? const ChunkAssetSnapshot(
            state: ChunkAssetState.consolidated, stage: 0)
        : const ChunkAssetSnapshot(
            state: ChunkAssetState.consolidating, stage: 0);
  }

  /// 学习阶段主动跳过/延期：进入巩固中，次日回访（旧「跳过→复习队列」语义）。
  static ChunkAssetSnapshot deferLearning(ChunkAssetSnapshot s) {
    _require(s.state == ChunkAssetState.learning, '学习延期', s);
    return const ChunkAssetSnapshot(
        state: ChunkAssetState.consolidating, stage: 0);
  }

  /// 复习通过：按档升一档；需重修通过则回到失败前的原位。
  static ChunkAssetSnapshot reviewPass(ChunkAssetSnapshot s) {
    switch (s.state) {
      case ChunkAssetState.consolidating:
        _require(s.stage == 0, '复习通过', s);
        return const ChunkAssetSnapshot(
            state: ChunkAssetState.consolidated, stage: 1);
      case ChunkAssetState.consolidated:
        // 首到期（+1 天）通过 → 升到 3 天档；3 天档通过 → 长期 7 天档。
        if (s.stage == 0) {
          return const ChunkAssetSnapshot(
              state: ChunkAssetState.consolidated, stage: 1);
        }
        _require(s.stage == 1, '复习通过', s);
        return const ChunkAssetSnapshot(
            state: ChunkAssetState.longTerm, stage: 2);
      case ChunkAssetState.longTerm:
        if (s.stage == 2) {
          return const ChunkAssetSnapshot(
              state: ChunkAssetState.longTerm, stage: 3);
        }
        _require(s.stage == 3, '复习通过', s);
        return const ChunkAssetSnapshot(
            state: ChunkAssetState.mastered, stage: masteredStage);
      case ChunkAssetState.relearning:
        final back = s.returnState;
        _require(
            back != null && back.isReviewable && back != ChunkAssetState.relearning,
            '复习通过（需重修回位）',
            s);
        _require(s.returnStage >= 0, '复习通过（需重修回位）', s);
        return ChunkAssetSnapshot(state: back!, stage: s.returnStage);
      case ChunkAssetState.learning:
      case ChunkAssetState.mastered:
        throw StateError('非法转换：复习通过不允许从 ${s.state.name} 出发');
    }
  }

  /// 复习失败：降档进入需重修，间隔重置回 1 天；重复失败保持需重修并保留回退点。
  static ChunkAssetSnapshot reviewFail(ChunkAssetSnapshot s) {
    switch (s.state) {
      case ChunkAssetState.consolidating:
      case ChunkAssetState.consolidated:
      case ChunkAssetState.longTerm:
        return ChunkAssetSnapshot(
          state: ChunkAssetState.relearning,
          stage: 0,
          returnState: s.state,
          returnStage: s.stage,
        );
      case ChunkAssetState.relearning:
        final back = s.returnState;
        _require(back != null && s.returnStage >= 0, '复习失败（需重修）', s);
        return ChunkAssetSnapshot(
          state: ChunkAssetState.relearning,
          stage: 0,
          returnState: back,
          returnStage: s.returnStage,
        );
      case ChunkAssetState.learning:
      case ChunkAssetState.mastered:
        throw StateError('非法转换：复习失败不允许从 ${s.state.name} 出发');
    }
  }

  /// 下一次到期时间；新学/已掌握不排期（null）。
  static DateTime? nextDue(DateTime from, ChunkAssetSnapshot s) {
    switch (s.state) {
      case ChunkAssetState.learning:
      case ChunkAssetState.mastered:
        return null;
      case ChunkAssetState.relearning:
        return from.add(const Duration(days: 1));
      case ChunkAssetState.consolidating:
        return ReviewScheduler.nextDue(from, 0);
      case ChunkAssetState.consolidated:
        return ReviewScheduler.nextDue(from, s.stage);
      case ChunkAssetState.longTerm:
        return ReviewScheduler.nextDue(from, s.stage);
    }
  }

  /// 快照自洽校验（落库/导出前使用；迁移来的旧数据不强制）。
  static void validate(ChunkAssetSnapshot s) {
    switch (s.state) {
      case ChunkAssetState.learning:
        _require(s.stage == 0 && s.returnState == null, '快照校验', s);
      case ChunkAssetState.consolidating:
        _require(s.stage == 0 && s.returnState == null, '快照校验', s);
      case ChunkAssetState.consolidated:
        _require((s.stage == 0 || s.stage == 1) && s.returnState == null,
            '快照校验', s);
      case ChunkAssetState.longTerm:
        _require(
            (s.stage == 2 || s.stage == 3) && s.returnState == null,
            '快照校验',
            s);
      case ChunkAssetState.mastered:
        _require(s.stage == masteredStage && s.returnState == null, '快照校验', s);
      case ChunkAssetState.relearning:
        _require(s.stage == 0, '快照校验', s);
        _require(
            s.returnState != null &&
                s.returnState!.isReviewable &&
                s.returnState != ChunkAssetState.relearning &&
                s.returnStage >= 0,
            '快照校验',
            s);
    }
  }

  static void _require(bool ok, String action, ChunkAssetSnapshot s) {
    if (!ok) {
      throw StateError(
          '非法转换：$action 不允许从 ${s.state.name}(stage=${s.stage}) 出发');
    }
  }
}

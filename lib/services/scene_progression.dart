import '../models/content_pack.dart';

/// 场景解锁门槛：上一场景 mastered ≥80%。
const double kSceneUnlockRatio = 0.8;

int masteredInLevel(Level level, Set<String> masteredKeys) =>
    level.chunks.where((c) => masteredKeys.contains(c.id)).length;

/// 解锁所需掌握块数（向上取整，与 ≥80% 判定同源）。
int sceneUnlockTarget(Level level) =>
    (level.chunks.length * kSceneUnlockRatio).ceil();

bool isSceneUnlocked(List<Level> levels, int index, Set<String> masteredKeys,
    {bool Function(int index)? allowed}) {
  if (index < 0 || index >= levels.length) return false;
  // 1.6.0（LIC-1）：license 只做 AND 收窄；传 null 时行为与 1.5.x 完全一致。
  if (allowed != null && !allowed(index)) return false;
  // ASR-208 §一.4：可选模块（L0 生存）恒解锁，且不进解锁链——
  // 它不是任何后续场景的前置，老用户不学它也照样能进 A。
  if (levels[index].optional) return true;
  if (index == 0) return true;
  Level? prev;
  for (var i = index - 1; i >= 0; i--) {
    if (!levels[i].optional) {
      prev = levels[i];
      break;
    }
  }
  if (prev == null) return true; // 链首（A）：没有非可选前置 → 直接可进
  if (prev.chunks.isEmpty) return true;
  return masteredInLevel(prev, masteredKeys) >=
      prev.chunks.length * kSceneUnlockRatio;
}

/// 还差多少块才能解锁 [level]（已解锁返回 0）。
int missingForUnlock(Level level, Set<String> masteredKeys) {
  final missing =
      sceneUnlockTarget(level) - masteredInLevel(level, masteredKeys);
  return missing > 0 ? missing : 0;
}

/// 地图点击进入：只有已解锁场景返回 Level，锁定场景返回 null。
Level? enterableScene(
        List<Level> levels, int index, Set<String> masteredKeys,
        {bool Function(int index)? allowed}) =>
    isSceneUnlocked(levels, index, masteredKeys, allowed: allowed)
        ? levels[index]
        : null;

/// 主推进目标 = 已解锁链上的最后一个场景（进度前沿）。
/// 全部通关（最后一关也 100% 掌握）时返回 null。
Level? progressionTarget(List<Level> levels, Set<String> masteredKeys,
    {bool Function(int index)? allowed}) {
  // ASR-208 §一.4：零基础（本机还没有任何掌握块）时，第一站 = 可选生存模块；
  // 只要有过进度，就完全跳过它，不催老用户去学 L0。
  final hasAnyProgress =
      levels.any((l) => masteredInLevel(l, masteredKeys) > 0);
  if (!hasAnyProgress) {
    for (final l in levels) {
      if (l.optional) return l;
    }
  }
  Level? last;
  for (var i = 0; i < levels.length; i++) {
    if (levels[i].optional) continue;
    if (!isSceneUnlocked(levels, i, masteredKeys, allowed: allowed)) break;
    last = levels[i];
  }
  if (last == null) return null;
  final rest = levels.where((l) => !l.optional).toList();
  if (identical(last, rest.last) &&
      masteredInLevel(last, masteredKeys) >= last.chunks.length) {
    return null;
  }
  return last;
}

/// 完成页的「下一场景」状态：名字、是否真解锁、还差几块。
class NextSceneState {
  final int index;
  final Level level;
  final bool unlocked;
  final int missing;

  const NextSceneState({
    required this.index,
    required this.level,
    required this.unlocked,
    required this.missing,
  });
}

NextSceneState? nextSceneState(
    List<Level> levels, String currentId, Set<String> masteredKeys,
    {bool Function(int index)? allowed}) {
  final idx = levels.indexWhere((lv) => lv.id == currentId);
  if (idx < 0 || idx >= levels.length - 1) return null;
  return NextSceneState(
    index: idx + 1,
    level: levels[idx + 1],
    unlocked: isSceneUnlocked(levels, idx + 1, masteredKeys, allowed: allowed),
    missing: missingForUnlock(levels[idx], masteredKeys),
  );
}

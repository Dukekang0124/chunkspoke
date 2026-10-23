import '../models/content_pack.dart';

/// 场景解锁门槛：上一场景 mastered ≥80%。
const double kSceneUnlockRatio = 0.8;

int masteredInLevel(Level level, Set<String> masteredKeys) =>
    level.chunks.where((c) => masteredKeys.contains(c.id)).length;

/// 解锁所需掌握块数（向上取整，与 ≥80% 判定同源）。
int sceneUnlockTarget(Level level) =>
    (level.chunks.length * kSceneUnlockRatio).ceil();

bool isSceneUnlocked(List<Level> levels, int index, Set<String> masteredKeys) {
  if (index < 0 || index >= levels.length) return false;
  if (index == 0) return true;
  final prev = levels[index - 1];
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
        List<Level> levels, int index, Set<String> masteredKeys) =>
    isSceneUnlocked(levels, index, masteredKeys) ? levels[index] : null;

/// 主推进目标 = 已解锁链上的最后一个场景（进度前沿）。
/// 全部通关（最后一关也 100% 掌握）时返回 null。
Level? progressionTarget(List<Level> levels, Set<String> masteredKeys) {
  Level? last;
  for (var i = 0; i < levels.length; i++) {
    if (!isSceneUnlocked(levels, i, masteredKeys)) break;
    last = levels[i];
  }
  if (last == null) return null;
  if (identical(last, levels.last) &&
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
    List<Level> levels, String currentId, Set<String> masteredKeys) {
  final idx = levels.indexWhere((lv) => lv.id == currentId);
  if (idx < 0 || idx >= levels.length - 1) return null;
  return NextSceneState(
    index: idx + 1,
    level: levels[idx + 1],
    unlocked: isSceneUnlocked(levels, idx + 1, masteredKeys),
    missing: missingForUnlock(levels[idx], masteredKeys),
  );
}

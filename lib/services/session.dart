import 'review_scheduler.dart';
import '../models/content_pack.dart';

/// 简化 SM-2 调度（M4）：以 ReviewScheduler 的 1/3/7/14 天阶梯为基底，
/// 成功推进一级、失败回退两级，索引封顶在阶梯末级（stage 3 = 14 天）。
class Sm2Scheduler {
  static const int _maxStage = 3; // ReviewScheduler.intervalsDays 最后一格

  static int advanceStage(int stage, bool correct) {
    if (correct) return (stage + 1).clamp(0, _maxStage);
    return (stage - 2).clamp(0, _maxStage);
  }

  static DateTime nextDue(DateTime from, int stage) =>
      ReviewScheduler.nextDue(from, stage);
}

/// 每日会话编排（M7）：到期复习优先；复习未清不推新学；每日新学 ≤5。
class PracticeSession {
  /// 返回当日应练词块：
  ///  - 有到期复习 → 先练复习（最多 [maxDue]），不插入新学；
  ///  - 无到期复习 → 再推新学，且每日新学 ≤ [maxNew]。
  static List<Chunk> buildPlan(
    List<Chunk> dueChunks,
    List<Chunk> allChunks, {
    int maxDue = 12,
    int maxNew = 5,
  }) {
    final due = dueChunks.take(maxDue).toList();
    if (due.isNotEmpty) return due; // 复习优先，复习未清不推新
    return allChunks.take(maxNew).toList(); // 每日新学 ≤5
  }

  /// 是否有内容可练（决定是否显示总结屏 / 冷启动空态）。
  static bool hasContent(int practicedCount) => practicedCount > 0;
}

/// 数据迁移（M4）：v1.1.0 首启检测旧数据 → 重置。
class Migration {
  static const String currentDataVersion = '1.1.0';

  /// 无版本标记或版本低于当前 → 需重置（旧版进度清空，从第一课重新开始）。
  static bool needsReset(String? storedVersion) {
    if (storedVersion == null) return true;
    return _compare(storedVersion, currentDataVersion) < 0;
  }

  static int _compare(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final x = pa[i], y = pb[i];
      if (x != y) return x < y ? -1 : 1;
    }
    return 0;
  }
}

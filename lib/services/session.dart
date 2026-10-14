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

/// 每日会话编排（M4）：到期优先，补新学至 3–5，最后给总结屏。
class PracticeSession {
  /// 返回当日应练词块：到期最多取 [maxDue] 个；不足 [minNew] 个则补未学新词。
  static List<Chunk> buildPlan(
    List<Chunk> dueChunks,
    List<Chunk> allChunks, {
    int maxDue = 10,
    int minNew = 4,
  }) {
    final due = dueChunks.take(maxDue).toList();
    if (due.length >= minNew) return due;
    final taken = due.map((c) => c.id).toSet();
    final fresh = allChunks
        .where((c) => !taken.contains(c.id))
        .take((minNew - due.length).clamp(0, minNew))
        .toList();
    return [...due, ...fresh];
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

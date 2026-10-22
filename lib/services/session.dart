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

/// 每日会话编排（v1.5.2 六步）：新块 ≤6 个（六步闭环）+ 旧块复习（后四步）。
class PracticeSession {
  /// 返回当日应练词块：
  ///  - 有到期复习 → 先练复习（最多 [maxDue]），不插入新学；
  ///  - 无到期复习 → 再推新学，且每日新学 ≤ [maxNew]。
  static List<Chunk> buildPlan(
    List<Chunk> dueChunks,
    List<Chunk> allChunks, {
    int maxDue = 12,
    int maxNew = 6,
  }) {
    final due = dueChunks.take(maxDue).toList();
    if (due.isNotEmpty) return due; // 复习优先，复习未清不推新
    return allChunks.take(maxNew).toList(); // 每日新学 ≤6
  }

  /// 每日会话 = 新块（≤[maxNew]，各走六步）+ 到期复习块（≤[maxReview]，各走后四步）。
  static DailyPlan dailyPlan({
    required List<Chunk> dueChunks,
    required List<Chunk> newChunks,
    int maxNew = 6,
    int maxReview = 6,
  }) {
    return DailyPlan(
      newChunks: newChunks.take(maxNew).toList(),
      reviewChunks: dueChunks.take(maxReview).toList(),
    );
  }

  /// 由到期复习块构造一个「合成场景」，供 review 模式的 PracticeLoop 使用：
  /// 每个块的开口说句目标 = 原场景中「包含该块」的目标句（找不到则回退为该块自身）。
  static Level reviewLevel(ContentPack content, List<Chunk> chunks) {
    final sentences = <TargetSentence>[];
    for (final c in chunks) {
      TargetSentence? found;
      for (final lv in content.levels) {
        for (final s in lv.sentences) {
          if (s.chunkIds.contains(c.id)) {
            found = s;
            break;
          }
        }
        if (found != null) break;
      }
      sentences.add(found ??
          TargetSentence(
              id: c.id, text: c.text, meaningCN: c.meaningCN, chunkIds: [c.id]));
    }
    return Level(
        id: 'review',
        theme: 'Review',
        sceneImage: '',
        chunks: chunks,
        sentences: sentences);
  }

  /// 是否有内容可练（决定是否显示总结屏 / 冷启动空态）。
  static bool hasContent(int practicedCount) => practicedCount > 0;
}

/// 每日会话计划：新块（六步）+ 到期复习块（后四步）。
class DailyPlan {
  final List<Chunk> newChunks;
  final List<Chunk> reviewChunks;
  const DailyPlan({required this.newChunks, required this.reviewChunks});
  int get total => newChunks.length + reviewChunks.length;
}

/// 非破坏式 schema 版本管理（A0 红线）：
///  - `Migration.currentDataVersion` 是「破坏式重置」标记，v1.1.0 起冻结，永不再上调；
///  - `SchemaMigration.currentSchema` 是「增量、非破坏」结构版本，只做 ALTER ADD COLUMN（带默认值），
///    绝不 DROP / 改名 / 清空，升级前后用户进度（掌握块/连击/打卡/自由造句计数）完整保留。
class SchemaMigration {
  /// v1.4.0 基线：无新增列，schema 记 1。
  static const int currentSchema = 1;
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

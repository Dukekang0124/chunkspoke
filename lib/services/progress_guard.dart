import 'dart:async';

import '../models/content_pack.dart';
import 'crash_log.dart';
import 'loaders.dart';
import 'progress_integrity.dart';

/// ASR-211 修复 3：自愈的「全局时机」入口（四时机的 ① 冷启动 与 ② 回前台）。
///
/// 四时机 =
///   ① 冷启动：[bootstrap] 末尾 unawaited 跑一次，存量脏断点开门即修；
///   ② 回前台：地图页 lifecycle resumed 跑一次（同一入口，节流复用）；
///   ③ 打开模块：`PracticeLoop._init` 里的 audit → heal（锚定会话当场归位）；
///   ④ 自检修复：诊断页「一键修复」→ [ProgressIntegrity.reconcileAll]。
///
/// 为什么要有 ①②：非锚定会话（补练 / 复习 / 自选块）不写断点，也不该在子集里
/// 猜整模块的锚点。把「整模块归位」放到全局时机，进来时台账已经是干净的。
///
/// 失败一律静默留痕（CrashLog），绝不影响首帧；重入与频率由本类自己挡。
class ProgressGuard {
  ProgressGuard._();

  /// 两次全局归位的最小间隔（回前台反复触发时不至于狂写库）。
  static const Duration minInterval = Duration(minutes: 1);

  static DateTime? _lastRun;
  static bool _running = false;

  /// 仅供测试复位节流状态。
  static void resetForTest() {
    _lastRun = null;
    _running = false;
  }

  static Future<ReconcileResult?> run(
    ProgressService p,
    ContentPack content, {
    required String reason,
    bool force = false,
  }) async {
    if (_running) return null;
    final now = DateTime.now();
    if (!force && _lastRun != null && now.difference(_lastRun!) < minInterval) {
      return null;
    }
    _running = true;
    try {
      final r = await ProgressIntegrity.reconcileAll(p, content, reason: reason);
      _lastRun = now;
      return r;
    } catch (e, st) {
      CrashLog.write('ProgressGuard($reason): $e', st);
      return null;
    } finally {
      _running = false;
    }
  }

  /// 冷启动腿：不阻塞首帧，异常不冒泡。
  static void scheduleColdStart(ProgressService p, ContentPack content) {
    unawaited(run(p, content, reason: 'cold_start', force: true)
        .catchError((Object e, StackTrace st) {
      CrashLog.write('ProgressGuard.coldStart: $e', st);
      return null;
    }));
  }
}

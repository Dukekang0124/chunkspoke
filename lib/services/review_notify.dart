import 'loaders.dart';
import 'notification_service.dart';

/// 把「到期复习提醒」与真实资产排期对齐：
/// 开关关闭 → 取消；无到期 → 取消；有到期 → 按最早到期时间重排一次。
/// 全程吞错：通知失败绝不影响练习主链路。
Future<void> syncReviewReminder(ProgressService p) async {
  try {
    if (!p.reviewNotifEnabled) {
      await NotificationService.instance.cancelReviewDue();
      return;
    }
    final due = await p.chunkStore.earliestDueTimestamp();
    if (due == null) {
      await NotificationService.instance.cancelReviewDue();
    } else {
      await NotificationService.instance.scheduleReviewDue(due);
    }
  } catch (_) {}
}

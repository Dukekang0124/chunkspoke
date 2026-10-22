import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/notification_service.dart';

/// 波 1-C：到期复习提醒的排期纯逻辑。
void main() {
  test('未来到期：按原时刻提醒', () {
    final now = DateTime(2026, 1, 1, 9);
    final due = DateTime(2026, 1, 2, 9);
    expect(reviewReminderAt(now, due.millisecondsSinceEpoch), due);
  });

  test('已到期：5 分钟后提醒一次（不静默错过）', () {
    final now = DateTime(2026, 1, 2, 10);
    final due = DateTime(2026, 1, 2, 9);
    expect(reviewReminderAt(now, due.millisecondsSinceEpoch),
        now.add(const Duration(minutes: 5)));
  });

  test('恰好等于 now：视为已到期', () {
    final now = DateTime(2026, 1, 2, 9);
    expect(reviewReminderAt(now, now.millisecondsSinceEpoch),
        now.add(const Duration(minutes: 5)));
  });
}

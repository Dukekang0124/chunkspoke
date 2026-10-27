import 'package:flutter/foundation.dart';

import '../storage/store.dart';
import '../storage/store_factory.dart';

/// 会话内唯一的对外数字：今日已复习 N 块。
/// 不实现 streak / 积分 / 进度墙（红线「防焦虑」）。
class AppSession {
  final ValueNotifier<int> reviewedToday = ValueNotifier<int>(0);

  /// null = 尚未探测；空串 = 可用；非空 = 不可用原因。
  final ValueNotifier<String?> storageError = ValueNotifier<String?>(null);

  ProgressStore? store;

  Future<void> bootstrap() async {
    final probe = store ?? createProgressStore();
    try {
      await probe.open();
      store = probe;
      storageError.value = '';
    } catch (e) {
      storageError.value = e.toString();
    }
  }

  void markReviewed() => reviewedToday.value += 1;

  void dispose() {
    reviewedToday.dispose();
    storageError.dispose();
  }
}

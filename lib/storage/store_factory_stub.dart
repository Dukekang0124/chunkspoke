import 'store.dart';

/// 非 Web 环境（单测跑在 VM 上）没有 IndexedDB，退回内存实现。
ProgressStore createProgressStore() => MemoryProgressStore();

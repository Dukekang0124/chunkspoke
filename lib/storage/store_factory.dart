import 'store.dart';
import 'store_factory_stub.dart'
    if (dart.library.js_interop) 'store_factory_web.dart' as impl;

/// Web 构建走 IndexedDB，VM 单测走内存实现。
ProgressStore createProgressStore() => impl.createProgressStore();

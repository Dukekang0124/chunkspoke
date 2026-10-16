import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 崩溃日志落盘（documents/crash_log.txt）：
/// - Dart 层任何未捕获异常都追加记录，供下一轮 `tools/crash_capture.ps1` 取证；
/// - 记录器自身必须零风险：写失败静默，绝不引发二次异常。
class CrashLog {
  static bool _writing = false;

  static void write(String head, StackTrace? st) {
    if (_writing) return; // 防雪崩：连续崩溃时丢弃重复记录
    _writing = true;
    () async {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final f = File('${dir.path}/crash_log.txt');
        final ts = DateTime.now().toIso8601String();
        await f.writeAsString('[$ts] $head\n${st ?? ''}\n----\n',
            mode: FileMode.append);
      } catch (_) {
        // 静默：崩溃记录失败不允许再抛。
      } finally {
        _writing = false;
      }
    }();
  }
}

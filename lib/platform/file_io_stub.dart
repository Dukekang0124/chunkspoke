import 'dart:async';

/// 非 Web 环境（单测）没有文件下载/选择，调用即失败，避免静默无操作。
Future<void> saveTextFile(String name, String content) async {
  throw UnsupportedError('非 Web 环境不支持文件下载');
}

Future<String?> pickTextFile() async {
  throw UnsupportedError('非 Web 环境不支持文件选择');
}

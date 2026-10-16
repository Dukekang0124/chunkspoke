import 'dart:io';
import 'package:crypto/crypto.dart';

/// 计算文件 SHA-256（小写十六进制）。
Future<String> fileSha256(String path) async {
  final bytes = await File(path).readAsBytes();
  return sha256.convert(bytes).toString();
}

/// 比对期望哈希：忽略大小写与首尾空白；expected 为空视为“不校验”。
bool sha256Matches(String actualHex, String expectedHex) {
  final a = actualHex.trim().toLowerCase();
  final e = expectedHex.trim().toLowerCase();
  if (e.isEmpty) return true;
  return a == e;
}

/// 下载被用户取消时抛出，区别于真实下载失败（前者静默、不提示“下载失败”）。
class UpdateCancelledException implements Exception {
  const UpdateCancelledException();
  @override
  String toString() => 'UpdateCancelledException';
}

import 'dart:io';
import 'package:crypto/crypto.dart';

/// 计算文件 SHA-256（小写十六进制）。
///
/// 流式计算：66MB 安装包若一次性 readAsBytes，低内存机型有 OOM 风险。
Future<String> fileSha256(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
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

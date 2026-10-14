import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class VersionInfo {
  final String version;
  final int buildNumber;
  final String apkUrl;
  final String contentUrl;
  final String notes;
  VersionInfo({
    required this.version,
    required this.buildNumber,
    required this.apkUrl,
    required this.contentUrl,
    required this.notes,
  });
  factory VersionInfo.fromJson(Map<String, dynamic> j) => VersionInfo(
        version: j['version']?.toString() ?? '0.0.0',
        buildNumber: j['buildNumber'] as int? ?? 0,
        apkUrl: j['apkUrl']?.toString() ?? '',
        contentUrl: j['contentUrl']?.toString() ?? '',
        notes: j['notes']?.toString() ?? '',
      );
}

/// 更新机制（方案 v2.0 §9）：App 内下载 + 真实进度 + 权限引导 + 平台通道安装。
class UpdateService {
  static const String remoteUrl = ''; // 部署后填入远端 version.json 地址
  static const MethodChannel _ch = MethodChannel('chunkspoke/update');

  Future<VersionInfo> local() async {
    final s = await rootBundle.loadString('assets/version.json');
    return VersionInfo.fromJson(jsonDecode(s) as Map<String, dynamic>);
  }

  Future<(bool, VersionInfo)> check([String? remoteUrlOverride]) async {
    final cur = await local();
    final url = (remoteUrlOverride == null || remoteUrlOverride.isEmpty)
        ? remoteUrl
        : remoteUrlOverride;
    if (url.isEmpty) return (false, cur);
    try {
      final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        final latest =
            VersionInfo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
        if (latest.buildNumber > cur.buildNumber) return (true, latest);
      }
    } catch (_) {
      // 网络异常 → 视为最新
    }
    return (false, cur);
  }

  /// App 内下载 APK，进度来自已下载字节（real progress）。
  Future<String> downloadApk(
    String url,
    String fileName,
    void Function(int received, int total) onProgress,
  ) async {
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/updates/$fileName');
    await dest.parent.create(recursive: true);
    final req = http.Request('GET', Uri.parse(url));
    final resp = await http.Client().send(req);
    final total = resp.contentLength ?? 0;
    final sink = dest.openWrite();
    int received = 0;
    await for (final chunk in resp.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress(received, total);
    }
    await sink.close();
    return dest.path;
  }

  Future<bool> canInstallPackages() async {
    try {
      return await _ch.invokeMethod('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openInstallSettings() async {
    try {
      await _ch.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  Future<void> installApk(String path) async {
    try {
      await _ch.invokeMethod('installApk', path);
    } catch (_) {}
  }
}

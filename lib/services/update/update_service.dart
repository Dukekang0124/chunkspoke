import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'version_compare.dart';
import 'sha256_util.dart';

/// 远端版本信息（对齐 version.json 规范）。
class VersionInfo {
  final String versionName;
  final int versionCode;
  final String url; // APK 直链（HTTPS）
  final String sha256;
  final int size; // 字节数
  final String notes;
  VersionInfo({
    required this.versionName,
    required this.versionCode,
    required this.url,
    required this.sha256,
    required this.size,
    required this.notes,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> j) => VersionInfo(
        versionName: (j['versionName'] ?? j['version'] ?? '0.0.0').toString(),
        versionCode: parseVersionCode(j['versionCode'] ?? j['buildNumber']),
        url: (j['url'] ?? j['apkUrl'] ?? '').toString(),
        sha256: (j['sha256'] ?? '').toString(),
        size: (j['size'] as int?) ?? 0,
        notes: (j['notes'] ?? '').toString(),
      );
}

/// 检查结果状态：有新版 / 已是最新 / 检查失败（网络或未配置）。
enum CheckStatus { update, latest, error }

class CheckResult {
  final CheckStatus status;
  final VersionInfo info;
  const CheckResult(this.status, this.info);
}

/// 本地 APK 是否完整：期望大小未知(≤0)时只要非空即视为可用；否则要求字节数精确匹配。
bool sizeMatches(int actual, int expected) =>
    expected <= 0 ? actual > 0 : actual == expected;

/// 可取消的下载句柄。
class DownloadHandle {
  final Future<String> future; // 完成时返回本地 APK 路径
  final void Function() cancel;
  DownloadHandle({required this.future, required this.cancel});
}

/// 应用内自更新服务（方案 v2.0 §9）：拉取 version.json → 数值比较 → 流式下载
/// （真实进度 + 可取消）→ SHA-256 校验 → 原生通道 FileProvider 调起安装。
/// 「更新源」为应用内**常量**（GitHub raw 直链），不经用户输入。
class UpdateService {
  /// 内置更新源：GitHub raw 直链（应用常量，用户不可见/不可改）。
  /// 可用 `--dart-define=CHUNKSPOKE_UPDATE_URL=...` 在构建期覆盖（调试/迁移用）。
  static const String defaultRemoteUrl = String.fromEnvironment(
    'CHUNKSPOKE_UPDATE_URL',
    defaultValue:
        'https://raw.githubusercontent.com/Dukekang0124/chunkspoke/main/version.json',
  );

  /// 下载落盘文件名（固定；供「本地已有完整包则直接安装」复用）。
  static const String apkFileName = 'chunkspoke_update.apk';
  static const MethodChannel _ch = MethodChannel('chunkspoke/update');

  /// 本机真实版本：取自 PackageInfo（避免被构建期 --build-number 覆盖、
  /// 也避免 assets/version.json 与安装包 versionCode 不一致导致误判）。
  Future<VersionInfo> local() async {
    final i = await PackageInfo.fromPlatform();
    return VersionInfo(
      versionName: i.version,
      versionCode: int.tryParse(i.buildNumber) ?? 0,
      url: '',
      sha256: '',
      size: 0,
      notes: '',
    );
  }

  /// 拉取远端 version.json 与本机版本比较，返回**三态**结果：
  ///  - update：有更高 versionCode（弹窗）；
  ///  - latest：等于或更低（toast 已是最新）；
  ///  - error：未配置 / 非 200 / 网络或解析异常（toast 检查失败）。
  /// [client] 可注入（单测用 mock）；[current] 可注入本机版本（单测跳过 PackageInfo）。
  Future<CheckResult> check(
      {String? overrideUrl, http.Client? client, VersionInfo? current}) async {
    final cur = current ?? await local();
    final url = (overrideUrl != null && overrideUrl.isNotEmpty)
        ? overrideUrl
        : defaultRemoteUrl;
    // 未配置（空）→ 明确归为失败，避免「假装已最新」。
    if (url.isEmpty) {
      return CheckResult(CheckStatus.error, cur);
    }
    final created = client == null;
    client ??= http.Client();
    try {
      final r =
          await client.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return CheckResult(CheckStatus.error, cur);
      final latest =
          VersionInfo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      if (isNewerVersion(cur.versionCode, latest.versionCode)) {
        return CheckResult(CheckStatus.update, latest);
      }
      return CheckResult(CheckStatus.latest, cur);
    } catch (_) {
      return CheckResult(CheckStatus.error, cur);
    } finally {
      if (created) client?.close();
    }
  }

  /// 本地已下载 APK 的路径（FileProvider 可达的应用私有外部目录）。
  Future<String> apkPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/updates/$apkFileName';
  }

  /// 「本地已有完整包则复用」：若缓存 APK 存在、大小匹配且 SHA-256 校验通过，
  /// 直接返回其路径（安装界面取消后下次启动免重新下载）；否则返回 null。
  Future<String?> reusableCachedApk(VersionInfo info) async {
    try {
      final path = await apkPath();
      final f = File(path);
      if (!await f.exists()) return null;
      if (!sizeMatches(await f.length(), info.size)) return null;
      if (info.sha256.isNotEmpty) {
        final actual = await fileSha256(path);
        if (!sha256Matches(actual, info.sha256)) {
          await f.delete(); // 损坏缓存：删除，待重下
          return null;
        }
      }
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 流式下载 APK 到应用私有外部文件目录 updates/（FileProvider 可达），
  /// 支持取消；进度为已下载字节 / 总字节。
  DownloadHandle downloadApkCancellable(
    String url,
    String fileName,
    void Function(int received, int total) onProgress,
  ) {
    final client = http.Client();
    final completer = Completer<String>();
    StreamSubscription<List<int>>? sub;
    Future<void> start() async {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final dest = File('${dir.path}/updates/$fileName');
        await dest.parent.create(recursive: true);
        final req = http.Request('GET', Uri.parse(url));
        final resp = await client.send(req);
        final total = resp.contentLength ?? 0;
        final sink = dest.openWrite();
        int received = 0;
        sub = resp.stream.listen(
          (chunk) {
            sink.add(chunk);
            received += chunk.length;
            onProgress(received, total);
          },
          onDone: () async {
            await sink.close();
            completer.complete(dest.path);
          },
          onError: (e, st) async {
            try {
              await sink.close();
            } catch (_) {}
            try {
              if (await dest.exists()) await dest.delete();
            } catch (_) {}
            completer.completeError(e);
          },
          cancelOnError: true,
        );
      } catch (e) {
        completer.completeError(e);
      }
    }

    start(); // 触发下载（fire-and-forget，结果经 completer 传递）
    return DownloadHandle(
      future: completer.future,
      cancel: () {
        sub?.cancel();
        client.close();
        if (!completer.isCompleted) {
          completer.completeError(const UpdateCancelledException());
        }
      },
    );
  }

  Future<String> downloadApk(String url, String fileName,
          void Function(int received, int total) onProgress) =>
      downloadApkCancellable(url, fileName, onProgress).future;

  /// SHA-256 校验：不匹配则删除损坏文件并返回 false（绝不安装损坏包）。
  Future<bool> verifySha256(String path, String expected) async {
    if (expected.isEmpty) return true;
    try {
      final actual = await fileSha256(path);
      if (sha256Matches(actual, expected)) return true;
    } catch (_) {
      return false;
    }
    try {
      await File(path).delete();
    } catch (_) {}
    return false;
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

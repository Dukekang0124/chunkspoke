import 'dart:convert';

import 'package:flutter/material.dart';
import '../../services/database.dart';
import '../../ui/theme.dart';
import 'update_service.dart';
import 'update_dialog.dart';
import 'sha256_util.dart';

/// 每次冷启动最多检查一次（避免重复弹窗/重复请求）。
bool _didStartupCheck = false;

/// 更新流程是否正在执行：防止「启动静默检查」与「设置页手动检查」并发，
/// 出现「更新弹窗已展示 + 底部又提示检查失败」的自相矛盾提示。
bool _flowRunning = false;

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}

// —— 「稍后」防骚扰记忆（学英语开口练的 kaikou_apk_skip）——
// 包大、下载慢的场景下，每次冷启动都弹同一个版本会招人烦：
// 点过「暂不」的版本 7 天内启动不再自动弹；设置页手动检查不受限；装上新版自然失效。
const String _skipKvKey = 'updateSkip';
const Duration _skipWindow = Duration(days: 7);

Future<bool> _skipMemoryHits(int versionCode) async {
  try {
    final raw = await AppDatabase().getKv(_skipKvKey);
    if (raw == null || raw.isEmpty) return false;
    final j = jsonDecode(raw);
    if (j is! Map || j['code'] != versionCode) return false;
    final at = (j['at'] as num?)?.toInt() ?? 0;
    return DateTime.now().millisecondsSinceEpoch - at < _skipWindow.inMilliseconds;
  } catch (_) {
    return false; // 记忆读不到就正常弹：宁可多提醒，也别让用户漏掉更新
  }
}

Future<void> _rememberSkip(int versionCode) async {
  try {
    await AppDatabase().setKv(_skipKvKey, jsonEncode({
      'code': versionCode,
      'at': DateTime.now().millisecondsSinceEpoch,
    }));
  } catch (_) {}
}

/// 完整更新流程：检查 → 弹窗 → 下载（进度+取消）→ SHA-256 校验 → 安装/权限引导。
/// 三态：有新版→弹窗；已是最新→toast「已是最新版本」；检查失败→toast「检查失败，请稍后再试」。
/// [silentIfLatest]=true 时，已最新/失败均静默（用于启动自动检查）。
Future<void> runUpdateFlow(BuildContext context,
    {bool silentIfLatest = false}) async {
  if (!context.mounted) return;
  // 已有流程在执行（含下载中）：直接忽略，避免重复请求与「弹窗 + 失败 toast」并存。
  if (_flowRunning) return;
  _flowRunning = true;
  try {
    final svc = UpdateService();
    final res = await svc.check();
    if (!context.mounted) return;
    switch (res.status) {
      case CheckStatus.update:
        // 启动自动检查时尊重「稍后」记忆；手动检查不受限。
        if (silentIfLatest && await _skipMemoryHits(res.info.versionCode)) {
          return;
        }
        if (!context.mounted) return;
        final action = await showUpdateDialog(context, res.info);
        if (!context.mounted) return;
        switch (action) {
          case UpdateDialogAction.later:
            await _rememberSkip(res.info.versionCode);
            return;
          case UpdateDialogAction.browser:
            await _openInBrowser(context, svc, res.info);
            return;
          case UpdateDialogAction.install:
            await _downloadAndInstall(context, svc, res.info);
            break;
        }
        break;
      case CheckStatus.latest:
        if (!silentIfLatest) _toast(context, '已是最新版本');
        break;
      case CheckStatus.error:
        if (!silentIfLatest) _toast(context, '检查失败，请稍后再试');
        break;
    }
  } finally {
    _flowRunning = false;
  }
}

/// 启动自动检查（进入首屏后静默请求一次，失败静默；有新版才弹窗；每次冷启动最多一次）。
void runUpdateCheck(BuildContext context) {
  if (_didStartupCheck) return;
  _didStartupCheck = true;
  // 等首帧后再发起，确保 dialog 有可用 context。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) runUpdateFlow(context, silentIfLatest: true);
  });
}

Future<void> _downloadAndInstall(
    BuildContext context, UpdateService svc, VersionInfo info) async {
  if (info.url.trim().isEmpty) {
    _toast(context, '更新源未配置下载地址，请联系开发者');
    return;
  }

  // ④ 缓存复用：本地已有完整包（大小匹配 + SHA-256 通过）→ 直接安装，不重新下载。
  final cached = await svc.reusableCachedApk(info);
  if (!context.mounted) return;
  if (cached != null) {
    await _installWithPermission(context, svc, cached);
    return;
  }

  final candidates = info.downloadUrls;
  final useParts = info.parts.isNotEmpty;
  final progress = ValueNotifier<double>(0);
  final received = ValueNotifier<int>(0);
  final status = ValueNotifier<String>('正在连接更新服务器…');
  var startedAt = DateTime.now();
  var baseBytes = 0; // 本阶段起点字节：速度只统计本阶段新增，续传时不会虚高
  DownloadHandle? current;
  // 过慢换源：<100KB/s 持续 10s 且还有备用源 → 主动切源。
  // 兄弟项目（又花钱了 apk_parts.dart）的结论是「失败计数拉黑比一次性测速稳」，
  // 这里用「持续低速率」而不是瞬时值，避免慢启动被误判。
  var slowSwitch = false;
  var canSwitch = false;

  void report(int r, int t) {
    received.value = r;
    progress.value = t > 0 ? (r / t).clamp(0.0, 1.0).toDouble() : 0.0;
    if (r <= 0) return;
    final elapsed = DateTime.now().difference(startedAt);
    final secs = elapsed.inMilliseconds / 1000;
    if (secs < 0.8) {
      status.value = '已连接，正在接收数据…';
      return;
    }
    final bps = (r - baseBytes) / secs; // 平均速度：比瞬时值稳，不会在 0 与峰值之间乱跳
    final speedText = bps >= 1024 * 1024
        ? '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s'
        : '${(bps / 1024).toStringAsFixed(0)} KB/s';
    final double remainSec = bps > 0 && t > 0 ? (t - r) / bps : -1.0;
    status.value = remainSec > 0
        ? '下载中 · $speedText · 剩 ${_eta(remainSec)}'
        : '下载中 · $speedText';

    if (!slowSwitch && secs >= 10 && bps < 100 * 1024 && canSwitch) {
      slowSwitch = true;
      status.value = '当前源过慢（<100KB/s），切换备用源…';
      current?.cancel();
    }
  }

  if (!context.mounted) return;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => DownloadProgressCard(
      progress: progress,
      received: received,
      total: info.size,
      status: status,
      onCancel: () {
        current?.cancel();
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      },
    ),
  );

  String? path;
  Object? lastError;

  // —— 阶段 1：分片下载（jsDelivr/对象存储分块，单文件 ≤20MB，国内可达优先）——
  // 分片与整包直链是同一文件：.part 里已有的字节 = 完整文件前缀，
  // 因此分片失败换直链时**保留断点续传，不从头下**（对应真机「0% 卡死」的根治路径）。
  if (useParts) {
    canSwitch = candidates.isNotEmpty;
    baseBytes = 0;
    current = svc.downloadApkPartsCancellable(
        info.parts, UpdateService.apkFileName, report,
        expectedSize: info.size, partTag: apkPartTag(info.sha256));
    try {
      path = await current.future;
    } on UpdateCancelledException {
      if (slowSwitch) {
        slowSwitch = false;
        lastError = const UpdateDownloadException('分片源速度过低，切换整包直链（保留断点）');
      } else {
        return; // 用户取消，静默（已下载部分保留，下次续传）
      }
    } catch (e) {
      lastError = e;
      debugPrint('[update] 分片下载失败，转整包直链：$e');
    }
    current = null;
  }

  // —— 阶段 2：整包直链（GitHub Releases，逐源尝试）——
  for (var i = 0; i < candidates.length && path == null; i++) {
    canSwitch = i < candidates.length - 1;
    baseBytes = received.value; // 速度只统计本阶段新增
    startedAt = DateTime.now();
    status.value = useParts
        ? '分片源不可用，改用整包直链（${i + 1}/${candidates.length}）…'
        : '切换备用下载源（${i + 1}/${candidates.length}）…';
    current = svc.downloadApkCancellable(
        candidates[i], UpdateService.apkFileName, report,
        expectedSize: info.size, partTag: apkPartTag(info.sha256));
    try {
      path = await current.future;
    } on UpdateCancelledException {
      if (slowSwitch) {
        // 主动换源：分片与直链字节相同，保留 .part 断点，下一源续传
        slowSwitch = false;
        lastError = const UpdateDownloadException('当前下载源速度过低，已切换备用源');
        continue;
      }
      return; // 用户取消，静默（已下载部分保留，下次续传）
    } catch (e) {
      lastError = e;
      debugPrint('[update] 下载源 ${i + 1}/${candidates.length} 失败：$e');
    }
  }

  if (path == null) {
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (!context.mounted) return;
    // 不再只弹一句 toast：直接给出「浏览器下载」这条更可靠的路。
    await _offerBrowserFallback(
        context,
        svc,
        info,
        lastError is UpdateDownloadException
            ? lastError.message
            : '下载失败，请稍后再试');
    return;
  }
  if (context.mounted && Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
  }

  // 完整性校验：不匹配则删除损坏文件并提示，绝不安装。
  if (info.sha256.isNotEmpty) {
    final ok = await svc.verifySha256(path, info.sha256);
    if (!context.mounted) return;
    if (!ok) {
      await _offerBrowserFallback(
          context, svc, info, '安装包校验失败（下载中断或源被篡改）');
      return;
    }
  }

  if (!context.mounted) return;
  await _installWithPermission(context, svc, path);
}

/// 调起安装；Android 8+ 未授权时应用内引导至本应用「安装未知应用」权限页（不跳浏览器）。
/// 安装界面取消/返回不改动已下载的 APK 缓存（下次启动可直接复用）。
Future<void> _installWithPermission(
    BuildContext context, UpdateService svc, String path) async {
  final canInstall = await svc.canInstallPackages();
  if (!context.mounted) return;
  if (canInstall) {
    await _tryInstall(context, svc, path);
    return;
  }
  final goSettings = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('需要安装权限', style: TextStyle(color: Colors.white)),
      content: const Text(
        '系统要求先授权 ChunkSpoke「安装未知应用」。\n点“前往设置”打开本应用权限页，打开后返回点“继续安装”。',
        style: TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('前往设置', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  if (goSettings != true) return;
  await svc.openInstallSettings();
  if (!context.mounted) return;
  final cont = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('继续安装', style: TextStyle(color: Colors.white)),
      content: const Text('已授权？点“继续安装”调起系统安装界面。',
          style: TextStyle(color: Colors.white70)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('稍后', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('继续安装', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  if (cont == true && context.mounted) {
    await _installWithPermission(context, svc, path); // 重检
  }
}

/// 调起安装失败时给出明确提示（旧实现静默吞异常 → 用户看到「点了没反应」）。
Future<void> _tryInstall(
    BuildContext context, UpdateService svc, String path) async {
  try {
    await svc.installApk(path);
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, e is UpdateDownloadException ? e.message : '无法调起安装，请重试');
  }
}

/// 把下载地址交给系统浏览器（不自己拉 66MB）。
Future<void> _openInBrowser(
    BuildContext context, UpdateService svc, VersionInfo info) async {
  try {
    await svc.openInBrowser(info.browserUrl);
    if (!context.mounted) return;
    _toast(context, '已交给浏览器下载，下载完成后点通知里的安装包即可');
  } catch (e) {
    if (!context.mounted) return;
    _toast(context,
        e is UpdateDownloadException ? e.message : '无法打开浏览器下载地址');
  }
}

/// 剩余时间文案：<60s → “52 秒”；分钟级 → “1 分 20 秒”；小时级 → “1 小时 5 分”。
String _eta(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '未知';
  final s = seconds.round();
  if (s < 60) return '$s 秒';
  final m = s ~/ 60;
  if (m < 60) return '$m 分 ${s % 60} 秒';
  return '${m ~/ 60} 小时 ${m % 60} 分';
}

/// 应用内下载/校验失败后的兜底：问一句要不要改用浏览器下载。
Future<void> _offerBrowserFallback(BuildContext context, UpdateService svc,
    VersionInfo info, String reason) async {
  if (info.browserUrl.trim().isEmpty) {
    _toast(context, reason);
    return;
  }
  final go = await showBrowserFallbackDialog(context, reason);
  if (!context.mounted || !go) return;
  await _openInBrowser(context, svc, info);
}

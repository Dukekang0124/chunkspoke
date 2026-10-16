import 'package:flutter/material.dart';
import '../../ui/theme.dart';
import 'update_service.dart';
import 'update_dialog.dart';
import 'sha256_util.dart';

/// 每次冷启动最多检查一次（避免重复弹窗/重复请求）。
bool _didStartupCheck = false;

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}

/// 完整更新流程：检查 → 弹窗 → 下载（进度+取消）→ SHA-256 校验 → 安装/权限引导。
/// 三态：有新版→弹窗；已是最新→toast「已是最新版本」；检查失败→toast「检查失败，请稍后再试」。
/// [silentIfLatest]=true 时，已最新/失败均静默（用于启动自动检查）。
Future<void> runUpdateFlow(BuildContext context,
    {bool silentIfLatest = false}) async {
  if (!context.mounted) return;
  final svc = UpdateService();
  final res = await svc.check();
  if (!context.mounted) return;
  switch (res.status) {
    case CheckStatus.update:
      final go = await showUpdateDialog(context, res.info);
      if (!go) return;
      await _downloadAndInstall(context, svc, res.info);
      break;
    case CheckStatus.latest:
      if (!silentIfLatest) _toast(context, '已是最新版本');
      break;
    case CheckStatus.error:
      if (!silentIfLatest) _toast(context, '检查失败，请稍后再试');
      break;
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
  // ④ 缓存复用：本地已有完整包（大小匹配 + SHA-256 通过）→ 直接安装，不重新下载。
  final cached = await svc.reusableCachedApk(info);
  if (!context.mounted) return;
  if (cached != null) {
    await _installWithPermission(context, svc, cached);
    return;
  }

  final progress = ValueNotifier<double>(0);
  final received = ValueNotifier<int>(0);
  final handle = svc.downloadApkCancellable(
      info.url, UpdateService.apkFileName, (r, t) {
    received.value = r;
    progress.value = t > 0 ? r / t : 0;
  });
  if (!context.mounted) return;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => DownloadProgressCard(
      progress: progress,
      received: received,
      total: info.size,
      onCancel: () {
        handle.cancel();
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      },
    ),
  );

  String? path;
  try {
    path = await handle.future;
  } on UpdateCancelledException {
    return; // 用户取消，静默
  } catch (e) {
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (context.mounted) _toast(context, '下载失败，请稍后再试');
    return;
  }
  if (context.mounted && Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
  }

  // 完整性校验：不匹配则删除损坏文件并提示，绝不安装。
  if (info.sha256.isNotEmpty) {
    final ok = await svc.verifySha256(path!, info.sha256);
    if (!ok) {
      _toast(context, '校验失败，请重试');
      return;
    }
  }

  await _installWithPermission(context, svc, path!);
}

/// 调起安装；Android 8+ 未授权时应用内引导至本应用「安装未知应用」权限页（不跳浏览器）。
/// 安装界面取消/返回不改动已下载的 APK 缓存（下次启动可直接复用）。
Future<void> _installWithPermission(
    BuildContext context, UpdateService svc, String path) async {
  if (await svc.canInstallPackages()) {
    await svc.installApk(path);
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
  if (cont == true) await _installWithPermission(context, svc, path); // 重检
}

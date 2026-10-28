import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'update_service.dart';
import '../../ui/theme.dart';

/// 更新弹窗的三种出口：
///  - install：应用内下载（有进度、SHA 校验、完成后直接调起安装）
///  - browser：把地址交给系统浏览器/下载工具（国内直连 GitHub 慢时的兜底）
///  - later：暂不更新
enum UpdateDialogAction { install, browser, later }

/// 更新弹窗：显示新版本号 + 更新内容 + 包大小，按钮【暂不】【浏览器下载】【立即更新】。
Future<UpdateDialogAction> showUpdateDialog(
    BuildContext context, VersionInfo info) async {
  final sizeMb = info.size > 0
      ? (info.size / (1024 * 1024)).toStringAsFixed(1)
      : '?';
  final hasBrowserFallback = info.browserUrl.trim().isNotEmpty;
  final result = await showDialog<UpdateDialogAction>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Text('发现新版本 v${info.versionName}',
          style: const TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('版本号：v${info.versionName}（versionCode ${info.versionCode}）',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Text('包大小：$sizeMb MB',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 10),
          const Text('更新内容：', style: TextStyle(color: Colors.white)),
          const SizedBox(height: 4),
          Text(info.notes.isNotEmpty ? info.notes : '（无说明）',
              style: const TextStyle(color: Colors.white70)),
          if (hasBrowserFallback) ...[
            const SizedBox(height: 12),
            const Text(
              '下载很慢或中途失败？选「浏览器下载」，交给浏览器/下载工具续传，完成后点通知即可安装。',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, UpdateDialogAction.later),
          child: const Text('暂不', style: TextStyle(color: Colors.white54)),
        ),
        if (hasBrowserFallback)
          TextButton(
            onPressed: () => Navigator.pop(context, UpdateDialogAction.browser),
            child: const Text('浏览器下载',
                style: TextStyle(color: Colors.white70)),
          ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
          onPressed: () => Navigator.pop(context, UpdateDialogAction.install),
          child: const Text('立即更新', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  return result ?? UpdateDialogAction.later;
}

/// 下载/安装失败后的兜底弹窗：直接把地址交给浏览器。
/// 返回 true 表示用户选择「用浏览器下载」。
Future<bool> showBrowserFallbackDialog(
    BuildContext context, String reason) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('应用内更新没成功', style: TextStyle(color: Colors.white)),
      content: Text(
        '$reason\n\n可以改用浏览器下载安装包（支持断点续传，也能转给下载工具）。',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('浏览器下载', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  return go ?? false;
}

/// 下载/校验失败页（1.5.8.1）：人话原因 + 诊断信息 + 一键复制，另给「浏览器下载」兜底。
/// 返回 true 表示用户选择「用浏览器下载」。
Future<bool> showDownloadFailureDialog(
  BuildContext context, {
  required String reason,
  required String diag,
  bool allowBrowser = true,
}) async {
  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('下载没成功', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(reason, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            const Text(
              '点「复制诊断信息」发给开发者，能直接看出卡在哪一步（只含下载失败的技术记录：源地址、HTTP 码、字节数，不含学习内容）：',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D17),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  diag,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11, height: 1.45),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('关闭', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: diag)).then((_) {
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                  content: Text('诊断信息已复制'),
                  duration: Duration(seconds: 2)));
            });
          },
          child: const Text('复制诊断信息',
              style: TextStyle(color: Colors.white70)),
        ),
        if (allowBrowser)
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('浏览器下载', style: TextStyle(color: Colors.white)),
          ),
      ],
    ),
  );
  return go ?? false;
}

/// 下载进度卡片：百分比 + 已下载/总 MB，支持取消。
class DownloadProgressCard extends StatelessWidget {
  final ValueNotifier<double> progress;
  final ValueNotifier<int> received;
  final int total;

  /// 阶段/速度文案（“正在连接更新服务器…” / “下载中 · 1.2 MB/s”）。
  /// 为空时保持旧版界面，不影响既有调用。
  final ValueNotifier<String>? status;
  final VoidCallback onCancel;
  const DownloadProgressCard({
    super.key,
    required this.progress,
    required this.received,
    required this.total,
    this.status,
    required this.onCancel,
  });

  String _mb(int n) => (n / (1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('正在下载更新',
          style: TextStyle(color: Colors.white)),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, v, __) => ValueListenableBuilder<int>(
          valueListenable: received,
          builder: (_, r, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: v, color: kPrimary),
              const SizedBox(height: 10),
              Text(
                '${(v * 100).round()}%  ${_mb(r)}MB / ${total > 0 ? _mb(total) : "?"}MB',
                style: const TextStyle(color: Colors.white70),
              ),
              if (status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ValueListenableBuilder<String>(
                    valueListenable: status!,
                    builder: (_, s, __) => Text(
                      s,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: const Text('取消', style: TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }
}

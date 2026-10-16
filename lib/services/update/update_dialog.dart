import 'package:flutter/material.dart';
import 'update_service.dart';
import '../../ui/theme.dart';

/// 更新弹窗：显示新版本号 + 更新内容 + 包大小，按钮【立即更新】【暂不】。
/// 返回 true 表示用户选择“立即更新”。
Future<bool> showUpdateDialog(BuildContext context, VersionInfo info) async {
  final sizeMb = info.size > 0
      ? (info.size / (1024 * 1024)).toStringAsFixed(1)
      : '?';
  final result = await showDialog<bool>(
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('暂不', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('立即更新', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 下载进度卡片：百分比 + 已下载/总 MB，支持取消。
class DownloadProgressCard extends StatelessWidget {
  final ValueNotifier<double> progress;
  final ValueNotifier<int> received;
  final int total;
  final VoidCallback onCancel;
  const DownloadProgressCard({
    required this.progress,
    required this.received,
    required this.total,
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

import 'package:flutter/material.dart';

import '../services/loaders.dart';
import '../services/tts_native.dart';
import 'sheet.dart';
import 'theme.dart';

/// 安装语音引擎的商店检索入口（国内厂商商店优先，Google TTS 备选）。
const List<({String name, String query, String note})> kTtsEngines = [
  (
    name: '讯飞语记',
    query: '讯飞语记',
    note: '国内应用商店可下载；安装后在系统语音设置里选为首选引擎',
  ),
  (
    name: 'Google 语音合成',
    query: 'Google 语音合成',
    note: '英文语音自然；Google Play 或浏览器搜索安装',
  ),
];

Future<void> openTtsSettings(BuildContext context) async {
  final ok = await TtsNative.openSettings();
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('无法打开系统语音设置，请手动进入：设置 → 系统 → 语言和输入法 → 文字转语音输出'),
      duration: Duration(seconds: 4),
    ));
  }
}

/// 商店检索底部弹层：两个可下载的语音引擎，逐项跳转。
Future<void> showTtsStoreSheet(BuildContext context) async {
  await showAppSheet<void>(
    context: context,
    backgroundColor: kCard,
    builder: (sheetCtx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('安装语音引擎（二选一）',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('安装后回到 ChunkSpoke，点「重新检测」即可。',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 10),
            for (final e in kTtsEngines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.download_rounded, color: kPrimary),
                title: Text(e.name,
                    style: const TextStyle(color: kText, fontSize: 15)),
                subtitle: Text(e.note,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
                trailing: const Icon(Icons.open_in_new,
                    size: 16, color: Colors.white38),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  final ok = await TtsNative.openStore(e.query);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('未找到应用商店，请在浏览器搜索「${e.name}」'),
                      duration: const Duration(seconds: 3),
                    ));
                  }
                },
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    ),
  );
}

/// 朗读失败的可操作对话框（替代旧 SnackBar 裸提示）：
/// 取消 / 去下载 / 去设置，按检测状态给出不同原因。
Future<void> showTtsFixDialog(BuildContext context, TtsService tts) async {
  final status = tts.status;
  final String title;
  final String reason;
  switch (status) {
    case TtsStatus.noEngine:
      title = '未检测到语音引擎';
      reason = '当前设备没有可用的语音合成引擎，朗读按钮不会有声音。'
          '安装一个语音引擎即可恢复，学习进度和录音判定不受影响。';
    case TtsStatus.noEnglish:
      title = '语音引擎缺少英文语音';
      reason = '已找到语音引擎，但没有可用的英文语音数据。'
          '请在系统语音设置中安装英文语音包，或安装其他语音引擎后重试。';
    case TtsStatus.error:
      title = '语音检测未完成';
      reason = '系统语音服务暂时没有响应。请稍后重试，或打开系统语音设置检查首选引擎。';
    case TtsStatus.unknown:
    case TtsStatus.ready:
      title = '语音暂时没能播放';
      reason = '系统语音引擎没有响应。可打开系统语音设置检查首选引擎，'
          '或安装/切换其他语音引擎后重试。';
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: kCard,
      icon: const Icon(Icons.volume_off_rounded, color: kPrimary, size: 30),
      title: Text(title,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 18)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(reason,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 14, height: 1.45)),
          const SizedBox(height: 10),
          Text('诊断码：${tts.diagnostic}',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          child: const Text('取消', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            showTtsStoreSheet(context);
          },
          child: const Text('去下载', style: TextStyle(color: kPrimary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
          onPressed: () {
            Navigator.of(dialogCtx).pop();
            openTtsSettings(context);
          },
          child: const Text('去设置', style: TextStyle(color: Colors.black87)),
        ),
      ],
    ),
  );
}

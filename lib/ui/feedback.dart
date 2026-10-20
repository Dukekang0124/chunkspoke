import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/loaders.dart';
import 'theme.dart';

/// 最小反馈：对=轻快系统音（受设置页「音效」开关控制，B7）；错=中等振动（跟随系统）。
void chimeCorrect([BuildContext? context]) {
  if (context != null) {
    final p = Provider.of<ProgressService>(context, listen: false);
    if (!p.soundOn) return;
  }
  SystemSound.play(SystemSoundType.click);
}

void buzzWrong() => HapticFeedback.mediumImpact();

/// 反馈邮箱（A7：会话收尾页 + 设置页双入口）。
const String kFeedbackEmail = 'chunkspoke.feedback@gmail.com';

/// 调起系统邮件客户端（mailto）。
Future<void> openFeedbackEmail() async {
  final uri = Uri(
    scheme: 'mailto',
    path: kFeedbackEmail,
    query: 'subject=ChunkSpoke 反馈',
  );
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// 复制反馈邮箱到剪贴板。
Future<void> copyFeedbackEmail() async {
  await Clipboard.setData(const ClipboardData(text: kFeedbackEmail));
}

/// 播放 TTS，失败时弹 SnackBar 提示：把「点喇叭无声」从静默失败变为可见反馈。
/// 附带 lastError（含失败码 / 当前默认 TTS 引擎包名），便于真机定位引擎问题。
Future<void> speakOrHint(
    BuildContext context, TtsService tts, String text) async {
  final ok = await tts.speak(text);
  if (!ok && context.mounted) {
    final why = tts.lastError;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(why == null || why.isEmpty
          ? '无法播放语音，请检查系统 TTS 设置'
          : '无法播放语音（$why），请检查系统 TTS 设置'),
      duration: const Duration(seconds: 2),
    ));
  }
}

/// 反馈入口（A7）：底部弹层提供「发邮件 / 复制邮箱」双方式。
void showFeedbackSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCard,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('反馈与建议',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('发邮件或复制邮箱，我们都会认真看',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      openFeedbackEmail();
                    },
                    icon: const Icon(Icons.mail_outline, color: Colors.black87),
                    label: const Text('发邮件',
                        style: TextStyle(color: Colors.black87)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await copyFeedbackEmail();
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                            content: Text('邮箱已复制'),
                            duration: Duration(seconds: 1)));
                      }
                    },
                    icon: const Icon(Icons.copy, color: kPrimary),
                    label: const Text('复制邮箱',
                        style: TextStyle(color: kPrimary)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

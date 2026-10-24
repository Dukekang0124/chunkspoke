import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../services/loaders.dart';
import '../services/notification_service.dart';
import '../services/recording.dart';
import 'motion.dart';
import 'sheet.dart';
import 'theme.dart';

/// M1（#64 权限请求前说明）：系统权限框之前，先用自己的说明卡讲清好处。
///
/// 口径（`ui-motion` v0.21 · 64）：说明卡从底部弹起约 400ms 轻微回弹（走 [showAppSheet]）、
/// 预览延迟约 0.5s 滑入、卡片收起约 300ms ease-in、**之后约 150ms 才请求系统权限**；
/// 每个权限只弹一次（落库记忆）；已永久拒绝不再弹（直接走系统状态，由上层引导设置页）。
enum PermissionKind { microphone, notifications }

/// 返回 true = 可以继续去弹系统权限框；false = 用户选了「以后再说」，本次不索取。
Future<bool> permissionPrepromptConsent(
  BuildContext context, {
  required PermissionKind kind,
}) async {
  final progress = Provider.of<ProgressService>(context, listen: false);
  final seen = kind == PermissionKind.microphone
      ? progress.prepromptSeenMic
      : progress.prepromptSeenNotify;
  if (seen) return true; // 已经说明过一次，不再拦路
  // 记住「说明过」这件事本身，避免每次开口都弹。
  if (kind == PermissionKind.microphone) {
    await progress.setPrepromptSeenMic();
  } else {
    await progress.setPrepromptSeenNotify();
  }
  if (!context.mounted) return true;
  // 可能在 initState 里被调用：等这一帧画完再弹卡，避免建树途中改路由。
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return true;
  final agreed = await showAppSheet<bool>(
    context: context,
    builder: (_) => _PrepromptSheet(kind: kind),
  );
  if (agreed != true) return false;
  if (!context.mounted) return true;
  // 卡片收起后再等一下，系统框不要和关闭动画叠在一起。
  await Future.delayed(Motion.of(context).dur(150));
  return true;
}

/// 麦克风：需要新授权时先说明，再走既有 [RecordingService.ensurePermission]。
Future<MicPerm> ensureMicWithPreprompt(
  BuildContext context,
  RecordingService rec,
) async {
  if (await _needsPreprompt(PermissionKind.microphone)) {
    if (!context.mounted) return MicPerm.denied;
    if (!await permissionPrepromptConsent(context,
        kind: PermissionKind.microphone)) {
      return MicPerm.denied;
    }
  }
  return rec.ensurePermission();
}

/// 通知：需要新授权时先说明，再请求；返回是否已授权。
Future<bool> ensureNotificationsWithPreprompt(BuildContext context) async {
  if (await _needsPreprompt(PermissionKind.notifications)) {
    if (!context.mounted) return false;
    if (!await permissionPrepromptConsent(context,
        kind: PermissionKind.notifications)) {
      return false;
    }
  }
  return NotificationService.instance.requestPermission();
}

/// 已授予或已永久拒绝 → 不该再弹说明卡（库内禁用场景）。
/// 探测失败（测试环境无平台通道）按「需要说明」处理，由后续真实请求兜底。
Future<bool> _needsPreprompt(PermissionKind kind) async {
  try {
    final st = kind == PermissionKind.microphone
        ? await Permission.microphone.status
        : await Permission.notification.status;
    return !st.isGranted && !st.isPermanentlyDenied && !st.isRestricted;
  } catch (_) {
    return true;
  }
}

class _PrepromptSheet extends StatefulWidget {
  final PermissionKind kind;
  const _PrepromptSheet({required this.kind});

  @override
  State<_PrepromptSheet> createState() => _PrepromptSheetState();
}

class _PrepromptSheetState extends State<_PrepromptSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wiggle;
  bool _previewIn = false;

  @override
  void initState() {
    super.initState();
    // 图标只轻动一下（库内「无限循环的装饰动画」是 anti-cheap 明令禁止项）。
    _wiggle = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..forward();
    // 预览延迟约 0.5s 滑入。
    Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _previewIn = true);
    });
  }

  @override
  void dispose() {
    _wiggle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mic = widget.kind == PermissionKind.microphone;
    final policy = Motion.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedBuilder(
                  animation: _wiggle,
                  builder: (_, child) => Transform.rotate(
                    // 摆一下再回正：阻尼摆动，起止角度都是 0。
                    angle: policy.animates
                        ? 0.15 *
                            math.sin(_wiggle.value * math.pi * 3) *
                            (1 - _wiggle.value)
                        : 0.0,
                    child: child,
                  ),
                  child: Icon(mic ? Icons.mic : Icons.notifications_outlined,
                      size: 26, color: kPrimary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    mic ? '开口练习要用麦克风' : '复习到期时提醒你',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              mic
                  ? '只在你点录音的那几秒采集声音，识别在本机完成，'
                      '录音不上传、不保存到服务器，学习进度只存本机。'
                  : '只在有词块到期那天发一条提醒，点它会回到待复习的词块。'
                      '不开也不影响任何练习，随时可在设置里关。',
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 14),
            // 权限用途的小预览（通知：一条通知滑进来；麦克风：一条电平）。
            AnimatedSlide(
              offset: _previewIn ? Offset.zero : const Offset(0, .6),
              duration: policy.dur(300),
              curve: Curves.easeOut,
              child: AnimatedOpacity(
                opacity: _previewIn ? 1 : 0,
                duration: policy.dur(300),
                curve: Curves.easeOut,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: kBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    children: [
                      Icon(mic ? Icons.graphic_eq : Icons.schedule,
                          size: 16, color: Colors.white38),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          mic ? '「我说的是…」→ 本机识别打分' : '今天有 3 个词块到期 · 点我去复习',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('以后再说',
                        style: TextStyle(color: Colors.white54)),
                  ),
                ),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: kPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('好的',
                        style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

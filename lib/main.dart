import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/content_pack.dart';
import 'models/listening_article.dart';
import 'services/crash_log.dart';
import 'services/hd_voice.dart';
import 'services/loaders.dart';
import 'services/notification_service.dart';
import 'services/review_notify.dart';
import 'ui/theme.dart';
import 'ui/error_page.dart';
import 'ui/motion.dart';
import 'screens/ftue.dart';
import 'screens/model_gate.dart';
import 'screens/nav.dart';
import 'screens/onboarding_screen.dart';
import 'screens/tts_gate.dart';

void main() {
  // 全局错误拦截（P0 加固）：任何页面/异步异常都不允许灰屏或闪退退桌面。
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      CrashLog.write('FlutterError: ${details.exception}', details.stack);
    };
    WidgetsBinding.instance.platformDispatcher.onError = (e, st) {
      CrashLog.write('PlatformError: $e', st);
      return true;
    };
    // 组件构建异常 → 应用内错误页（替代默认灰屏 ErrorWidget）。
    ErrorWidget.builder = (details) =>
        ErrorBody(detail: details.exception);
    await bootstrap();
  }, (e, st) {
    CrashLog.write('Uncaught: $e', st);
  });
}

Future<void> bootstrap() async {
  try {
    final progress = ProgressService();
    await progress.init();
    final content = await loadContentPack();
    progress.setChunkTiers(content);
    final listening = await loadListeningPack();
    if (kDebugMode) {
      final packErrors = validateContentPackReferences(content);
      if (packErrors.isNotEmpty) {
        throw StateError('内容包引用校验失败：${packErrors.take(5).join('；')}');
      }
      final errors = validateListeningPack(listening, content);
      if (errors.isNotEmpty) {
        throw StateError('收听文章内容校验失败：${errors.take(5).join('；')}');
      }
    }
    final hdVoice = HdVoiceService(
      isEnabled: () => progress.hdVoiceEnabled,
      setEnabled: progress.setHdVoiceEnabled,
      readVoiceId: () => progress.hdVoiceId,
      persistVoiceId: progress.setHdVoiceId,
      // 高清包下载完成率单独成口径（与 Vosk 模型分开），抛错不影响下载。
      onEvent: (e, p) {
        progress.logEvent(e, p);
      },
    );
    await hdVoice.init();
    final tts = TtsService(
      preferredVoice: () => progress.ttsVoiceKey,
      hdVoice: hdVoice,
    );
    await tts.init();
    // 音色分布（指令 H）：每次启动记一条当前实际生效的发声配置快照。
    try {
      final v = tts.selectedVoice;
      progress.logEvent('voice_state', {
        'hd': tts.hdActive,
        'auto': tts.preferredVoiceKey == null,
        'locale': v?.locale ?? '',
        'accent': v?.accentLabel ?? '',
        'quality': v?.quality ?? '',
        'net': v?.networkRequired ?? false,
        'status': tts.status.name,
      });
    } catch (_) {}
    // 留存通知：初始化 + 已开启时复挂每日提醒（进程重启/系统清闹钟后自愈）。
    // 全程非致命：通知失败绝不阻塞启动。
    try {
      await NotificationService.instance.init();
      if (progress.notifEnabled) {
        await NotificationService.instance
            .scheduleDaily(progress.notifHour, progress.notifMinute);
      }
      // 到期复习提醒：启动时按资产引擎的最早到期重排（关闭则取消）。
      await syncReviewReminder(progress);
    } catch (_) {}
    // 回访漏斗埋点（P0-七）：连续打卡 2 天 / 7 天各记一次。
    try {
      if (progress.streak >= 2) await progress.logOnce('day2_return');
      if (progress.streak >= 7) await progress.logOnce('day7_return');
    } catch (_) {}
    runApp(
      MultiProvider(
        providers: [
          Provider<ProgressService>.value(value: progress),
          Provider<ContentPack>.value(value: content),
          Provider<ListeningPack>.value(value: listening),
          Provider<TtsService>.value(value: tts),
          ChangeNotifierProvider<HdVoiceService>.value(value: hdVoice),
          ChangeNotifierProvider<MotionService>(
              create: (_) => MotionService()),
        ],
        child: const ChunkSpokeApp(),
      ),
    );
  } catch (e, st) {
    // 启动链路兜底：初始化失败也渲染应用内错误页（带重试），绝不静默退出。
    CrashLog.write('Bootstrap: $e', st);
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: darkTheme,
      home: Scaffold(body: ErrorBody(detail: e, onRetry: main)),
    ));
  }
}

class ChunkSpokeApp extends StatelessWidget {
  const ChunkSpokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final progress = Provider.of<ProgressService>(context, listen: false);
    return MaterialApp(
      title: 'ChunkSpoke',
      debugShowCheckedModeBanner: false,
      theme: darkTheme,
      // 防御：根节点铺满应用底色，任何时刻（含栈空/过渡）都不会露系统黑底。
      builder: (context, child) =>
          ColoredBox(color: kBg, child: child ?? const SizedBox.shrink()),
      home: ModelGate(
        child: !progress.onboardingDone
            ? const OnboardingScreen()
            : TtsGate(
                child: progress.seenFtue
                    ? const AppNav()
                    : const FtueScreen(),
              ),
      ),
    );
  }
}

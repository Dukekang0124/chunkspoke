import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/content_pack.dart';
import 'models/listening_article.dart';
import 'services/crash_log.dart';
import 'services/hd_voice.dart';
import 'services/legacy_gate.dart';
import 'services/license_gate.dart';
import 'services/license_state.dart';
import 'services/loaders.dart';
import 'services/notification_service.dart';
import 'services/progress_guard.dart';
import 'services/review_notify.dart';
import 'services/theme_provider.dart';
import 'services/zipformer_asr.dart';
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
    // 1.5.10（#209）· D1：老用户身份判据必须在**任何开库动作之前**跑完。
    // 判据 = 首启时 chunkspoke.db 文件在不在；结论写进库外的 legacy.flag，
    // 写过永不重写。顺序反了（先 openDatabase 再判）会全员判成老用户 → 墙失效。
    LegacyGate? legacyGate;
    try {
      legacyGate = await openLegacyGate();
      await legacyGate.bootstrap();
    } catch (e, st) {
      CrashLog.write('LegacyGate.bootstrap: $e', st);
    }
    final progress = ProgressService();
    await progress.init();
    // 外观主题：初始值在首帧前同步生效，避免启动闪一下默认深色。
    final themeProvider = ThemeProvider(
      initialId: progress.appThemeId,
      initialMode: progress.appThemeMode,
      persistId: progress.setAppThemeId,
      persistMode: progress.setAppThemeMode,
    );
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
      // 语速档位现读现用（§30.5 单源）：设置页改档后下一句即生效。
      readProfile: () => VoiceProfile(speed: progress.ttsSpeed),
      hdVoice: hdVoice,
      // 高清回落等发音事件单独成口径（与下载事件分开），抛错不影响发声。
      onEvent: (e, p) {
        progress.logEvent(e, p);
      },
    );
    await tts.init();
    // 音色分布（指令 H）：每次启动记一条当前实际生效的发声配置快照。
    try {
      final v = tts.selectedVoice;
      progress.logEvent('voice_state', {
        'hd': tts.hdActive,
        'speed': tts.profile.speed.name,
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
    // 1.6.0（LIC-1）：授权状态在 legacy 判据之后装配（老用户终身全量）。
    // 读盘失败不阻塞启动 → 退化为「无授权」，A–F 照常免费。
    var legacyEligible = false;
    try {
      legacyEligible =
          legacyGate != null && LegacyGate.isLegacy(await legacyGate.readRaw());
    } catch (e, st) {
      CrashLog.write('LegacyGate.readRaw: $e', st);
    }
    final license = LicenseState(
      db: progress.database,
      legacyEligible: legacyEligible,
    );
    try {
      await license.load();
    } catch (e, st) {
      CrashLog.write('LicenseState.load: $e', st);
    }
    // 白名单刷新不阻塞首屏；失败保持本地态（断网 ≠ 未登记）。
    unawaited(LicenseGate().refresh(license).catchError((Object e, StackTrace st) {
      CrashLog.write('LicenseGate.refresh: $e', st);
    }));
    // ASR-191：增强识别预热不阻塞首屏；未开启/未下载时什么都不做，默认仍是 Vosk。
    unawaited(EnhancedAsrService.instance.warmUp().catchError(
        (Object e, StackTrace st) => CrashLog.write('EnhancedAsr.warmUp: $e', st)));
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
          ChangeNotifierProvider<LicenseState>.value(value: license),
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ],
        child: const ChunkSpokeApp(),
      ),
    );
    // ASR-211 修复 3（时机①）：冷启动全模块归位。首帧不被它拖慢，失败只留痕；
    // 存量用户带着旧断点进来时，红名单在进入任何练习页之前就已经被台账改写。
    ProgressGuard.scheduleColdStart(progress, content);
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
    final theme = Provider.of<ThemeProvider>(context);
    return MaterialApp(
      title: 'ChunkSpoke',
      debugShowCheckedModeBanner: false,
      theme: theme.lightThemeData,
      darkTheme: theme.darkThemeData,
      themeMode: theme.themeMode,
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

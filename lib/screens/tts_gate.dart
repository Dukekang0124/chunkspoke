import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/loaders.dart';
import '../ui/theme.dart';
import 'tts_guide.dart';

/// TTS 启动预检门（三.3 同类拦截）：
/// 引擎缺失 / 无英文语音时先展示修复引导，用户可一键跳系统设置或下载引擎；
/// 也可「先继续使用」——只在首次命中时拦截，不反复打扰。
/// 检测本身在 bootstrap 已跑过一次，这里只消费状态；回前台时复检。
class TtsGate extends StatefulWidget {
  final Widget child;
  const TtsGate({super.key, required this.child});

  @override
  State<TtsGate> createState() => _TtsGateState();
}

class _TtsGateState extends State<TtsGate> with WidgetsBindingObserver {
  bool _checking = false;
  bool _loggedShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensure());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    final tts = Provider.of<TtsService>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    if (!progress.ttsGuideDone && !tts.available) _recheck();
  }

  Future<void> _ensure() async {
    if (!mounted) return;
    final tts = Provider.of<TtsService>(context, listen: false);
    if (tts.status == TtsStatus.unknown) {
      setState(() => _checking = true);
      await tts.init();
      if (mounted) setState(() => _checking = false);
    }
    _logShownIfNeeded();
  }

  Future<TtsStatus> _recheck() async {
    final tts = Provider.of<TtsService>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    final s = await tts.recheck();
    if (s == TtsStatus.ready) {
      await progress.logEvent('tts_guide_fixed', {'engine': tts.activeEngine});
    } else {
      _logShownIfNeeded();
    }
    if (mounted) setState(() {});
    return s;
  }

  void _logShownIfNeeded() {
    if (_loggedShown) return;
    final tts = Provider.of<TtsService>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    if (tts.available || progress.ttsGuideDone) return;
    _loggedShown = true;
    progress.logEvent('tts_guide_shown', {
      'status': tts.status.name,
      'engine': tts.activeEngine,
    });
  }

  @override
  Widget build(BuildContext context) {
    final tts = Provider.of<TtsService>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);

    if (tts.status == TtsStatus.unknown || _checking) {
      return Scaffold(
        backgroundColor: kBg,
        body: const SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(height: 14),
                Text('正在检测语音朗读…',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    }
    if (tts.available || progress.ttsGuideDone) return widget.child;

    return TtsGuideScreen(
      status: tts.status,
      diagnostic: tts.diagnostic,
      engine: tts.activeEngine,
      onRecheck: _recheck,
      onContinue: () async {
        await progress.setTtsGuideDone(true);
        await progress.logEvent('tts_guide_skip', {'status': tts.status.name});
        if (mounted) setState(() {});
      },
    );
  }
}

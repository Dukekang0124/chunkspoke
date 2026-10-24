import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/vosk_engine.dart';
import '../ui/theme.dart';
import '../ui/motion.dart';
import '../ui/permission_preprompt.dart';
import '../ui/widgets.dart';
import 'level.dart';
import 'nav.dart';
import 'tts_gate.dart';

class FtueScreen extends StatefulWidget {
  const FtueScreen({super.key});
  @override
  State<FtueScreen> createState() => _FtueScreenState();
}

class _FtueScreenState extends State<FtueScreen> {
  bool s1 = false, s2 = false, s3 = false, showStart = false;
  bool _micOk = false;
  EngineState _engine = EngineState.unknown;

  @override
  void initState() {
    super.initState();
    final tts = Provider.of<TtsService>(context, listen: false);
    Future.delayed(const Duration(milliseconds: 300),
        () { if (mounted) setState(() => s1 = true); });
    Future.delayed(const Duration(milliseconds: 700),
        () { if (mounted) setState(() => s2 = true); });
    Future.delayed(const Duration(milliseconds: 1100),
        () { if (mounted) setState(() => s3 = true); });
    Future.delayed(const Duration(milliseconds: 1500),
        () { if (mounted) tts.speak("I'd like a cup of coffee."); });
    Future.delayed(const Duration(milliseconds: 2200),
        () { if (mounted) setState(() => showStart = true); });
    // P0-2.2 前置：首次开口的两道前置关（麦克风权限 + 41MB 语音引擎）提前到引导页完成，
    // 练习环节不再被这两步打断（报告实测的「连闯三关」最大流失点）。
    // 权限是系统级、全局生效；引擎是单例、预热后练习直接可用，且不在 initState 阻塞「开始学习」。
    _prep();
  }

  Future<void> _prep() async {
    try {
      final perm = await ensureMicWithPreprompt(context, RecordingService());
      if (mounted) setState(() => _micOk = perm == MicPerm.granted);
    } catch (_) {}
    if (mounted) setState(() => _engine = EngineState.loading);
    SpeechEngine.instance.init().then((ok) {
      if (mounted) {
        setState(() => _engine = ok ? EngineState.ready : EngineState.failed);
      }
    });
  }

  Future<void> _start() async {
    final content = Provider.of<ContentPack>(context, listen: false);
    final level = content.levels.firstWhere((l) => l.id == 'A',
        orElse: () => content.levels.first);
    await Provider.of<ProgressService>(context, listen: false).setSeenFtue(true);
    if (!mounted) return;
    final nav = Navigator.of(context);
    // P0 修复：先把「场景列表(AppNav)」作为栈底落地，再在其上进入练习页。
    // 修复前用 pushReplacement 会替换掉唯一的地图路由，练习页 ✕ pop() 后栈空 → 整屏黑。
    nav.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const TtsGate(child: AppNav())),
      (r) => false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nav.push(MaterialPageRoute(builder: (_) => LevelScreen(level: level)));
    });
  }

  Widget _fly(bool visible, String text, String type) => AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: Motion.of(context).dur(350),
        curve: Curves.easeOut,
        child: ChunkTile(text, type),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('ChunkSpoke',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              const Text('用词块思考，用英语开口。',
                  style: TextStyle(fontSize: 16, color: Colors.white70)),
              const SizedBox(height: 48),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _fly(s1, "I'd like", 'function'),
                  _fly(s2, 'a cup of', 'content'),
                  _fly(s3, 'coffee', 'content'),
                ],
              ),
              const SizedBox(height: 12),
              AnimatedOpacity(
                opacity: s3 ? 1 : 0,
                duration: Motion.of(context).dur(300),
                curve: Curves.easeOut,
                child: const Text("I'd like a cup of coffee.",
                    style: TextStyle(fontSize: 18, color: Colors.white)),
              ),
              const Spacer(),
              if (showStart) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_micOk ? Icons.check_circle : Icons.mic,
                        size: 15,
                        color: _micOk ? kUnlocked : Colors.white54),
                    const SizedBox(width: 4),
                    Text(_micOk ? '麦克风已授权' : '麦克风待授权',
                        style: const TextStyle(fontSize: 12, color: Colors.white54)),
                    const SizedBox(width: 16),
                    Icon(
                        _engine == EngineState.ready
                            ? Icons.check_circle
                            : _engine == EngineState.failed
                                ? Icons.warning
                                : Icons.hourglass_bottom,
                        size: 15,
                        color: _engine == EngineState.ready
                            ? kUnlocked
                            : _engine == EngineState.failed
                                ? Colors.orange
                                : Colors.white54),
                    const SizedBox(width: 4),
                    Text(_engine == EngineState.ready
                        ? '语音引擎就绪'
                        : _engine == EngineState.failed
                            ? '引擎不可用(可降级)'
                            : '引擎准备中…',
                        style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _start,
                    child: const Text('开始学习',
                        style: TextStyle(fontSize: 18, color: Colors.white)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

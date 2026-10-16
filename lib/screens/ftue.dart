import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'level.dart';
import 'nav.dart';

class FtueScreen extends StatefulWidget {
  const FtueScreen({super.key});
  @override
  State<FtueScreen> createState() => _FtueScreenState();
}

class _FtueScreenState extends State<FtueScreen> {
  bool s1 = false, s2 = false, s3 = false, showStart = false;

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
  }

  void _start() {
    final content = Provider.of<ContentPack>(context, listen: false);
    final level = content.levels.firstWhere((l) => l.id == 'A',
        orElse: () => content.levels.first);
    Provider.of<ProgressService>(context, listen: false).setSeenFtue(true);
    final nav = Navigator.of(context);
    // P0 修复：先把「场景列表(AppNav)」作为栈底落地，再在其上进入练习页。
    // 修复前用 pushReplacement 会替换掉唯一的地图路由，练习页 ✕ pop() 后栈空 → 整屏黑。
    nav.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppNav()),
      (r) => false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nav.push(MaterialPageRoute(builder: (_) => LevelScreen(level: level)));
    });
  }

  Widget _fly(bool visible, String text, String type) => AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 350),
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
                duration: const Duration(milliseconds: 300),
                child: const Text("I'd like a cup of coffee.",
                    style: TextStyle(fontSize: 18, color: Colors.white)),
              ),
              const Spacer(),
              if (showStart)
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
          ),
        ),
      ),
    );
  }
}

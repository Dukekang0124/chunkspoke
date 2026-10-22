import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'ftue.dart';
import 'nav.dart';
import 'tts_gate.dart';

/// 新手引导（P0-二）：首次启动 3 屏滑动引导，可跳过。
/// 完成 / 跳过 → 记录 onboardingDone，返回主流程。
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pc = PageController();
  int _page = 0;
  static const int _last = 2;

  Future<void> _goNext(bool finished) async {
    final p = Provider.of<ProgressService>(context, listen: false);
    // 在置位前读取：已做过技术前置(FTUE)的回流用户直接进主流程，
    // 否则引导后进入 FTUE（麦克风授权 + 引擎预热），再到 AppNav。
    final alreadyFtue = p.seenFtue;
    await p.setOnboardingDone();
    await p.logEvent(finished ? 'onboarding_complete' : 'onboarding_skip');
    if (!mounted) return;
    // 首用即做 TTS 预检：缺失引擎/英文语音时先在引导页说明，不等到朗读时裸报错。
    final target = TtsGate(
      child: alreadyFtue ? const AppNav() : const FtueScreen(),
    );
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => target));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: () => _goNext(false),
                child: const Text('跳过',
                    style: TextStyle(color: Colors.white54, fontSize: 15)),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _Page(
                    emoji: '🧩',
                    title: '还在一个单词一个单词地背？',
                    subtitle: '背了 1000 个单词，开口还是不会说？',
                    visual: _ScatterVisual(),
                  ),
                  _Page(
                    emoji: '🔗',
                    title: 'ChunkSpoke 教你「词块」学习法',
                    subtitle: '像母语者一样，一次掌握一整串表达，直接开口说句子',
                    visual: _SentenceVisual(),
                  ),
                  _Page(
                    emoji: '🚀',
                    title: '每天 5 分钟，从跟读到造句',
                    subtitle: '学完词块 → 自由组合 → 真正开口',
                    visual: _RocketVisual(),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                  _last + 1,
                  (i) => Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: _page == i ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _page == i ? kPrimary : Colors.white24,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      )),
            ),
            const SizedBox(height: 18),
            if (_page < _last)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimary,
                      foregroundColor: Colors.black87,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _pc.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut),
                    child: const Text('下一步',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimary,
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => _goNext(true),
                        child: const Text('开始学习',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('已为 30+ 学习者提供服务',
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final Widget visual;
  const _Page(
      {required this.emoji,
      required this.title,
      required this.subtitle,
      required this.visual});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            visual,
            const SizedBox(height: 28),
            Text(emoji, style: const TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15)),
          ],
        ),
      );
}

/// 屏1：散落的单词碎片。
class _ScatterVisual extends StatelessWidget {
  const _ScatterVisual();
  @override
  Widget build(BuildContext context) {
    const chips = ['apple', 'run', 'book', 'happy', 'go', 'cat'];
    return SizedBox(
      height: 120,
      child: Stack(
        children: [
          for (var i = 0; i < chips.length; i++)
            Positioned(
              left: (i * 47.0) % 240,
              top: (i * 31.0) % 80,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text(chips[i],
                    style: const TextStyle(color: Colors.white54, fontSize: 14)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 屏2：词块拼成句子。
class _SentenceVisual extends StatelessWidget {
  const _SentenceVisual();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kPrimary.withOpacity(0.5)),
        ),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final w in ['I', 'would', 'like', 'to', 'book', 'a', 'table'])
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: kPrimary.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kPrimary.withOpacity(0.6)),
                ),
                child: Text(w,
                    style: const TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      );
}

/// 屏3：起飞。
class _RocketVisual extends StatelessWidget {
  const _RocketVisual();
  @override
  Widget build(BuildContext context) => Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
              colors: [kPrimary, kUnlocked],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: const Center(
            child: Text('🚀', style: TextStyle(fontSize: 48))),
      );
}

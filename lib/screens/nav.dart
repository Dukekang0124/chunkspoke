import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../services/changelog.dart';
import '../services/loaders.dart';
import '../ui/badge_count.dart';
import '../ui/pressable.dart';
import '../ui/theme.dart';
import 'map.dart';
import 'me.dart';
import 'library.dart';
import 'listening_home_screen.dart';
import 'settings.dart';
import '../services/update/update_flow.dart';

/// M5 导航：[练习][磨耳朵][词块库][进度] + 齿轮（设置）。
class AppNav extends StatefulWidget {
  const AppNav({super.key});
  @override
  State<AppNav> createState() => _AppNavState();
}

class _AppNavState extends State<AppNav> with WidgetsBindingObserver {
  int _index = 0;

  /// M1（#58）：切 tab / 回前台时刷新到期数角标（角标只在入口层，不进学习流）。
  int _dueTick = 0;

  @override
  void initState() {
    super.initState();
    // 进入首屏后静默检查更新（每次冷启动最多一次，网络失败静默跳过）。
    runUpdateCheck(context);
    _maybeShowChangelog();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() => _dueTick++);
    }
  }

  /// A6：首启一次性「本次更新」清单，标题/内容由当前版本号动态生成，看过记忆不再弹。
  Future<void> _maybeShowChangelog() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    if (p.seenChangelog140) return;
    final info = await PackageInfo.fromPlatform();
    final c = buildChangelog(info.version);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await p.setSeenChangelog140();
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kCard,
          title: Text(c.title, style: const TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in c.items) ...[
                Text(item, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('开始使用', style: TextStyle(color: kPrimary)),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      const MapScreen(),
      ListeningHomeScreen(onGoLibrary: () => setState(() => _index = 2)),
      LibraryScreen(onGoPractice: () => setState(() => _index = 0)),
      const MeScreen(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('ChunkSpoke'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: tabs[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() {
          _index = i;
          _dueTick++;
        }),
        type: BottomNavigationBarType.fixed,
        backgroundColor: kCard,
        selectedItemColor: kPrimary,
        unselectedItemColor: Colors.white54,
        items: [
          BottomNavigationBarItem(
            icon: _tabPress(const Icon(Icons.school)),
            label: '练习',
          ),
          BottomNavigationBarItem(
            icon: _tabPress(_DueBadge(tick: _dueTick)),
            label: '磨耳朵',
          ),
          BottomNavigationBarItem(
            icon: _tabPress(const Icon(Icons.library_books)),
            label: '词块库',
          ),
          BottomNavigationBarItem(
            icon: _tabPress(const Icon(Icons.show_chart)),
            label: '进度',
          ),
        ],
      ),
    );
  }

  /// M-2 按下态：底部导航图标缩小反馈（点击仍归 BottomBar 自己处理）。
  static Widget _tabPress(Widget icon) =>
      PressableScale(scale: 0.92, child: icon);
}

/// M1（#58）：磨耳朵入口的到期块角标。只读 `dueChunkKeys`，不改任何到期时间。
class _DueBadge extends StatefulWidget {
  final int tick;
  const _DueBadge({required this.tick});

  @override
  State<_DueBadge> createState() => _DueBadgeState();
}

class _DueBadgeState extends State<_DueBadge> {
  int _due = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _DueBadge old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick) _load();
  }

  Future<void> _load() async {
    final store =
        Provider.of<ProgressService>(context, listen: false).chunkStore;
    final keys =
        await store.dueChunkKeys(DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    setState(() => _due = keys.length);
  }

  @override
  Widget build(BuildContext context) {
    return BadgeCount(
      count: _due,
      child: const Icon(Icons.headphones),
    );
  }
}

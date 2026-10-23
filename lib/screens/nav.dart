import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../services/changelog.dart';
import '../services/loaders.dart';
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

class _AppNavState extends State<AppNav> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // 进入首屏后静默检查更新（每次冷启动最多一次，网络失败静默跳过）。
    runUpdateCheck(context);
    _maybeShowChangelog();
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
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        backgroundColor: kCard,
        selectedItemColor: kPrimary,
        unselectedItemColor: Colors.white54,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.school), label: '练习'),
          BottomNavigationBarItem(
              icon: Icon(Icons.headphones), label: '磨耳朵'),
          BottomNavigationBarItem(
              icon: Icon(Icons.library_books), label: '词块库'),
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: '进度'),
        ],
      ),
    );
  }
}

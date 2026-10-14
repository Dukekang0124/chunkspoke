import 'package:flutter/material.dart';
import '../ui/theme.dart';
import 'map.dart';
import 'me.dart';
import 'settings.dart';

/// M5 两栏导航：[练习][进度] + 齿轮（设置）。
class AppNav extends StatefulWidget {
  const AppNav({super.key});
  @override
  State<AppNav> createState() => _AppNavState();
}

class _AppNavState extends State<AppNav> {
  int _index = 0;
  final List<Widget> _tabs = const [MapScreen(), MeScreen()];

  @override
  Widget build(BuildContext context) {
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
      body: _tabs[_index],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        backgroundColor: kCard,
        selectedItemColor: kPrimary,
        unselectedItemColor: Colors.white54,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.school), label: '练习'),
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: '进度'),
        ],
      ),
    );
  }
}

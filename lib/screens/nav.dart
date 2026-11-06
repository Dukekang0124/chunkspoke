import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../services/asr_budget.dart';
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

  /// ASR-217 P1-1 后半：全新安装的「3 行上手卡」。
  ///
  /// 升级方案 §1.8.4 P1-1 写的是「新装走 3 行上手卡」，1.8.4 只做到了「不弹更新日志」，
  /// 新人进来其实没人告诉他下一步做什么。三行只讲这台机器上真实存在的东西，
  /// 不写没实装的能力（P2-6 那条教训）。
  Future<void> _showQuickStartCard(ProgressService p) async {
    await p.setQuickStartSeen();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCard,
        title: Text('三步上手', style: TextStyle(color: kText)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1. 首页点任意场景，六步过一遍一个词块，一次约 3 分钟。',
                  style: TextStyle(color: kTextSecondary)),
              const SizedBox(height: 8),
              Text('2. 开口没听清可以直接打字，照样算过——机器的问题不该算你的。',
                  style: TextStyle(color: kTextSecondary)),
              const SizedBox(height: 8),
              Text('3. 复习排期由系统记着，到期出现在首页；内容全在本机，不联网上传。',
                  style: TextStyle(color: kTextSecondary)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('知道了', style: TextStyle(color: kPrimary)),
          ),
        ],
      ),
    );
  }

  /// A6：一次性「本次更新」清单，标题/内容由当前版本号动态生成，看过记忆不再弹。
  ///
  /// ASR-213 P1-1：全新安装 **不弹**——新用户第一次点「开始学习」就被一屏老用户
  /// 才看得懂的修复日志挡住，是实测抓到的首启噪音。判据见 [shouldShowChangelog]。
  Future<void> _maybeShowChangelog() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    final info = await PackageInfo.fromPlatform();
    final version = info.version;
    if (!shouldShowChangelog(
      seenForVersion: p.changelogSeenVersion,
      legacyOneShot: p.seenChangelog140,
      currentVersion: version,
    )) {
      // 新装用户：只记账，不打扰；下次升级才会看到更新说明。
      if (p.changelogSeenVersion == null) {
        await p.setChangelogSeenVersion(version);
        // ASR-217 P1-1 后半：新装用户改看「3 行上手卡」（升级方案 §1.8.4 P1-1 的欠项）。
        if (!p.quickStartSeen && mounted) await _showQuickStartCard(p);
      }
      return;
    }
    final c = buildChangelog(version);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await p.setChangelogSeenVersion(version);
      await p.setSeenChangelog140();
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kCard,
          title: Text(c.title, style: TextStyle(color: kText)),
          // ASR-213 P1-2：正文改成限高内滚动，按钮固定在 actions 区。
          // 旧写法是裸 Column，条目一多就把正文顶到按钮下面叠在一起。
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in c.items) ...[
                    Text(item, style: TextStyle(color: kTextSecondary)),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('开始使用', style: TextStyle(color: kPrimary)),
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
        unselectedItemColor: kTextMuted,
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

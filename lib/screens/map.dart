import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'level.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final content = Provider.of<ContentPack>(context);
    final progress = Provider.of<ProgressService>(context);
    final completed = progress.completedLevels;
    final levels = content.levels;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const TodayCard(),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.9,
          ),
          itemCount: levels.length,
          itemBuilder: (context, i) {
            final lv = levels[i];
            final unlocked = i == 0 || completed.contains(levels[i - 1].id);
            final done = completed.contains(lv.id);
            return _LevelCell(
              level: lv,
              unlocked: unlocked,
              fraction: done ? 1.0 : 0.0,
              dims: progress.dimsFor(lv.id),
              onTap: unlocked
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => LevelScreen(level: lv)),
                      )
                  : null,
              onLongPressLocked: () => showCnCard(context, '先完成上一关，就快了。'),
            );
          },
        ),
      ],
    );
  }
}

/// M5 首页今日会话卡：展示到期数 / 冷启动“今天开始”，一击开练。
class TodayCard extends StatefulWidget {
  const TodayCard({super.key});
  @override
  State<TodayCard> createState() => _TodayCardState();
}

class _TodayCardState extends State<TodayCard> {
  int _due = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    final due = await p.chunkStore.dueChunkKeys(DateTime.now().millisecondsSinceEpoch);
    if (mounted) setState(() => _due = due.length);
  }

  @override
  Widget build(BuildContext context) {
    final content = Provider.of<ContentPack>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    final completed = progress.completedLevels;
    final levels = content.levels;
    final target =
        levels.firstWhere((l) => !completed.contains(l.id), orElse: () => levels.first);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: kCard,
        border: Border.all(color: kPrimary.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('今日会话',
              style: TextStyle(color: kPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            _due > 0
                ? '$_due 个词块到期复习'
                : (progress.streak == 0 ? '今天开始 · 新学一关' : '今天也来练一练'),
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => LevelScreen(level: target)),
              ),
              child: const Text('一击开练', style: TextStyle(color: Colors.black87)),
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelCell extends StatelessWidget {
  final Level level;
  final bool unlocked;
  final double fraction;
  final List<bool> dims;
  final VoidCallback? onTap;
  final VoidCallback? onLongPressLocked;
  const _LevelCell({
    required this.level,
    required this.unlocked,
    required this.fraction,
    required this.dims,
    this.onTap,
    this.onLongPressLocked,
  });

  @override
  Widget build(BuildContext context) {
    final color = unlocked ? kUnlocked : kLocked;
    return GestureDetector(
      onTap: onTap ??
          () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Finish the previous level. You’re close.'),
                duration: Duration(seconds: 2),
              ),
            );
          },
      onLongPress: unlocked ? null : onLongPressLocked,
      child: Container(
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MasteryRing(fraction, size: 36),
            const SizedBox(height: 6),
            Text(level.id,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: unlocked ? Colors.white : kLocked)),
            const SizedBox(height: 4),
            Expanded(
              child: Center(
                child: Text(level.theme,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: unlocked ? Colors.white70 : kLocked)),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (di) => Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dims[di] ? kUnlocked : kLocked,
                ),
              )),
            ),
            const SizedBox(height: 4),
            Icon(unlocked ? Icons.play_arrow : Icons.lock,
                color: color, size: 18),
          ],
        ),
      ),
    );
  }
}

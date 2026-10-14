import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'level.dart';
import 'settings.dart';
import 'review.dart';
import 'me.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final content = Provider.of<ContentPack>(context);
    final progress = Provider.of<ProgressService>(context);
    final completed = progress.completedLevels;
    final levels = content.levels;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ChunkSpoke'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ReviewScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.person, color: Colors.white70),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const MeScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: GridView.builder(
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
          color: const Color(0xFF1A1A2E),
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'settings.dart';

class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final progress = Provider.of<ProgressService>(context);
    final content = Provider.of<ContentPack>(context);
    final streak = progress.streak;
    final hintRate = progress.sayCount + progress.hintCount > 0
        ? (progress.hintCount / (progress.hintCount + progress.sayCount) * 100).round()
        : 0;
    final acc = progress.avgScore.round();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FutureBuilder<int>(
          future: progress.chunksMastered(content),
          builder: (c, s) {
            final total = content.levels.fold<int>(0, (n, l) => n + l.chunks.length);
            return _stat('已掌握词块', '${s.data ?? 0}/$total', 'L2一次过+L4≥80%');
          },
        ),
        _stat('连续打卡', '$streak', '连续天数'),
        _stat('中文提示率', '$hintRate%', '越低越好'),
        _stat('平均准确度', '$acc', '文本匹配 / 发音评分'),
        _GoalCard(progress: progress),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            child: const Text('设置', style: TextStyle(color: Colors.black87)),
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, String value, [String sub = '']) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  if (sub.isNotEmpty)
                    Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          ],
        ),
      );
}

class _GoalCard extends StatelessWidget {
  final ProgressService progress;
  const _GoalCard({required this.progress});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: Future.value(progress.dailyGoal),
      builder: (c, s) {
        final g = s.data ?? 5;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: kCard, borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('每日目标',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [5, 10, 20]
                    .map((n) => ChoiceChip(
                          label: Text('$n 句'),
                          selected: g == n,
                          selectedColor: kPrimary,
                          labelStyle: TextStyle(
                              color: g == n ? Colors.black87 : Colors.white70),
                          onSelected: (_) => progress.setDailyGoal(n),
                        ))
                    .toList(),
              ),
            ],
          ),
        );
      },
    );
  }
}

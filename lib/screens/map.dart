import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'level.dart';
import 'review.dart';

import '../ui/labels.dart';

String _cn(Level lv) => sceneCn(lv.theme);

/// 难度分组（按内容顺序切三档：入门 / 进阶 / 挑战）。
const List<(String, int, int)> _tiers = [
  ('入门', 0, 9),
  ('进阶', 9, 18),
  ('挑战', 18, 999),
];

/// 场景解锁门槛：上一场景 mastered ≥ 80%（替换旧的“字母顺序解锁”）。
const double _unlockRatio = 0.8;

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final content = Provider.of<ContentPack>(context);
    final progress = Provider.of<ProgressService>(context);
    final levels = content.levels;

    return Scaffold(
      appBar: AppBar(title: const Text('练习')),
      body: FutureBuilder<(Set<String>, List<String>)>(
        future: (() async {
          final m = (await progress.chunkStore.allMasteredKeys()).toSet();
          final due =
              await progress.chunkStore.dueChunkKeys(DateTime.now().millisecondsSinceEpoch);
          return (m, due);
        })(),
        builder: (ctx, snap) {
          final mastered = snap.data?.$1 ?? <String>{};
          final due = snap.data?.$2 ?? const <String>[];
          int masteredIn(Level lv) =>
              lv.chunks.where((c) => mastered.contains(c.id)).length;
          bool unlockedAt(int i) => i == 0 ||
              (i > 0 &&
                  masteredIn(levels[i - 1]) / levels[i - 1].chunks.length >=
                      _unlockRatio);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TodayCard(mastered: mastered, content: content, due: due),
              const SizedBox(height: 18),
              for (final (label, start, end) in _tiers)
                if (start < levels.length) ...[
                  _TierHeader(label),
                  const SizedBox(height: 8),
                  ...levels.asMap().entries
                      .where((e) => e.key >= start && e.key < end)
                      .map((e) => _SceneRow(
                            level: e.value,
                            index: e.key,
                            unlocked: unlockedAt(e.key),
                            masteredCount: masteredIn(e.value),
                            mastered: mastered,
                          ))
                      .toList(),
                  const SizedBox(height: 14),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _TierHeader extends StatelessWidget {
  final String label;
  const _TierHeader(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 2),
        child: Row(
          children: [
            Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                    color: kPrimary, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(
                    color: kPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

class _SceneRow extends StatelessWidget {
  final Level level;
  final int index;
  final bool unlocked;
  final int masteredCount;
  final Set<String> mastered;
  const _SceneRow(
      {required this.level,
      required this.index,
      required this.unlocked,
      required this.masteredCount,
      required this.mastered});

  @override
  Widget build(BuildContext context) {
    final total = level.chunks.length;
    final done = masteredCount >= (total * _unlockRatio);
    return Opacity(
      opacity: unlocked ? 1 : 0.5,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: kBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: done ? kUnlocked.withOpacity(0.6) : Colors.white12),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          leading: unlocked
              ? Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: kPrimary.withOpacity(0.15),
                    border: Border.all(color: kPrimary.withOpacity(0.5)),
                  ),
                  child: done
                      ? const Icon(Icons.check, color: kUnlocked)
                      : Center(
                          child: Text('${index + 1}',
                              style: const TextStyle(
                                  color: kPrimary,
                                  fontWeight: FontWeight.w600)),
                        ),
                )
              : const Icon(Icons.lock, color: Colors.white38),
          title: Text(_cn(level),
              style: const TextStyle(
                  color: kText, fontSize: 17, fontWeight: FontWeight.w600)),
          subtitle: Text(done ? '已通关' : '$masteredCount/$total 已掌握',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          trailing: unlocked
              ? const Icon(Icons.arrow_forward_ios,
                  size: 16, color: Colors.white38)
              : null,
          onTap: unlocked
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => LevelScreen(level: level)),
                  )
              : () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('上一场景掌握度需达 80% 才能解锁')),
                  ),
        ),
      ),
    );
  }
}

class TodayCard extends StatelessWidget {
  final Set<String> mastered;
  final ContentPack content;
  final List<String> due;
  const TodayCard(
      {super.key,
      required this.mastered,
      required this.content,
      required this.due});

  @override
  Widget build(BuildContext context) {
    final masteredCount = mastered.length; // 已掌握总数（概览）
    final anyLocked = content.levels
        .any((lv) => mastered.intersection(lv.chunks.map((c) => c.id).toSet()).length <
            (lv.chunks.length * _unlockRatio));
    final theme = anyLocked ? '今天开始 · 攻克未掌握' : '今天也来练一练';

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1B2E), Color(0xFF241A06)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kPrimary.withOpacity(0.45)),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 14, offset: Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: kPrimary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(theme,
                    style: const TextStyle(
                        color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              const Text('今日会话',
                  style: TextStyle(color: kPrimary, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '已掌握 $masteredCount 个词块',
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            anyLocked ? '温故知新，把未掌握的词块练到 80%' : '保持节奏，每天 5 分钟',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          if (due.isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ReviewScreen()),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                decoration: BoxDecoration(
                  color: kUnlocked.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kUnlocked.withOpacity(0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.replay, color: kUnlocked, size: 18),
                    const SizedBox(width: 8),
                    Text('今日复习 ${due.length} 个词块',
                        style: const TextStyle(color: kUnlocked, fontSize: 15)),
                    const Spacer(),
                    const Icon(Icons.arrow_forward_ios, size: 14, color: kUnlocked),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kPrimary,
                foregroundColor: Colors.black87,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => _openToday(context),
              child: const Text('一击开练',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  void _openToday(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final content = this.content;
    // 到期复习优先：进入复习会话（② 开口说块 + ④ 开口说句，轻量两步）。
    if (due.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ReviewScreen()),
      );
      return;
    }
    final firstUnlockedLocked = content.levels.firstWhere(
      (l) => !mastered
          .intersection(l.chunks.map((c) => c.id).toSet())
          .contains(l.chunks.first.id),
      orElse: () => content.levels.first,
    );
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LevelScreen(level: firstUnlockedLocked)),
    );
  }
}

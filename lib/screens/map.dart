import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'level.dart';
import 'review.dart';

/// 场景中文名（去掉字母前缀，直接用场景名）。key 为 content_pack 的 theme。
const Map<String, String> _sceneCN = {
  'Asking for things': '索取东西',
  'Breakfast': '早餐',
  'Coffee & Cafe': '咖啡馆',
  'Directions': '问路',
  'Eating out': '外出就餐',
  'Feelings': '情绪表达',
  'Greetings': '打招呼',
  'Home & Hotel': '住宿·酒店',
  'Invitations': '邀请',
  'Just checking': '确认一下',
  'Kind requests': '委婉请求',
  "Let's go": '出发吧',
  'Morning routine': '晨间日常',
  'Numbers & paying': '数字与付款',
  'Opinions': '表达看法',
  'Places': '地点',
  'Quick responses': '快速回应',
  'Restaurant': '餐厅点餐',
  'Shopping': '购物',
  'Time & plans': '时间与计划',
  'Understanding': '听懂对方',
  'Weekend vibes': '周末时光',
  'Weather': '天气',
  'eXclamations': '感叹语',
  'Yes & no': '是与否',
  'Sleep & rest': '睡眠与休息',
};

String _cn(Level lv) => _sceneCN[lv.theme] ?? lv.theme;

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
      body: FutureBuilder<Set<String>>(
        future: progress.chunkStore.allMasteredKeys().then((l) => l.toSet()),
        builder: (ctx, snap) {
          final mastered = snap.data ?? <String>{};
          int masteredIn(Level lv) =>
              lv.chunks.where((c) => mastered.contains(c.id)).length;
          bool unlockedAt(int i) => i == 0 ||
              (i > 0 &&
                  masteredIn(levels[i - 1]) / levels[i - 1].chunks.length >=
                      _unlockRatio);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TodayCard(mastered: mastered, content: content),
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
  const TodayCard({super.key, required this.mastered, required this.content});

  @override
  Widget build(BuildContext context) {
    final due = mastered.length; // 已掌握总数（概览）
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
            '已掌握 $due 个词块',
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            anyLocked ? '温故知新，把未掌握的词块练到 80%' : '保持节奏，每天 5 分钟',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
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

  void _openToday(BuildContext context) {
    HapticFeedback.mediumImpact();
    final content = this.content;
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

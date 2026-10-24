import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/count_up.dart';
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
            final n = s.data ?? 0;
            final combo = n > 1 ? n * (n - 1) ~/ 2 : 0;
            return Column(
              children: [
                _stat('已掌握词块', '$n 个',
                    help: () => _showMasteryHelp(context)),
                _stat('累计可组合句子', '$combo+', sub: '越学越强大'),
              ],
            );
          },
        ),
        _stat('连续打卡', '$streak', sub: '连续天数'),
        _stat('中文提示率', '$hintRate%', sub: '越低说明你越脱稿，继续加油'),
        FutureBuilder<int>(
          future: _unlockedScenes(progress, content),
          builder: (c, s) {
            final unlockedScenes = s.data ?? 0;
            final avgText = progress.firstPracticeDone
                ? '$acc'
                : '完成首次练习后显示';
            return Column(
              children: [
                _stat('平均准确度', avgText, sub: '文本匹配相似度'),
                // A2①：发音评分独立展示，未配置发音服务时显示「—」，绝不显示 0。
                _stat('发音评分', '—',
                    sub: progress.azureKey == null ? '未配置发音评分' : '已配置发音服务'),
                _stat('自由造句次数', '${progress.freeBuildCount} 次',
                    sub: '用已学词块自由开口'),
                _stat('已解锁场景', '$unlockedScenes 个',
                    sub: '场景内达标块 ≥60%'),
              ],
            );
          },
        ),
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

  /// 掌握度 ≥60% 的场景数（场景解锁统计）。
  Future<int> _unlockedScenes(ProgressService p, ContentPack content) async {
    final mastered = (await p.chunkStore.allMasteredKeys()).toSet();
    int n = 0;
    for (final lv in content.levels) {
      final m = lv.chunks.where((c) => mastered.contains(c.id)).length;
      if (lv.chunks.isNotEmpty && m / lv.chunks.length >= 0.6) n++;
    }
    return n;
  }

  void _showMasteryHelp(BuildContext context) => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: kCard,
          title: const Text('掌握标准',
              style: TextStyle(color: Colors.white)),
          content: const Text(
            '学完六步后进入巩固周期；走完 1/3/7/14 天复习且每次通过，'
            '即成为「已掌握」词块。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了', style: TextStyle(color: kPrimary)),
            ),
          ],
        ),
      );

  Widget _statValue(String value) {
    final m = RegExp(r'^(\d+)(.*)$').firstMatch(value);
    if (m == null) {
      return Text(value,
          style: const TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold));
    }
    final suffix = m.group(2) ?? '';
    return CountUpText(int.parse(m.group(1)!),
        style: const TextStyle(
            color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        format: (v) => '$v$suffix');
  }

  Widget _stat(String label, String value,
          {String sub = '', VoidCallback? help}) =>
      Container(
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
                  Row(
                    children: [
                      Text(label,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14)),
                      if (help != null) ...[
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: help,
                          child: const Icon(Icons.help_outline,
                              size: 14, color: Colors.white38),
                        ),
                      ],
                    ],
                  ),
                  if (sub.isNotEmpty)
                    Text(sub,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            // M1（数字滚动）：以数字开头的统计值滚到位（450ms ≤600ms），非数字文案原样显示。
            _statValue(value),
          ],
        ),
      );
}

class _GoalCard extends StatefulWidget {
  final ProgressService progress;
  const _GoalCard({required this.progress});

  @override
  State<_GoalCard> createState() => _GoalCardState();
}

class _GoalCardState extends State<_GoalCard> {
  /// 同步 getter 直接读内存缓存，无需 FutureBuilder：
  /// 旧实现每次 build 都新建 Future，先渲染一帧旧值再跳新值，
  /// 且 setDailyGoal 不触发上层重建，导致「点了没反应、离开页面才变」。
  late int _goal = widget.progress.dailyGoal;

  @override
  void didUpdateWidget(covariant _GoalCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cur = widget.progress.dailyGoal;
    if (cur != _goal) _goal = cur;
  }

  void _select(int n) {
    if (n == _goal) return;
    setState(() => _goal = n); // 点击即时反馈
    widget.progress.setDailyGoal(n); // 落库（异步，不阻塞交互）
  }

  @override
  Widget build(BuildContext context) {
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
                      selected: _goal == n,
                      selectedColor: kPrimary,
                      labelStyle: TextStyle(
                          color: _goal == n ? Colors.black87 : Colors.white70),
                      onSelected: (_) => _select(n),
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('今日已开口 ${widget.progress.todaySpoken} / $_goal 句',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const Spacer(),
              if (widget.progress.todaySpoken >= _goal)
                const Text('已达成 ✓',
                    style: TextStyle(color: kUnlocked, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _goal > 0
                  ? (widget.progress.todaySpoken / _goal).clamp(0.0, 1.0)
                  : 0.0,
              minHeight: 8,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(kUnlocked),
            ),
          ),
        ],
      ),
    );
  }
}

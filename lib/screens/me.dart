import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/database.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/count_up.dart';
import 'pronunciation_screen.dart';
import 'settings.dart';

class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final progress = Provider.of<ProgressService>(context);
    final content = Provider.of<ContentPack>(context);
    final streak = progress.streak;
    final hintRate = progress.sayCount + progress.hintCount > 0
        ? (progress.hintCount / (progress.hintCount + progress.sayCount) * 100)
            .round()
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
                _stat('已掌握词块', '$n 个', help: () => _showMasteryHelp(context)),
                _stat('累计可组合句子', '$combo+', sub: '越学越强大'),
              ],
            );
          },
        ),
        // 核心库覆盖（指令 N §四.2）：只在这里出现，首页不放进任何进度元素。
        FutureBuilder<int>(
          future: progress.coreMastered(content),
          builder: (c, s) => _stat(
            '核心库覆盖',
            'T0 ${s.data ?? 0}/${ProgressService.coreTotal(content)}',
            sub: 'T0 核心块已掌握 / 总量',
          ),
        ),
        _stat('连续打卡', '$streak', sub: '连续天数'),
        _stat('中文提示率', '$hintRate%', sub: '越低说明你越脱稿，继续加油'),
        FutureBuilder<int>(
          future: _unlockedScenes(progress, content),
          builder: (c, s) {
            final unlockedScenes = s.data ?? 0;
            final avgText = progress.firstPracticeDone ? '$acc' : '完成首次练习后显示';
            return Column(
              children: [
                _stat('平均准确度', avgText, sub: '文本匹配相似度'),
                // A2①：发音评分独立展示；1.5.9 起点击进入本机发音评测（免费能力）。
                GestureDetector(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const PronunciationScreen())),
                  child: _stat(
                    '发音评分',
                    '—',
                    sub: progress.azureKey == null
                        ? '点这里测一次发音（本机评分）'
                        : '已配置发音服务 · 点这里评测',
                  ),
                ),
                _stat('自由造句次数', '${progress.freeBuildCount} 次',
                    sub: '用已学词块自由开口'),
                _stat('已解锁场景', '$unlockedScenes 个', sub: '场景内达标块 ≥60%'),
              ],
            );
          },
        ),
        _CalendarCard(progress: progress),
        _GoalCard(progress: progress),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
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
          title: const Text('掌握标准', style: TextStyle(color: Colors.white)),
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

/// 学习日历（1.5.9）：月视图 + 当日三数，无热力图。
/// 数据只读既有 `chunks.first_learned_at` + `sessions`，口径见
/// `验收-v1.5.9/学习日历-口径-1.5.9.md`。
class _CalendarCard extends StatefulWidget {
  final ProgressService progress;
  const _CalendarCard({required this.progress});

  @override
  State<_CalendarCard> createState() => _CalendarCardState();
}

class _CalendarCardState extends State<_CalendarCard> {
  late DateTime _month; // 当月 1 日
  late DateTime _selected;
  Future<Map<String, DayActivity>>? _future;

  @override
  void initState() {
    super.initState();
    final n = widget.progress.now;
    _month = DateTime(n.year, n.month);
    _selected = DateTime(n.year, n.month, n.day);
    _load();
  }

  /// 一次查整月；只在切月时重查，点某天不查库。
  void _load() {
    _future = widget.progress.dayActivity(
        DateTime(_month.year, _month.month, 1),
        DateTime(_month.year, _month.month + 1, 0));
  }

  bool get _canGoNext {
    final n = widget.progress.now;
    return _month.isBefore(DateTime(n.year, n.month));
  }

  void _shiftMonth(int delta) {
    final n = widget.progress.now;
    final today = DateTime(n.year, n.month, n.day);
    final next = DateTime(_month.year, _month.month + delta);
    if (next.isAfter(DateTime(today.year, today.month))) return;
    setState(() {
      _month = next;
      _selected =
          (next.year == today.year && next.month == today.month) ? today : next;
      _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.progress.now;
    final today = DateTime(n.year, n.month, n.day);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration:
          BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
      child: FutureBuilder<Map<String, DayActivity>>(
        future: _future,
        builder: (context, snap) {
          final data = snap.data ?? const <String, DayActivity>{};
          final sel = data[dayKey(_selected)] ?? const DayActivity();
          final days = DateTime(_month.year, _month.month + 1, 0).day;
          final lead = DateTime(_month.year, _month.month, 1).weekday - 1;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('学习日历',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _shiftMonth(-1),
                    icon: const Icon(Icons.chevron_left,
                        size: 20, color: Colors.white70),
                  ),
                  Text('${_month.year} 年 ${_month.month} 月',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: _canGoNext ? () => _shiftMonth(1) : null,
                    icon: Icon(Icons.chevron_right,
                        size: 20,
                        color: _canGoNext ? Colors.white70 : Colors.white24),
                  ),
                  const Spacer(),
                  if (_selected == today)
                    const Text('今天',
                        style: TextStyle(color: kPrimary, fontSize: 11)),
                ],
              ),
              Row(
                children: ['一', '二', '三', '四', '五', '六', '日']
                    .map((w) => Expanded(
                          child: Center(
                            child: Text(w,
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 11)),
                          ),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 4),
              GridView.count(
                crossAxisCount: 7,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.15,
                children: [
                  for (var i = 0; i < lead; i++) const SizedBox.shrink(),
                  for (var d = 1; d <= days; d++)
                    _dayCell(
                      d,
                      hasActivity: !(data[dayKey(
                                  DateTime(_month.year, _month.month, d))] ??
                              const DayActivity())
                          .isEmpty,
                      isToday: DateTime(_month.year, _month.month, d) == today,
                      selected:
                          DateTime(_month.year, _month.month, d) == _selected,
                    ),
                ],
              ),
              const Divider(color: Colors.white12, height: 20),
              Text(
                '${_selected.month} 月 ${_selected.day} 日 · 当日三数',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _triple('新学块', sel.newChunks),
                  _triple('复习', sel.reviews),
                  _triple('通过', sel.passes),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _dayCell(int day,
      {required bool hasActivity,
      required bool isToday,
      required bool selected}) {
    return GestureDetector(
      onTap: () =>
          setState(() => _selected = DateTime(_month.year, _month.month, day)),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color:
              selected ? kPrimary.withValues(alpha: 0.22) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isToday && !selected
              ? Border.all(color: kPrimary.withValues(alpha: 0.4))
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$day',
                style: TextStyle(
                    color: selected ? kPrimary : Colors.white70,
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal)),
            const SizedBox(height: 2),
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: hasActivity ? kPrimary : Colors.transparent,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _triple(String label, int value) => Expanded(
        child: Column(
          children: [
            Text('$value',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
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
      decoration:
          BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
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

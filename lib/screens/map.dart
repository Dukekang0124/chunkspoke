import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/chunk_asset.dart';
import '../services/loaders.dart';
import '../services/scene_progression.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'level.dart';
import 'review.dart';
import 'free_build_screen.dart';

import '../ui/labels.dart';

String _cn(Level lv) => sceneCn(lv.theme);

/// 难度分组（按内容顺序切三档：入门 / 进阶 / 挑战）。
const List<(String, int, int)> _tiers = [
  ('入门', 0, 9),
  ('进阶', 9, 18),
  ('挑战', 18, 999),
];

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  Future<_MapData>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// 两条轴各取所需：
  ///  - levelMastered：场景解锁/推进（旧关卡轴，继续保留）；
  ///  - learned/assetMastered：W2-1 所有「已掌握/已学完」计数（资产轴）。
  Future<_MapData> _load() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    final levelMastered =
        (await progress.chunkStore.allMasteredKeys()).toSet();
    final rows = await progress.chunkStore.allRows();
    final contentIds = <String>{
      for (final lv in content.levels)
        for (final c in lv.chunks) c.id,
    };
    final learned = <String>{
      for (final r in rows)
        if (contentIds.contains(r.chunkKey) &&
            r.assetState != ChunkAssetState.learning)
          r.chunkKey,
    };
    final assetMastered = rows
        .where((r) =>
            contentIds.contains(r.chunkKey) &&
            r.assetState == ChunkAssetState.mastered)
        .length;
    final nowMs = progress.now.millisecondsSinceEpoch;
    final due = await progress.chunkStore.dueChunkKeys(nowMs);
    final next = await progress.chunkStore.nextDueTimestamp(nowMs);
    return _MapData(
      levelMastered: levelMastered,
      learned: learned,
      assetMastered: assetMastered,
      due: due,
      nextDue: next,
    );
  }

  /// 从会话/复习返回后刷新计数：ProgressService 非 ChangeNotifier，
  /// 必须显式重建，否则首页计数停留在进入前的值（S12）。
  void _reload() {
    if (!mounted) return;
    final next = _load();
    // 不能用箭头函数：赋值表达式的返回值是 Future，setState 会直接抛错且不重建。
    setState(() {
      _future = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = Provider.of<ContentPack>(context);
    final levels = content.levels;

    return Scaffold(
      appBar: AppBar(title: const Text('练习')),
      body: FutureBuilder<_MapData>(
        future: _future,
        builder: (ctx, snap) {
          final data = snap.data;
          final mastered = data?.levelMastered ?? <String>{};
          final learned = data?.learned ?? <String>{};
          final assetMastered = data?.assetMastered ?? 0;
          final due = data?.due ?? const <String>[];
          final nextDue = data?.nextDue;
          final progress = Provider.of<ProgressService>(context);
          int masteredIn(Level lv) => masteredInLevel(lv, mastered);
          bool unlockedAt(int i) => isSceneUnlocked(levels, i, mastered);
          String lockedHintFor(int i) {
            final prev = levels[i - 1];
            return '先完成「${_cn(prev)}」：本场景达标 '
                '${sceneUnlockTarget(prev)}/${prev.chunks.length} 块解锁'
                '（当前 ${masteredIn(prev)}/${prev.chunks.length}）';
          }

          // A1：自由造句沙盒——累计学完（资产轴非新学）≥10 块全局解锁。
          final learnedChunks = <Chunk>[];
          for (final lv in levels) {
            for (final c in lv.chunks) {
              if (learned.contains(c.id)) learnedChunks.add(c);
            }
          }
          final combo = learnedChunks.length > 1
              ? learnedChunks.length * (learnedChunks.length - 1) ~/ 2
              : 0;
          final sandboxOn = freeBuildUnlocked(learnedChunks.length);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TodayCard(
                  levelMastered: mastered,
                  learned: learned,
                  assetMasteredCount: assetMastered,
                  content: content,
                  due: due,
                  nextDue: nextDue,
                  dailyNew: progress.dailyNewCount,
                  onReturn: _reload),
              const SizedBox(height: 12),
              _FreeBuildCard(
                learnedCount: learnedChunks.length,
                combo: combo,
                unlocked: sandboxOn,
                learnedChunks: learnedChunks,
                onReturn: _reload,
              ),
              const SizedBox(height: 18),
              for (final (label, start, end) in _tiers)
                if (start < levels.length) ...[
                  _TierHeader(label),
                  const SizedBox(height: 8),
                  ...levels
                      .asMap()
                      .entries
                      .where((e) => e.key >= start && e.key < end)
                      .map((e) => _SceneRow(
                            level: e.value,
                            index: e.key,
                            unlocked: unlockedAt(e.key),
                            lockedHint: e.key > 0 ? lockedHintFor(e.key) : null,
                            masteredCount: masteredIn(e.value),
                            onReturn: _reload,
                          )),
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

/// A1：自由造句沙盒入口卡片——累计学完 ≥10 块全局解锁，可点击进入沙盒。
class _FreeBuildCard extends StatelessWidget {
  final int learnedCount;
  final int combo;
  final bool unlocked;
  final List<Chunk> learnedChunks;
  final VoidCallback onReturn;
  const _FreeBuildCard({
    required this.learnedCount,
    required this.combo,
    required this.unlocked,
    required this.learnedChunks,
    required this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: unlocked ? 1 : 0.65,
      child: GestureDetector(
        onTap: unlocked
            ? () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          FreeBuildScreen(learnedChunks: learnedChunks)),
                );
                onReturn();
              }
            : null,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF241A06), Color(0xFF1A1B2E)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: unlocked ? kPrimary.withValues(alpha: 0.6) : Colors.white12),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, color: kPrimary, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('自由造句沙盒 · 累计可组合句子 $combo+',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      unlocked
                          ? '已学完 $learnedCount 块，选块拼句、开口判定'
                          : '累计学完 10 块解锁（当前 $learnedCount/10）',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(unlocked ? Icons.arrow_forward_ios : Icons.lock,
                  size: 16, color: unlocked ? kPrimary : Colors.white38),
            ],
          ),
        ),
      ),
    );
  }
}

class _SceneRow extends StatelessWidget {
  final Level level;
  final int index;
  final bool unlocked;
  final String? lockedHint;
  final int masteredCount;
  final VoidCallback onReturn;
  const _SceneRow(
      {required this.level,
      required this.index,
      required this.unlocked,
      this.lockedHint,
      required this.masteredCount,
      required this.onReturn});

  Future<void> _open(BuildContext context) async {
    if (!unlocked) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(lockedHint ?? '先完成上一场景，达标到 80% 解锁'),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    HapticFeedback.mediumImpact();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LevelScreen(level: level)),
    );
    onReturn();
  }

  @override
  Widget build(BuildContext context) {
    final total = level.chunks.length;
    final ratio = total > 0 ? masteredCount / total : 0.0;
    final done = masteredCount >= sceneUnlockTarget(level);
    final status = done ? '🟢' : (unlocked ? '🟡' : '⚪');
    return Opacity(
      opacity: unlocked ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _open(context),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: kBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: done ? kUnlocked.withValues(alpha: 0.6) : Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  unlocked
                      ? Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: kPrimary.withValues(alpha: 0.15),
                            border:
                                Border.all(color: kPrimary.withValues(alpha: 0.5)),
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_cn(level),
                            style: const TextStyle(
                                color: kText,
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text('$masteredCount/$total',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 13)),
                            const SizedBox(width: 6),
                            Text(status, style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // 场景圆环与本场景达标 x/y 同源（关卡轴，仅用于解锁）。
                  MasteryRing(total > 0 ? masteredCount / total : 0, size: 42),
                  const SizedBox(width: 8),
                  if (unlocked)
                    const Icon(Icons.arrow_forward_ios,
                        size: 16, color: Colors.white38),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  valueColor:
                      AlwaysStoppedAnimation(done ? kUnlocked : kPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TodayCard extends StatelessWidget {
  /// 关卡轴：只用于场景解锁/推进。
  final Set<String> levelMastered;
  /// 资产轴：已进入复习周期（非 learning）的块，用于“新学”筛选。
  final Set<String> learned;
  /// 资产轴：走完 1/3/7/14 天的块数（W2-1 头部唯一口径）。
  final int assetMasteredCount;
  final ContentPack content;
  final List<String> due;
  final int? nextDue; // 下一次资产复习到期（epoch ms；无则 null）
  final int dailyNew;
  final VoidCallback onReturn;
  const TodayCard(
      {super.key,
      required this.levelMastered,
      required this.learned,
      required this.assetMasteredCount,
      required this.content,
      required this.due,
      this.nextDue,
      this.dailyNew = 0,
      required this.onReturn});

  @override
  Widget build(BuildContext context) {
    // A3：每日会话瘦身——新学 ≤6（跨场景按序取资产轴尚未学过的块），复习到期优先。
    final newChunks = <String>[];
    for (final lv in content.levels) {
      for (final c in lv.chunks) {
        if (newChunks.length >= 6) break;
        if (!learned.contains(c.id)) newChunks.add(c.id);
      }
      if (newChunks.length >= 6) break;
    }
    final reviewCount = due.length;
    final newCount = newChunks.length;
    final allClear = reviewCount == 0 && newCount == 0;
    final anyLocked =
        content.levels.any((lv) => missingForUnlock(lv, levelMastered) > 0);
    final theme = anyLocked ? '今天开始 · 完成未解锁场景' : '今天也来练一练';
    final target = progressionTarget(content.levels, levelMastered);
    // 首页「下次复习」直接接资产复习引擎（无到期时展示下一次排期）。
    String nextDueText;
    if (due.isNotEmpty) {
      nextDueText = '今天';
    } else if (nextDue == null) {
      nextDueText = '暂无';
    } else {
      final d = DateTime.fromMillisecondsSinceEpoch(nextDue!);
      nextDueText = '${d.month}月${d.day}日';
    }

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1B2E), Color(0xFF241A06)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kPrimary.withValues(alpha: 0.45)),
        boxShadow: const [
          BoxShadow(
              color: Colors.black45, blurRadius: 14, offset: Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: kPrimary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(theme,
                    style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              const Text('今日会话',
                  style: TextStyle(color: kPrimary, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '已掌握 $assetMasteredCount 个词块',
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '复习 $reviewCount 个 + 新学 $newCount 个 · '
            '已学完 ${learned.length} 块',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '下次复习：$nextDueText',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          if (due.isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReviewScreen()),
                );
                onReturn();
              },
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                decoration: BoxDecoration(
                  color: kUnlocked.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kUnlocked.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.replay, color: kUnlocked, size: 18),
                    const SizedBox(width: 8),
                    Text('今日复习 ${due.length} 个词块',
                        style: const TextStyle(color: kUnlocked, fontSize: 15)),
                    const Spacer(),
                    const Icon(Icons.arrow_forward_ios,
                        size: 14, color: kUnlocked),
                  ],
                ),
              ),
            ),
          ],
          if (allClear) ...[
            const SizedBox(height: 12),
            const Text('今日已清空，明天见 🎉',
                style: TextStyle(
                    color: kUnlocked,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
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
              onPressed:
                  target == null ? null : () => _openToday(context, target),
              child: Text(target == null ? '已全部通关' : '继续学习：${_cn(target)}',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  void _openToday(BuildContext context, Level target) async {
    HapticFeedback.mediumImpact();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LevelScreen(level: target)),
    );
    onReturn();
  }
}


class _MapData {
  final Set<String> levelMastered;
  final Set<String> learned;
  final int assetMastered;
  final List<String> due;
  final int? nextDue;
  const _MapData({
    required this.levelMastered,
    required this.learned,
    required this.assetMastered,
    required this.due,
    required this.nextDue,
  });
}

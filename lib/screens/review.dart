import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/chunk_progress.dart';
import '../services/loaders.dart';
import '../services/license_state.dart';
import '../services/review_notify.dart';
import '../services/session.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';
import '../ui/pressable.dart';
import '../ui/stagger.dart';
import '../steps/practice_loop.dart';

/// 复习页：展示到期复习词块（统一以 chunk.id 为键，与 chunks 表一致）。
/// 复习走「四步」——① 听辨 → ② 跟读 → ③ 替换 → ④ 开口说句；
/// 结果由词块资产状态机升档/降档（1d/3d/7d/14d），每日上限 20 块。
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Future<ReviewQueue>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final progress = Provider.of<ProgressService>(context, listen: false);
    setState(() {
      _future = progress.chunkStore.reviewQueue(progress.now);
    });
  }

  Map<String, Chunk> _lookup() {
    final content = Provider.of<ContentPack>(context, listen: false);
    final lookup = <String, Chunk>{};
    for (final lv in content.levels) {
      for (final c in lv.chunks) {
        lookup[c.id] = c;
      }
    }
    return lookup;
  }

  /// 1.6.0（LIC-1 / G-5）：chunk.id → 所属场景下标。复习播单只排「当前有权进入」
  /// 的场景里的块（未解锁场景的块不占用每日 20 块上限）。
  Map<String, int> _levelIndex() {
    final content = Provider.of<ContentPack>(context, listen: false);
    return {
      for (var i = 0; i < content.levels.length; i++)
        for (final c in content.levels[i].chunks) c.id: i,
    };
  }

  void _startReview(List<Chunk> due) {
    final content = Provider.of<ContentPack>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('复习课堂')),
          body: PracticeLoop(
            level: PracticeSession.reviewLevel(content, due),
            chunks: due,
            reviewMode: true,
            onDone: (_) => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    ).then((_) {
      _reload();
      syncReviewReminder(progress);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lookup = _lookup();
    final lic = Provider.of<LicenseState?>(context, listen: true);
    final levelOf = lic == null ? const <String, int>{} : _levelIndex();
    bool allowedChunk(String chunkKey) {
      if (lic == null) return true;
      final i = levelOf[chunkKey];
      return i == null || lic.allowsLevel(i);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('复习')),
      body: FutureBuilder<ReviewQueue>(
        future: _future,
        builder: (ctx, snap) {
          final q = snap.data ??
              const ReviewQueue(items: [], dueTotal: 0, reviewedToday: 0);
          final known = q.items.where((r) => lookup.containsKey(r.chunkKey));
          final dropped = known.where((r) => !allowedChunk(r.chunkKey)).length;
          final items = known
              .where((r) => allowedChunk(r.chunkKey))
              .map((r) => lookup[r.chunkKey]!)
              .toList();
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  q.capped
                      ? '今日复习已达上限 ${q.cap} 块\n剩余 ${q.dueTotal} 块明天继续'
                      : '今天没有待复习词块',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextSecondary, fontSize: 16),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              PressableScale(
                scale: 0.98,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kUnlocked,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _startReview(items),
                    icon: Icon(Icons.play_arrow, color: kText),
                    label: Text('开始复习（${items.length} 个 · 听辨→跟读→替换→开口）',
                        style:
                            TextStyle(color: kText, fontSize: 15)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '今日已复习 ${q.reviewedToday}/${q.cap} 块 · 今日到期 ${q.dueTotal} 块'
                '${q.deferred > 0 ? ' · 超出上限 ${q.deferred} 块顺延到明天' : ''}'
                '${dropped > 0 ? ' · 另有 $dropped 块属于未解锁场景，暂不排入复习' : ''}',
                style: TextStyle(color: kTextMuted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              for (final (i, c) in items.indexed)
                StaggerIn(index: i, child: _ReviewItem(chunk: c)),
            ],
          );
        },
      ),
    );
  }
}

class _ReviewItem extends StatelessWidget {
  final Chunk chunk;
  const _ReviewItem({required this.chunk});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: kCard,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            ChunkTile(chunk.text, chunk.semantic),
            const SizedBox(width: 10),
            Expanded(
              child: Text(chunk.meaningCN,
                  style: TextStyle(color: kTextSecondary, fontSize: 14)),
            ),
            IconButton(
              icon: Icon(Icons.volume_up, color: kPrimary),
              onPressed: () => speakOrHint(context,
                  Provider.of<TtsService>(context, listen: false), chunk.text),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/session.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';
import '../steps/practice_loop.dart';

/// 复习页：展示到期复习词块（统一以 chunk.id 为键，与 chunks 表一致）。
/// 复习走「轻量两步」——② 开口说块 + ④ 开口说句（不再听辨块/块拼句）。
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Future<List<Chunk>>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final content = Provider.of<ContentPack>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    final lookup = <String, Chunk>{};
    for (final lv in content.levels) {
      for (final c in lv.chunks) lookup[c.id] = c;
    }
    setState(() {
      _future = progress.chunkStore
          .dueChunkKeys(DateTime.now().millisecondsSinceEpoch)
          .then((keys) => keys
              .where(lookup.containsKey)
              .map((k) => lookup[k]!)
              .toList());
    });
  }

  void _startReview(List<Chunk> due) {
    final content = Provider.of<ContentPack>(context, listen: false);
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
    ).then((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('复习')),
      body: FutureBuilder<List<Chunk>>(
        future: _future,
        builder: (ctx, snap) {
          final items = snap.data ?? const <Chunk>[];
          if (items.isEmpty) {
            return const Center(
              child: Text('今天没有待复习词块',
                  style: TextStyle(color: Colors.white70, fontSize: 16)),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kUnlocked,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => _startReview(items),
                  icon: const Icon(Icons.play_arrow, color: Colors.white),
                  label: Text('开始复习（${items.length} 个 · 开口说块 + 开口说句）',
                      style: const TextStyle(color: Colors.white, fontSize: 15)),
                ),
              ),
              const SizedBox(height: 16),
              for (final c in items) _ReviewItem(chunk: c),
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
      color: const Color(0xFF1A1A2E),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            ChunkTile(chunk.text, chunk.type),
            const SizedBox(width: 10),
            Expanded(
              child: Text(chunk.meaningCN,
                  style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ),
            IconButton(
              icon: const Icon(Icons.volume_up, color: kPrimary),
              onPressed: () => speakOrHint(
                  context,
                  Provider.of<TtsService>(context, listen: false),
                  chunk.text),
            ),
          ],
        ),
      ),
    );
  }
}

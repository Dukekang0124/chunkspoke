import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Review 次日队列：展示到期复习的词块（TTS 跟读 + 标记完成）。
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final content = Provider.of<ContentPack>(context);
    final progress = Provider.of<ProgressService>(context);
    final lookup = <String, Chunk>{};
    for (final lv in content.levels) {
      for (final c in lv.chunks) lookup['${lv.id}:${c.id}'] = c;
    }
    final items = progress
        .dueReviews()
        .where((k) => lookup.containsKey(k))
        .map((k) => lookup[k]!)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: items.isEmpty
          ? const Center(
              child: Text('No review due. Come back tomorrow!',
                  style: TextStyle(color: Colors.white70, fontSize: 16)),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final c = items[i];
                return Card(
                  color: const Color(0xFF1A1A2E),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ChunkTile(c.text, c.type),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.volume_up, color: kPrimary),
                              onPressed: () => Provider.of<TtsService>(context, listen: false)
                                  .speak(c.sentence.text),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(c.sentence.text,
                            style: const TextStyle(color: Colors.white, fontSize: 15)),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                            onPressed: () {
                              progress.removeReview('${_levelOf(content, c)}:${c.id}');
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                  content: Text('Reviewed!'), duration: Duration(seconds: 1)));
                            },
                            child: const Text('Mark reviewed',
                                style: TextStyle(color: Colors.white)),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  String _levelOf(ContentPack content, Chunk c) {
    for (final lv in content.levels) {
      if (lv.chunks.any((x) => x.id == c.id)) return lv.id;
    }
    return '';
  }
}

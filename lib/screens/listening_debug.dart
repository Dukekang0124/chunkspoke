import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/listening_article.dart';
import '../services/listening_audio.dart';
import '../services/listening_store.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'listening_player.dart';

/// 浸泡层调试入口（仅 Debug 构建可见）。
///
/// Q-2 只做应用内播放器核心；首页常驻入口在 Q-3/Q-4 接入。
/// 文章只有标题/场景，不显示任何 Day N 编号。
class ListeningDebugScreen extends StatelessWidget {
  const ListeningDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pack = Provider.of<ListeningPack>(context, listen: false);
    final store = Provider.of<ProgressService>(context, listen: false).listening;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('磨耳朵（预览）')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kPrimary.withValues(alpha: 0.3)),
            ),
            child: const Text(
              '浸泡层预览：被动收听不产出学习资产，只记录浸泡时长与完听。'
              '首次播放会逐句合成离线音频，之后走本地缓存；断网可用。',
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(height: 12),
          for (final a in pack.articles) ...[
            _articleTile(context, a, store),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  int _estimateMinutes(ListeningArticle a) {
    final ms = a.sentences.fold<int>(
        0, (sum, s) => sum + estimateLiveSentenceMs(s.text));
    return (ms / 60000).ceil().clamp(1, 999);
  }

  Widget _articleTile(
      BuildContext context, ListeningArticle a, ListeningStore store) {
    final completed = store.isCompleted(a.id);
    final pos = store.positionFor(a.id);
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ListeningPlayerPage(article: a)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(a.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: kText,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (completed) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.check_circle,
                              size: 14, color: kUnlocked),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${a.sceneLabel} · ${a.sentences.length} 句 · '
                      '约 ${_estimateMinutes(a)} 分钟'
                      '${pos != null ? ' · 上次听到 ${((pos.positionMs / 1000) / 60).floor()} 分' : ''}',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.play_circle_outline,
                  color: kPrimary, size: 26),
            ],
          ),
        ),
      ),
    );
  }
}

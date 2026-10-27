import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/session.dart';
import '../data/content.dart';
import '../data/vocab.dart';
import '../ui/theme.dart';
import '../widgets/app_only_notice.dart';
import 'review_screen.dart' show assetColor;

class ArticlesScreen extends StatefulWidget {
  const ArticlesScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<ArticlesScreen> createState() => _ArticlesScreenState();
}

class _ArticlesScreenState extends State<ArticlesScreen> {
  String _level = '全部';

  static const List<String> _levels = ['全部', 'A1', 'A2', 'B1', 'B2', 'C1'];

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return ValueListenableBuilder<bool>(
      valueListenable: session.contentReady,
      builder: (context, ready, _) {
        if (!ready) {
          return Center(
            child: Text(
              session.contentError.value == null ? '内容包加载中…' : '内容包加载失败',
              style: const TextStyle(color: Colors.white54),
            ),
          );
        }
        final articles = session.content!.articles;
        final visible = [
          for (final a in articles)
            if (_level == '全部' || a.level == _level) a,
        ];
        final sentenceCount = articles.fold<int>(0, (s, a) => s + a.sentences.length);
        final highlightCount = articles.fold<int>(0, (s, a) => s + a.highlightedSentenceCount);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                const Text(
                  '沉浸阅读',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Text(
                  '${articles.length} 篇 · $sentenceCount 句 · 其中 $highlightCount 句标了词块',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const Spacer(),
                const AppOnlyNotice(compact: true),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '左文右块：点文章进入双栏阅读，句内词块按层级着色；朗读与跟读在 App 内可用。',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final lv in _levels)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      key: Key('articles_filter_$lv'),
                      label: Text(
                        lv == '全部'
                            ? '全部 ${articles.length}'
                            : '$lv ${articles.where((a) => a.level == lv).length}',
                      ),
                      selected: _level == lv,
                      onSelected: (_) => setState(() => _level = lv),
                      selectedColor: kPrimary.withValues(alpha: 0.18),
                      checkmarkColor: kPrimary,
                      labelStyle: TextStyle(
                        color: _level == lv ? kPrimary : Colors.white60,
                        fontSize: 12,
                      ),
                      side: BorderSide(color: _level == lv ? kPrimary : kLocked),
                      backgroundColor: Colors.transparent,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, c) {
                final columns = c.maxWidth >= 1080 ? 3 : (c.maxWidth >= 720 ? 2 : 1);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 1.9,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, i) => _articleCard(visible[i]),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _articleCard(Article a) {
    final chunks = {
      for (final s in a.sentences)
        for (final c in s.chunks)
          if (!c.candidate) c.id,
    };
    return InkWell(
      key: Key('article_card_${a.id}'),
      onTap: () => context.go('/articles/${a.id}'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kLocked),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _levelBadge(a.level),
                const SizedBox(width: 8),
                Text(a.sceneLabel, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                const Spacer(),
                Text(a.id, style: const TextStyle(color: Colors.white24, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              a.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                a.summaryCN,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
              ),
            ),
            Row(
              children: [
                Text(
                  '${a.sentences.length} 句 · ${chunks.length} 个词块',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ArticleReaderScreen extends StatelessWidget {
  const ArticleReaderScreen({super.key, required this.session, required this.articleId});

  final AppSession session;
  final String articleId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: session.contentReady,
      builder: (context, ready, _) {
        final content = session.content;
        if (!ready || content == null) {
          return Center(
            child: Text(
              session.contentError.value == null ? '内容包加载中…' : '内容包加载失败',
              style: const TextStyle(color: Colors.white54),
            ),
          );
        }
        final article = _findArticle(content, articleId);
        if (article == null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('没有这篇文章', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => context.go('/articles'),
                  child: const Text('回到文章列表'),
                ),
              ],
            ),
          );
        }
        return ValueListenableBuilder<int>(
          valueListenable: session.revision,
          builder: (context, _, _) => _reader(context, article, content),
        );
      },
    );
  }

  Widget _reader(BuildContext context, Article article, ContentBundle content) {
    final coreChunks = <String, Chunk>{};
    for (final s in article.sentences) {
      for (final ref in s.chunks) {
        if (ref.candidate) continue;
        final chunk = content.byId[ref.id];
        if (chunk != null) coreChunks[ref.id] = chunk;
      }
    }
    final left = _articleBody(article);
    final right = _chunkPanel(article, coreChunks.values.toList());
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20, color: Colors.white70),
                tooltip: '返回文章列表',
                onPressed: () => context.go('/articles'),
              ),
              const SizedBox(width: 4),
              Text(
                article.title,
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              _levelBadge(article.level),
              const SizedBox(width: 8),
              Text(
                '${article.sceneLabel} · ${article.sentences.length} 句',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kLocked),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.volume_off, size: 14, color: Colors.white38),
                    SizedBox(width: 6),
                    Text(
                      '朗读/跟读在 App 内可用',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                if (c.maxWidth < 900) {
                  return Column(
                    children: [
                      Expanded(child: left),
                      const SizedBox(height: 12),
                      SizedBox(height: c.maxHeight * 0.4, child: right),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: left),
                    const SizedBox(width: 16),
                    SizedBox(width: 360, child: right),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _articleBody(Article article) {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kLocked),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        itemCount: article.sentences.length,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (context, i) {
          final s = article.sentences[i];
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 30,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(color: Colors.white24, fontSize: 11),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    s.hasCoreChunks
                        ? _highlighted(s, kBodyFontSize)
                        : Text(
                            s.text,
                            style: const TextStyle(color: kBodyText, fontSize: kBodyFontSize, height: 1.7),
                          ),
                    const SizedBox(height: 3),
                    Text(
                      s.meaningCN,
                      style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('sentence_play_${s.id}'),
                onPressed: null,
                icon: const Icon(Icons.play_circle_outline, size: 18),
                tooltip: '朗读在 App 内可用（网页版无语音）',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  disabledForegroundColor: Colors.white24,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _highlighted(ArticleSentence s, double fontSize) {
    final spans = <TextSpan>[];
    final text = s.text;
    // 长块优先，避免短块先命中把长块切开
    final refs = [...s.chunks.where((c) => !c.candidate)]
      ..sort((a, b) => b.text.length.compareTo(a.text.length));
    final marks = <(int, int, ChunkRef)>[];
    for (final ref in refs) {
      if (ref.text.isEmpty) continue;
      var start = 0;
      while (true) {
        final idx = text.toLowerCase().indexOf(ref.text.toLowerCase(), start);
        if (idx < 0) break;
        final end = idx + ref.text.length;
        final overlap = marks.any((m) => idx < m.$2 && end > m.$1);
        if (!overlap) marks.add((idx, end, ref));
        start = end;
      }
    }
    marks.sort((a, b) => a.$1.compareTo(b.$1));
    var cursor = 0;
    for (final m in marks) {
      if (m.$1 > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.$1)));
      }
      spans.add(
        TextSpan(
          text: text.substring(m.$1, m.$2),
          style: TextStyle(
            color: Colors.black,
            backgroundColor: _tierBg(m.$3.id),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      cursor = m.$2;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(
      TextSpan(children: spans),
      style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: fontSize, height: 1.7),
    );
  }

  Color _tierBg(String chunkId) {
    final chunk = session.content?.byId[chunkId];
    switch (chunk?.tier) {
      case 'T0':
        return kPrimary;
      case 'T1':
        return const Color(0xFF6FA8FF);
      default:
        return const Color(0xFF9BE3B8);
    }
  }

  Widget _chunkPanel(Article article, List<Chunk> chunks) {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kLocked),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Text(
                  '本文词块',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text('${chunks.length} 个', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                const Spacer(),
                _legend('T0', kPrimary),
                const SizedBox(width: 8),
                _legend('T1', const Color(0xFF6FA8FF)),
                const SizedBox(width: 8),
                _legend('T2', const Color(0xFF9BE3B8)),
              ],
            ),
          ),
          Expanded(
            child: chunks.isEmpty
                ? const Center(
                    child: Text('这篇没有标注核心词块', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: chunks.length,
                    separatorBuilder: (_, _) => const Divider(height: 16, color: kLocked, thickness: 0.5),
                    itemBuilder: (context, i) => _chunkTile(chunks[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _legend(String label, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      );

  Widget _chunkTile(Chunk chunk) {
    final record = session.chunks[chunk.id];
    final state = record?.assetState ?? AssetState.learning;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(chunk.text, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(chunk.meaningCN, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              state.label,
              style: TextStyle(
                color: assetColor(state),
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 4),
            if (state == AssetState.learning)
              OutlinedButton(
                key: Key('reader_learn_${chunk.id}'),
                onPressed: () => session.learnChunk(chunk),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kPrimary,
                  side: const BorderSide(color: kPrimary),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                ),
                // 字号写在子 Text 上：styleFrom(textStyle:) 会整体替换主题 TextStyle，
                // 解析出的 fontFamily 变 null，CanvasKit 缺中文字形就去 fonts.gstatic.com
                // 拉 Noto 兜底（国内不可达，且违反外链零命中）。
                child: const Text('加入复习', style: TextStyle(fontSize: 11)),
              )
            else
              Text(
                record != null && record.dueDate > 0
                    ? '${DateTime.fromMillisecondsSinceEpoch(record.dueDate).month}/'
                        '${DateTime.fromMillisecondsSinceEpoch(record.dueDate).day} 到期'
                    : '已排期',
                style: const TextStyle(color: Colors.white24, fontSize: 10),
              ),
          ],
        ),
      ],
    );
  }

}

Article? _findArticle(ContentBundle content, String id) {
  for (final a in content.articles) {
    if (a.id == id) return a;
  }
  return null;
}

Widget _levelBadge(String level) {
  final color = switch (level) {
    'A1' || 'A2' => kUnlocked,
    'B1' || 'B2' => const Color(0xFF6FA8FF),
    _ => const Color(0xFFB98CFF),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(level, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
  );
}

const double kBodyFontSize = 17;
const Color kBodyText = Color(0xD9FFFFFF);

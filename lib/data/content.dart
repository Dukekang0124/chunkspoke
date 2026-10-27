import 'dart:convert';

import 'package:flutter/services.dart';

/// 网页版内容资产：由 `tool/build_content.py` 从 App 的 `assets/content_pack.json`
/// 与 `assets/listening_articles.json` 压缩生成，生成时已做数量与引用校验。
class Chunk {
  final String id;
  final String text;
  final String meaningCN;
  final String semantic;
  final String funcCat;
  final String type;
  final String tier;
  final String level;
  final int freqRank;
  final List<String> sources;
  final String example;
  final String exampleCN;

  const Chunk({
    required this.id,
    required this.text,
    required this.meaningCN,
    required this.semantic,
    required this.funcCat,
    required this.type,
    required this.tier,
    required this.level,
    required this.freqRank,
    required this.sources,
    required this.example,
    required this.exampleCN,
  });

  static Chunk fromJson(Map<String, Object?> m) => Chunk(
        id: m['id'] as String,
        text: m['text'] as String,
        meaningCN: (m['meaningCN'] as String?) ?? '',
        semantic: (m['semantic'] as String?) ?? '',
        funcCat: (m['funcCat'] as String?) ?? '',
        type: (m['type'] as String?) ?? '',
        tier: m['tier'] as String,
        level: (m['level'] as String?) ?? '',
        freqRank: (m['freqRank'] as num?)?.toInt() ?? 0,
        sources: [for (final s in (m['sources'] as List? ?? const [])) s.toString()],
        example: (m['example'] as String?) ?? '',
        exampleCN: (m['exampleCN'] as String?) ?? '',
      );
}

class ChunkRef {
  final String id;
  final String text;
  final String meaningCN;
  final bool candidate;

  const ChunkRef({
    required this.id,
    required this.text,
    required this.meaningCN,
    this.candidate = false,
  });

  static ChunkRef fromJson(Map<String, Object?> m) => ChunkRef(
        id: m['id'] as String,
        text: (m['text'] as String?) ?? '',
        meaningCN: (m['meaningCN'] as String?) ?? '',
        candidate: m['candidate'] == true,
      );
}

class ArticleSentence {
  final String id;
  final String text;
  final String meaningCN;
  final List<ChunkRef> chunks;

  const ArticleSentence({
    required this.id,
    required this.text,
    required this.meaningCN,
    required this.chunks,
  });

  bool get hasCoreChunks => chunks.any((c) => !c.candidate);

  static ArticleSentence fromJson(Map<String, Object?> m) => ArticleSentence(
        id: m['id'] as String,
        text: (m['text'] as String?) ?? '',
        meaningCN: (m['meaningCN'] as String?) ?? '',
        chunks: [
          for (final c in (m['chunks'] as List? ?? const []))
            ChunkRef.fromJson((c as Map).map((k, v) => MapEntry(k.toString(), v))),
        ],
      );
}

class Article {
  final String id;
  final String title;
  final String level;
  final String sceneLabel;
  final String summaryCN;
  final double baseRate;
  final List<ArticleSentence> sentences;

  const Article({
    required this.id,
    required this.title,
    required this.level,
    required this.sceneLabel,
    required this.summaryCN,
    required this.baseRate,
    required this.sentences,
  });

  int get highlightedSentenceCount => sentences.where((s) => s.hasCoreChunks).length;

  static Article fromJson(Map<String, Object?> m) => Article(
        id: m['id'] as String,
        title: (m['title'] as String?) ?? '',
        level: (m['level'] as String?) ?? '',
        sceneLabel: (m['sceneLabel'] as String?) ?? '',
        summaryCN: (m['summaryCN'] as String?) ?? '',
        baseRate: (m['baseRate'] as num?)?.toDouble() ?? 1.0,
        sentences: [
          for (final s in (m['sentences'] as List? ?? const []))
            ArticleSentence.fromJson((s as Map).map((k, v) => MapEntry(k.toString(), v))),
        ],
      );
}

class LevelMeta {
  final String id;
  final String theme;

  const LevelMeta({required this.id, required this.theme});
}

class ContentBundle {
  static const String chunkAsset = 'assets/content/chunks.json';
  static const String articleAsset = 'assets/content/articles.json';

  /// App 内容包版本（`content_pack.json` 的 version），导出时写进 `packs`。
  final String packVersion;
  final String articleVersion;
  final List<Chunk> chunks;
  final Map<String, Chunk> byId;
  final List<LevelMeta> levels;
  final Map<String, int> tierCounts;
  final List<String> funcCats;
  final List<Article> articles;

  const ContentBundle({
    required this.packVersion,
    required this.articleVersion,
    required this.chunks,
    required this.byId,
    required this.levels,
    required this.tierCounts,
    required this.funcCats,
    required this.articles,
  });

  static ContentBundle? _cached;

  /// 路由进入内容页时调用；只解析一次，失败即抛（不静默降级成空库）。
  static Future<ContentBundle> load() async {
    final cached = _cached;
    if (cached != null) return cached;
    final chunkRaw = await rootBundle.loadString(chunkAsset);
    final articleRaw = await rootBundle.loadString(articleAsset);
    final bundle = ContentBundle.fromJson(
      jsonDecode(chunkRaw) as Map<String, Object?>,
      jsonDecode(articleRaw) as Map<String, Object?>,
    );
    _cached = bundle;
    return bundle;
  }

  static ContentBundle fromJson(Map<String, Object?> chunkDoc, Map<String, Object?> articleDoc) {
    final chunks = [
      for (final c in (chunkDoc['chunks'] as List))
        Chunk.fromJson((c as Map).map((k, v) => MapEntry(k.toString(), v))),
    ];
    if (chunks.length != (chunkDoc['count'] as num).toInt()) {
      throw StateError('词块数量与清单不符：${chunks.length} != ${chunkDoc['count']}');
    }
    final byId = {for (final c in chunks) c.id: c};
    if (byId.length != chunks.length) {
      throw StateError('词块 id 有重复，内容包不可用');
    }
    final tiers = (chunkDoc['tiers'] as Map).map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    if (chunks.length != tiers.values.fold<int>(0, (a, b) => a + b)) {
      throw StateError('层级计数与总数不符');
    }
    final articles = [
      for (final a in (articleDoc['articles'] as List))
        Article.fromJson((a as Map).map((k, v) => MapEntry(k.toString(), v))),
    ];
    if (articles.length != (articleDoc['count'] as num).toInt()) {
      throw StateError('文章数量与清单不符：${articles.length} != ${articleDoc['count']}');
    }
    return ContentBundle(
      // 词块包 version 是字符串（1.2.0），收听文章的 version 是整数（2），统一转字符串
      packVersion: chunkDoc['version']?.toString() ?? '',
      articleVersion: articleDoc['version']?.toString() ?? '',
      chunks: chunks,
      byId: byId,
      levels: [
        for (final l in (chunkDoc['levels'] as List))
          LevelMeta(
            id: ((l as Map)['id'] as String?) ?? '',
            theme: (l['theme'] as String?) ?? '',
          ),
      ],
      tierCounts: tiers,
      funcCats: [for (final f in (chunkDoc['funcCats'] as List? ?? const [])) f.toString()],
      articles: articles,
    );
  }
}

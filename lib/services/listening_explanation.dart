import '../models/content_pack.dart';
import '../models/listening_article.dart';
import 'chunk_asset.dart';

/// 讲解版单块的来源：新块候选（蓝）或在学/未掌握块（琥珀）。
/// 已掌握（金）永远不生成讲解；未知 id 缺库内释义时优雅跳过。
enum ListeningExplanationKind { candidate, learning }

/// 讲解段里被讲到的单块（保留原文 id/文本，供高亮、首遇记忆与埋点）。
class ListeningExplainedChunk {
  final ListeningChunk chunk;
  final ListeningExplanationKind kind;

  /// 首遇记忆键：既有块按块 id，候选块按文本键（全局小写去空白）。
  final String key;

  /// 实际朗读的短句（候选=块面×2+文中 gloss；在学=块面×1+库内释义）。
  final String text;

  const ListeningExplainedChunk({
    required this.chunk,
    required this.kind,
    required this.key,
    required this.text,
  });
}

/// 一句的讲解段：句级插入，同句多块合并成一段。
class ListeningExplanationSegment {
  final int sentenceIndex;
  final String text;
  final List<ListeningExplainedChunk> chunks;

  const ListeningExplanationSegment({
    required this.sentenceIndex,
    required this.text,
    required this.chunks,
  });

  List<String> get chunkIds => [for (final c in chunks) c.chunk.id];

  List<String> get memoryKeys => [for (final c in chunks) c.key];
}

/// 讲解文本生成（纯函数，无 I/O）。
///
/// 红线：只决定「读什么」，不写块状态、不产资产、不记学习事件。
class ListeningExplanationBuilder {
  /// 在学块库内释义上限（超出截断，避免讲解段被长释义拖过 8 秒）。
  static const int kMaxDefinitionChars = 15;

  static List<ListeningExplanationSegment> build({
    required ListeningArticle article,
    required Map<String, ChunkAssetState> states,
    required ContentPack content,
    Set<String> alreadyExplained = const {},
  }) {
    final byId = <String, Chunk>{
      for (final level in content.levels)
        for (final c in level.chunks) c.id: c,
    };
    final seen = <String>{...alreadyExplained};
    final segments = <ListeningExplanationSegment>[];

    for (var i = 0; i < article.sentences.length; i++) {
      final picks = <ListeningExplainedChunk>[];
      for (final chunk in article.sentences[i].chunks) {
        final kind = _kindFor(chunk, states);
        if (kind == null) continue;
        final key = _keyFor(chunk);
        if (seen.contains(key)) continue;
        final text = _textFor(chunk, kind, byId);
        if (text == null) continue;
        seen.add(key);
        picks.add(ListeningExplainedChunk(
          chunk: chunk,
          kind: kind,
          key: key,
          text: text,
        ));
      }
      if (picks.isEmpty) continue;
      segments.add(ListeningExplanationSegment(
        sentenceIndex: i,
        text: [for (final p in picks) p.text].join(' '),
        chunks: picks,
      ));
    }
    return segments;
  }

  /// null = 金色已掌握，不讲解。
  static ListeningExplanationKind? _kindFor(
    ListeningChunk chunk,
    Map<String, ChunkAssetState> states,
  ) {
    if (chunk.candidate) return ListeningExplanationKind.candidate;
    if (states[chunk.id] == ChunkAssetState.mastered) return null;
    return ListeningExplanationKind.learning;
  }

  static String _keyFor(ListeningChunk chunk) => chunk.candidate
      ? 't:${chunk.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}'
      : 'i:${chunk.id}';

  /// 缺释义/找不到库内词块 → null（优雅跳过，不朗读半截）。
  static String? _textFor(
    ListeningChunk chunk,
    ListeningExplanationKind kind,
    Map<String, Chunk> byId,
  ) {
    if (kind == ListeningExplanationKind.candidate) {
      final gloss = chunk.meaningCN.trim();
      if (gloss.isEmpty) return null;
      return '${chunk.text}. ${chunk.text}. $gloss';
    }
    final library = byId[chunk.id];
    final definition = (library?.meaningCN ?? '').trim();
    if (definition.isEmpty) return null;
    return '${chunk.text}. ${clipDefinition(definition)}';
  }

  /// 按 Unicode 码点截断，避免把中文截成半个代理对。
  static String clipDefinition(String definition, [int max = kMaxDefinitionChars]) {
    final trimmed = definition.trim();
    final runes = trimmed.runes.toList();
    if (runes.length <= max) return trimmed;
    return String.fromCharCodes(runes.take(max));
  }
}

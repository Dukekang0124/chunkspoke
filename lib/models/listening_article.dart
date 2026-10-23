import 'content_pack.dart';

/// 收听文章（磨耳朵 · 浸泡层）内容模型。
///
/// 红线：
/// - 浸泡层是词块资产生命周期的「浸」环：被动收听不产出资产、不计学习指标，
///   只计浸泡时长；本文件的任何结构都不得写入 [ChunkProgressStore] 的会话轴。
/// - 词块标注只引用既有词块（content 包）或标记为「新块候选」（candidate），
///   候选块加入学习后仍走既有状态机，不建第二套进度。
/// - 禁 Day N 编号库：文章只有标题/场景，没有天数序号。
class ListeningPack {
  final int version;
  final String generatedAt;
  final List<ListeningArticle> articles;

  ListeningPack({
    required this.version,
    required this.generatedAt,
    required this.articles,
  });

  factory ListeningPack.fromJson(Map<String, dynamic> json) => ListeningPack(
        version: (json['version'] as num?)?.toInt() ?? 1,
        generatedAt: (json['generatedAt'] as String?) ?? '',
        articles: (json['articles'] as List? ?? [])
            .map((e) => ListeningArticle.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, ListeningArticle> get byId =>
      {for (final a in articles) a.id: a};

  /// 候选块账本：全库候选块按 id 去重，保留首次出现的场景供浮层/词块库展示。
  Map<String, ListeningCandidate> get candidates {
    final out = <String, ListeningCandidate>{};
    for (final a in articles) {
      for (final s in a.sentences) {
        for (final c in s.chunks) {
          if (!c.candidate || out.containsKey(c.id)) continue;
          out[c.id] = ListeningCandidate(
            id: c.id,
            text: c.text,
            meaningCN: c.meaningCN,
            scene: a.scene,
            sceneLabel: a.sceneLabel,
            articleId: a.id,
          );
        }
      }
    }
    return out;
  }

  /// 供六步管线/复习使用的候选块对象（与 ContentPack 的 Chunk 同构）。
  /// 只在收词后取用；未收词不进入任何学习队列。
  Map<String, Chunk> get candidateChunks => {
        for (final c in candidates.values)
          c.id: Chunk.fromJson({
            'id': c.id,
            'text': c.text,
            'type': 'content',
            'meaningCN': c.meaningCN,
          }),
      };
}

class ListeningArticle {
  final String id;
  final String title;
  final String scene;
  final String sceneLabel;
  final String summaryCN;
  final String updatedAt;
  final String audioUrl;
  final int collectLimit;
  final List<ListeningSentence> sentences;

  ListeningArticle({
    required this.id,
    required this.title,
    required this.scene,
    required this.sceneLabel,
    required this.summaryCN,
    required this.updatedAt,
    required this.audioUrl,
    required this.collectLimit,
    required this.sentences,
  });

  factory ListeningArticle.fromJson(Map<String, dynamic> json) =>
      ListeningArticle(
        id: json['id'] as String,
        title: (json['title'] as String?) ?? '',
        scene: (json['scene'] as String?) ?? '',
        sceneLabel: (json['sceneLabel'] as String?) ?? '',
        summaryCN: (json['summaryCN'] as String?) ?? '',
        updatedAt: (json['updatedAt'] as String?) ?? '',
        audioUrl: (json['audioUrl'] as String?) ?? '',
        collectLimit: (json['collectLimit'] as num?)?.toInt() ?? 8,
        sentences: (json['sentences'] as List? ?? [])
            .map((e) => ListeningSentence.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// 去重后的块标注，按首次出现排序（浮层/收词上限都以此为准）。
  List<ListeningChunk> get chunks {
    final seen = <String>{};
    return [
      for (final s in sentences)
        for (final c in s.chunks)
          if (seen.add(c.id)) c,
    ];
  }

  int get totalSeconds => sentences.fold<int>(
      0, (s, e) => s + ((e.endMs ?? 0) - (e.startMs ?? 0)).clamp(0, 1 << 30));

  bool get hasTimeline => sentences.isNotEmpty && sentences.every((s) => s.hasTimeline);

  DateTime? get updatedDate => DateTime.tryParse(updatedAt);
}

class ListeningSentence {
  final String id;
  final String text;
  final String meaningCN;
  final List<ListeningChunk> chunks;

  /// 预生成音频的句级时间轴；audioUrl 为空（TTS 现合成）时为空，
  /// 由播放链在合成后按真实音频时长回填。
  final int? startMs;
  final int? endMs;

  ListeningSentence({
    required this.id,
    required this.text,
    required this.meaningCN,
    required this.chunks,
    this.startMs,
    this.endMs,
  });

  factory ListeningSentence.fromJson(Map<String, dynamic> json) =>
      ListeningSentence(
        id: json['id'] as String,
        text: (json['text'] as String?) ?? '',
        meaningCN: (json['meaningCN'] as String?) ?? '',
        chunks: (json['chunks'] as List? ?? [])
            .map((e) => ListeningChunk.fromJson(e as Map<String, dynamic>))
            .toList(),
        startMs: (json['startMs'] as num?)?.toInt(),
        endMs: (json['endMs'] as num?)?.toInt(),
      );

  bool get hasTimeline => startMs != null && endMs != null && endMs! > startMs!;
}

class ListeningChunk {
  final String id;
  final String text;
  final String meaningCN;
  final bool candidate;
  final String type;

  ListeningChunk({
    required this.id,
    required this.text,
    required this.meaningCN,
    this.candidate = false,
    this.type = 'content',
  });

  factory ListeningChunk.fromJson(Map<String, dynamic> json) => ListeningChunk(
        id: json['id'] as String,
        text: (json['text'] as String?) ?? '',
        meaningCN: (json['meaningCN'] as String?) ?? '',
        candidate: json['candidate'] == true,
        type: (json['type'] as String?) ?? 'content',
      );
}

class ListeningCandidate {
  final String id;
  final String text;
  final String meaningCN;
  final String scene;
  final String sceneLabel;
  final String articleId;

  const ListeningCandidate({
    required this.id,
    required this.text,
    required this.meaningCN,
    required this.scene,
    required this.sceneLabel,
    required this.articleId,
  });
}

/// 内容校验：发布前必须为 0 错。内容错误宁可加载即报错，也不静默降级。
List<String> validateListeningPack(ListeningPack pack, ContentPack content) {
  final errors = <String>[];
  final contentIds = {
    for (final lv in content.levels)
      for (final c in lv.chunks) c.id,
  };
  final articleIds = <String>{};
  final sentenceIds = <String>{};

  if (pack.articles.isEmpty) errors.add('收听文章为空');

  for (final a in pack.articles) {
    if (!articleIds.add(a.id)) errors.add('文章 id 重复：${a.id}');
    if (a.title.trim().isEmpty) errors.add('${a.id} 缺标题');
    if (a.scene.trim().isEmpty) errors.add('${a.id} 缺场景');
    if (a.collectLimit < 1 || a.collectLimit > 8) {
      errors.add('${a.id} collectLimit 越界：${a.collectLimit}（1..8）');
    }
    if (a.sentences.isEmpty) errors.add('${a.id} 无句子');
    if (a.audioUrl.isNotEmpty && !a.hasTimeline) {
      errors.add('${a.id} 有音频 URL 但句级时间轴不全');
    }

    final seen = <String>{};
    for (final s in a.sentences) {
      if (!sentenceIds.add(s.id)) errors.add('句 id 重复：${s.id}');
      if (s.text.trim().isEmpty) errors.add('${s.id} 文本为空');
      if (s.startMs != null || s.endMs != null) {
        if (!s.hasTimeline) errors.add('${s.id} 时间轴不完整或倒置');
      }
      final idsInSentence = <String>{};
      for (final c in s.chunks) {
        if (!idsInSentence.add(c.id)) errors.add('${s.id} 块重复：${c.id}');
        if (seen.add(c.id) && seen.length > a.collectLimit) {
          errors.add('${a.id} 标注块超过上限 ${a.collectLimit}：${c.id}');
        }
        if (c.text.trim().isEmpty) errors.add('${s.id}/${c.id} 块文本为空');
        if (!s.text.toLowerCase().contains(c.text.toLowerCase())) {
          errors.add('${s.id}/${c.id} 块文本不在句中：「${c.text}」');
        }
        if (c.candidate) {
          if (!c.id.startsWith('lx_')) {
            errors.add('${s.id}/${c.id} 候选块 id 须以 lx_ 开头');
          }
          if (contentIds.contains(c.id)) {
            errors.add('${s.id}/${c.id} 候选块 id 与既有词块冲突');
          }
        } else if (!contentIds.contains(c.id)) {
          errors.add('${s.id}/${c.id} 引用未知词块');
        }
      }
    }

    // 时间轴须单调且不重叠
    var lastEnd = -1;
    for (final s in a.sentences) {
      if (!s.hasTimeline) continue;
      if (s.startMs! < lastEnd) errors.add('${s.id} 时间轴与上一句重叠');
      lastEnd = s.endMs!;
    }
  }
  return errors;
}

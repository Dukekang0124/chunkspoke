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

/// CEFR 五档自选级别。
///
/// 定位（指令 S §〇.3）：级别**只是筛选器与默认语速**，没有分级测试、没有门槛、
/// 没有解锁语义 —— 用户自选，随时可换档。
/// 标尺三轴：总词数 / 句均词数 / 标注块数；`baseRate` 走播放速率（保调变速），
/// 不进音频缓存键，因此换级不重合成。
enum ListeningLevel {
  a1('A1', 'A1 入门', 0.75, 100, 180, 0, 6.0, 1, 6),
  a2('A2', 'A2 基础', 0.75, 181, 260, 6.1, 7.4, 6, 8),
  b1('B1', 'B1 进阶', 1.00, 261, 360, 7.5, 9.4, 7, 8),
  b2('B2', 'B2 流利', 1.00, 361, 430, 9.5, 11.9, 8, 8),
  c1('C1', 'C1 自主', 1.25, 431, 520, 12.0, double.infinity, 8, 8);

  const ListeningLevel(
    this.key,
    this.label,
    this.baseRate,
    this.minWords,
    this.maxWords,
    this.minAvgWords,
    this.maxAvgWords,
    this.minChunks,
    this.maxChunks,
  );

  /// 内容文件里写的字符串（也是筛选 chips 的显示简称）。
  final String key;

  /// 界面徽标文案。
  final String label;

  /// 该级别的默认播放速率；必须是播放速率梯上的既有档位，避免新增档位。
  final double baseRate;

  final int minWords;
  final int maxWords;
  final double minAvgWords;
  final double maxAvgWords;
  final int minChunks;
  final int maxChunks;

  static ListeningLevel? parse(String? raw) {
    if (raw == null) return null;
    final key = raw.trim().toUpperCase();
    for (final l in values) {
      if (l.key == key) return l;
    }
    return null;
  }
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

  /// 内容文件里 `level` 的原始值（缺失或非法时校验器要报错，故与解析结果并存）。
  final String levelRaw;
  final ListeningLevel level;

  /// 内容文件里 `baseRate` 的原始值；null 表示未声明。
  final double? baseRate;
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
    this.levelRaw = '',
    this.level = ListeningLevel.b1,
    this.baseRate,
    required this.sentences,
  });

  factory ListeningArticle.fromJson(Map<String, dynamic> json) {
    final raw = (json['level'] as String?)?.trim() ?? '';
    return ListeningArticle(
      id: json['id'] as String,
      title: (json['title'] as String?) ?? '',
      scene: (json['scene'] as String?) ?? '',
      sceneLabel: (json['sceneLabel'] as String?) ?? '',
      summaryCN: (json['summaryCN'] as String?) ?? '',
      updatedAt: (json['updatedAt'] as String?) ?? '',
      audioUrl: (json['audioUrl'] as String?) ?? '',
      collectLimit: (json['collectLimit'] as num?)?.toInt() ?? 8,
      levelRaw: raw,
      level: ListeningLevel.parse(raw) ?? ListeningLevel.b1,
      baseRate: (json['baseRate'] as num?)?.toDouble(),
      sentences: (json['sentences'] as List? ?? [])
          .map((e) => ListeningSentence.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

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

  /// 全文词数（按空白切分，只数含字母或数字的 token）。分级标尺的第一轴。
  int get wordCount => sentences.fold<int>(0, (sum, s) => sum + s.wordCount);

  /// 句均词数。分级标尺的第二轴（句子密度的直接体现）。
  double get avgWordsPerSentence =>
      sentences.isEmpty ? 0 : wordCount / sentences.length;

  /// 去重后的标注块数。分级标尺的第三轴。
  int get chunkCount => chunks.length;

  /// 复用率：标注块里引用既有词块（非新块候选）的占比。A1 档要求 ≥0.70。
  double get knownChunkRatio {
    final all = chunks;
    if (all.isEmpty) return 0;
    return all.where((c) => !c.candidate).length / all.length;
  }

  /// 按本级默认语速折算的实际收听秒数（合成语速按 150 wpm 估算）。
  int get estimatedSecondsAtBaseRate {
    final rate = baseRate ?? level.baseRate;
    final atNormal = wordCount / 150.0 * 60.0;
    return rate <= 0 ? atNormal.round() : (atNormal / rate).round();
  }

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

  /// 句词数：按空白切分后只数含字母或数字的 token（引号、标点不单独成词）。
  int get wordCount => _wordCount(text);
}

int _wordCount(String text) {
  if (text.trim().isEmpty) return 0;
  return text
      .split(RegExp(r'\s+'))
      .where((t) => RegExp(r'[A-Za-z0-9]').hasMatch(t))
      .length;
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

    // —— 分级断言（指令 S §一.1）：级别必须声明、语速必须走本级默认档、
    //    三轴实测值必须落在本级标尺内；A1 另加复用率门槛。
    if (a.levelRaw.isEmpty) {
      errors.add('${a.id} 缺 level 字段');
    } else if (ListeningLevel.parse(a.levelRaw) == null) {
      errors.add('${a.id} level 非法：${a.levelRaw}（须为 A1/A2/B1/B2/C1）');
    }
    final rubric = a.level;
    if (a.baseRate == null) {
      errors.add('${a.id} 缺 baseRate 字段');
    } else if ((a.baseRate! - rubric.baseRate).abs() > 0.001) {
      errors.add(
          '${a.id} baseRate ${a.baseRate} 与本级默认 ${rubric.baseRate}（${rubric.key}）不符');
    }
    if (a.wordCount < rubric.minWords || a.wordCount > rubric.maxWords) {
      errors.add('${a.id} 词数 ${a.wordCount} 不在 ${rubric.key} 档 '
          '${rubric.minWords}..${rubric.maxWords}');
    }
    if (a.avgWordsPerSentence < rubric.minAvgWords ||
        a.avgWordsPerSentence > rubric.maxAvgWords) {
      errors.add('${a.id} 句均词数 ${a.avgWordsPerSentence.toStringAsFixed(1)} 不在 '
          '${rubric.key} 档 ${rubric.minAvgWords}..${rubric.maxAvgWords}');
    }
    if (a.chunkCount < rubric.minChunks || a.chunkCount > rubric.maxChunks) {
      errors.add('${a.id} 标注块数 ${a.chunkCount} 不在 ${rubric.key} 档 '
          '${rubric.minChunks}..${rubric.maxChunks}');
    }
    if (rubric == ListeningLevel.a1 && a.knownChunkRatio < 0.70) {
      errors.add('${a.id} A1 档要求复用既有词块 ≥70%，实测 '
          '${(a.knownChunkRatio * 100).round()}%');
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

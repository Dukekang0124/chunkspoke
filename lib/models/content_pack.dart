/// 词块拼装体系数据模型（v1.2.0）。
///
/// 核心概念：
/// - Chunk（词块）：可复用的多词预制件（2~5 词），如 "I'm fine" / "Good morning"。
/// - Sentence（目标句）：由若干词块按序拼装而成，标注 [chunkIds]，供「块拼句」环节生成卡片。
/// - Level（场景）：包含词块清单 + 目标句清单（句句标注由哪些块拼成）。
///
/// 兼容说明：旧场景的 Chunk 仍带 `sentence`（单句训练用），新场景可省略 `sentence`，
/// 解析时回退为「以词块文本自身作为句子」，避免改写存量内容。
class ContentPack {
  final String version;
  final List<Level> levels;
  ContentPack({required this.version, required this.levels});

  factory ContentPack.fromJson(Map<String, dynamic> json) {
    return ContentPack(
      version: json['version'] as String,
      levels: (json['levels'] as List)
          .map((e) => Level.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Level {
  final String id;
  final String theme;
  final String sceneImage;
  final List<Chunk> chunks;
  /// 本场景目标句清单（句句标注由哪些词块拼成），供「块拼句 / 句子闯关」使用。
  final List<TargetSentence> sentences;
  Level({
    required this.id,
    required this.theme,
    required this.sceneImage,
    required this.chunks,
    this.sentences = const [],
  });

  factory Level.fromJson(Map<String, dynamic> json) {
    return Level(
      id: json['id'] as String,
      theme: json['theme'] as String,
      sceneImage: json['sceneImage'] as String,
      chunks: (json['chunks'] as List)
          .map((e) => Chunk.fromJson(e as Map<String, dynamic>))
          .toList(),
      sentences: (json['sentences'] as List? ?? [])
          .map((e) => TargetSentence.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Chunk {
  final String id;
  final String text; // 词块短语，如 "Good morning"
  final String type; // content | function | connector | timeplace
  final String meaningCN;
  final ChunkSentence sentence; // 旧场景单句训练用；新场景解析时回退为词块文本本身
  Chunk({
    required this.id,
    required this.text,
    required this.type,
    required this.meaningCN,
    required this.sentence,
  });

  factory Chunk.fromJson(Map<String, dynamic> json) {
    final text = json['text'] as String;
    final type = (json['type'] as String?) ?? 'content';
    final meaningCN = (json['meaningCN'] as String?) ?? '';
    final sentJson = json['sentence'] as Map<String, dynamic>?;
    final sentence = sentJson != null
        ? ChunkSentence.fromJson(sentJson)
        : ChunkSentence(
            text: text,
            slots: [Slot(text: text, type: type)],
            coreWords: text
                .toLowerCase()
                .split(RegExp(r"[^a-z0-9']+"))
                .where((w) => w.isNotEmpty)
                .toList(),
            swapSlotIndex: -1,
            swapOptions: const [],
          );
    return Chunk(
      id: json['id'] as String,
      text: text,
      type: type,
      meaningCN: meaningCN,
      sentence: sentence,
    );
  }
}

/// 目标句：由若干词块按序拼装而成。
class TargetSentence {
  final String id;
  final String text; // 完整句子，如 "Good morning everyone"
  final String meaningCN; // 中文提示
  final List<String> chunkIds; // 组成该句的词块 id（顺序）
  TargetSentence({
    required this.id,
    required this.text,
    required this.meaningCN,
    required this.chunkIds,
  });

  factory TargetSentence.fromJson(Map<String, dynamic> json) => TargetSentence(
        id: json['id'] as String,
        text: json['text'] as String,
        meaningCN: (json['meaningCN'] as String?) ?? '',
        chunkIds: (json['chunkIds'] as List)
            .map((e) => e as String)
            .toList(),
      );

  /// 按 chunkIds 顺序展开为词块文本（缺失的 id 跳过），供「块拼句」生成槽位与目标。
  List<String> orderedChunkTexts(Map<String, Chunk> byId) =>
      chunkIds.map((id) => byId[id]).whereType<Chunk>().map((c) => c.text).toList();
}

/// 旧单句训练遗留结构（保留以兼容存量场景内容）。
class ChunkSentence {
  final String text;
  final List<Slot> slots;
  final List<String> coreWords;
  final int swapSlotIndex;
  final List<String> swapOptions;
  ChunkSentence({
    required this.text,
    required this.slots,
    required this.coreWords,
    required this.swapSlotIndex,
    required this.swapOptions,
  });

  factory ChunkSentence.fromJson(Map<String, dynamic> json) {
    return ChunkSentence(
      text: json['text'] as String,
      slots: (json['slots'] as List)
          .map((e) => Slot.fromJson(e as Map<String, dynamic>))
          .toList(),
      coreWords: (json['coreWords'] as List).map((e) => e as String).toList(),
      swapSlotIndex: json['swapSlotIndex'] as int,
      swapOptions: (json['swapOptions'] as List).map((e) => e as String).toList(),
    );
  }
}

class Slot {
  final String text;
  final String type;
  Slot({required this.text, required this.type});
  factory Slot.fromJson(Map<String, dynamic> json) {
    return Slot(
      text: json['text'] as String,
      type: json['type'] as String,
    );
  }
}

/// 块拼句正确性判定：每个槽位都已填入，且与目标词块序列完全一致（顺序敏感）。
/// 供 BuildStep 完成判定与单测复用（拼句环节状态机核心校验）。
bool assemblyCorrect(List<String?> filled, List<String> expected) {
  if (filled.length != expected.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (filled[i] != expected[i]) return false;
  }
  return true;
}

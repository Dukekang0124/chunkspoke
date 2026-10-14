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
  Level({
    required this.id,
    required this.theme,
    required this.sceneImage,
    required this.chunks,
  });

  factory Level.fromJson(Map<String, dynamic> json) {
    return Level(
      id: json['id'] as String,
      theme: json['theme'] as String,
      sceneImage: json['sceneImage'] as String,
      chunks: (json['chunks'] as List)
          .map((e) => Chunk.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class Chunk {
  final String id;
  final String text;
  final String type; // content | function | connector | timeplace
  final String meaningCN;
  final ChunkSentence sentence;
  Chunk({
    required this.id,
    required this.text,
    required this.type,
    required this.meaningCN,
    required this.sentence,
  });

  factory Chunk.fromJson(Map<String, dynamic> json) {
    return Chunk(
      id: json['id'] as String,
      text: json['text'] as String,
      type: json['type'] as String,
      meaningCN: json['meaningCN'] as String,
      sentence: ChunkSentence.fromJson(json['sentence'] as Map<String, dynamic>),
    );
  }
}

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

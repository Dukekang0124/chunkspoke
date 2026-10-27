import '../data/vocab.dart';

/// 本机存储行（IndexedDB `chunks` store），字段与 App `chunks` 表逐列对应。
///
/// `l4_self_eval` / `l2_one_try` / `last_score` 是本机交互痕迹，
/// **不进交换协议**；导入端只能按派生规则把它们升到「通过」语义，永不覆盖为更低值。
class ChunkRecord {
  final String id;
  final String tier;
  final AssetState assetState;

  /// 失败前原位的枚举下标；-1 = 无值（App 用 `-1` 表示）。
  final int assetReturnStateIndex;

  /// 失败前原位的复习档位；-1 = 无值。
  final int assetReturnStage;

  final int reviewStage;
  final int dueDate;
  final int lastReviewAt;
  final int correctStreak;
  final int updatedAt;

  final int l4SelfEval; // 0/1
  final int l2OneTry; // -1 未知 | 0 否 | 1 是
  final int lastScore; // 0..100

  /// 入站块 id 不在本机内容包内时置 true：不显示、不参与统计，导出时原样带回。
  final bool orphan;

  const ChunkRecord({
    required this.id,
    required this.tier,
    required this.assetState,
    this.assetReturnStateIndex = -1,
    this.assetReturnStage = -1,
    this.reviewStage = 0,
    this.dueDate = 0,
    this.lastReviewAt = 0,
    this.correctStreak = 0,
    this.updatedAt = 0,
    this.l4SelfEval = 0,
    this.l2OneTry = -1,
    this.lastScore = 0,
    this.orphan = false,
  });

  AssetState? get assetReturnState =>
      assetReturnStateIndex >= 0 && assetReturnStateIndex < AssetState.values.length
          ? AssetState.values[assetReturnStateIndex]
          : null;

  ChunkRecord copyWith({
    String? id,
    String? tier,
    AssetState? assetState,
    int? assetReturnStateIndex,
    int? assetReturnStage,
    int? reviewStage,
    int? dueDate,
    int? lastReviewAt,
    int? correctStreak,
    int? updatedAt,
    int? l4SelfEval,
    int? l2OneTry,
    int? lastScore,
    bool? orphan,
  }) {
    return ChunkRecord(
      id: id ?? this.id,
      tier: tier ?? this.tier,
      assetState: assetState ?? this.assetState,
      assetReturnStateIndex: assetReturnStateIndex ?? this.assetReturnStateIndex,
      assetReturnStage: assetReturnStage ?? this.assetReturnStage,
      reviewStage: reviewStage ?? this.reviewStage,
      dueDate: dueDate ?? this.dueDate,
      lastReviewAt: lastReviewAt ?? this.lastReviewAt,
      correctStreak: correctStreak ?? this.correctStreak,
      updatedAt: updatedAt ?? this.updatedAt,
      l4SelfEval: l4SelfEval ?? this.l4SelfEval,
      l2OneTry: l2OneTry ?? this.l2OneTry,
      lastScore: lastScore ?? this.lastScore,
      orphan: orphan ?? this.orphan,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'tier': tier,
        'assetState': assetState.wire,
        'assetReturnState': assetReturnStateIndex,
        'assetReturnStage': assetReturnStage,
        'reviewStage': reviewStage,
        'dueDate': dueDate,
        'lastReviewAt': lastReviewAt,
        'correctStreak': correctStreak,
        'updatedAt': updatedAt,
        'l4SelfEval': l4SelfEval,
        'l2OneTry': l2OneTry,
        'lastScore': lastScore,
        'orphan': orphan,
      };

  static ChunkRecord fromMap(Map<String, Object?> m) {
    final stateRaw = m['assetState'];
    final assetState = stateRaw is String ? AssetState.parse(stateRaw) : AssetState.learning;
    return ChunkRecord(
      id: (m['id'] as String?) ?? '',
      tier: (m['tier'] as String?) ?? '',
      assetState: assetState,
      assetReturnStateIndex: _int(m['assetReturnState'], -1),
      assetReturnStage: _int(m['assetReturnStage'], -1),
      reviewStage: _int(m['reviewStage'], 0),
      dueDate: _int(m['dueDate'], 0),
      lastReviewAt: _int(m['lastReviewAt'], 0),
      correctStreak: _int(m['correctStreak'], 0),
      updatedAt: _int(m['updatedAt'], 0),
      l4SelfEval: _int(m['l4SelfEval'], 0),
      l2OneTry: _int(m['l2OneTry'], -1),
      lastScore: _int(m['lastScore'], 0),
      orphan: m['orphan'] == true,
    );
  }

  static int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
}

class EventRecord {
  final String eventId;
  final int at;
  final String name;
  final Map<String, Object?> props;

  const EventRecord({
    required this.eventId,
    required this.at,
    required this.name,
    this.props = const {},
  });

  Map<String, Object?> toMap() => {
        'event_id': eventId,
        'at': at,
        'name': name,
        'props': Map<String, Object?>.from(props),
      };

  static EventRecord fromMap(Map<String, Object?> m) => EventRecord(
        eventId: (m['event_id'] as String?) ?? '',
        at: ChunkRecord._int(m['at'], 0),
        name: (m['name'] as String?) ?? '',
        props: m['props'] is Map
            ? (m['props'] as Map).map((k, v) => MapEntry(k.toString(), v))
            : const {},
      );
}

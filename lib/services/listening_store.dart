import 'dart:convert';

/// 浸泡层的独立账本：只记收听行为与收词漏斗，不写学习会话轴。
///
/// 口径（与指令 Q 钉死）：
/// - 浸泡时长：按「实际播放秒数」累加，暂停/切后台不计；
/// - 收词：候选块被「一键加入学习」时记一次，按块去重；
/// - 推动率：收词块中完成六步的比例（分子只认已收词的块）；
/// - 重逢：文章内点击已学块的次数，按篇计。
/// 本类不产出任何 [ChunkAssetState]，资产状态只走 ChunkProgressStore。
class ListeningStore {
  static const kSeconds = 'listen_seconds';
  static const kSecondsByDay = 'listen_seconds_by_day';
  static const kPositions = 'listen_positions';
  static const kCompleted = 'listen_completed';
  static const kCollected = 'listen_collected';
  static const kConverted = 'listen_converted';
  static const kSixStarted = 'listen_six_started';
  static const kCandidateWishes = 'listen_candidate_wishes';
  static const kReunions = 'listen_reunions';
  static const kMaxCollectEntries = 500;
  static const kMaxWishEntries = 500;
  static const kDayKeep = 30;

  ListeningStore({
    required String? Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required DateTime Function() clock,
  })  : _read = read,
        _write = write,
        _clock = clock;

  final String? Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final DateTime Function() _clock;

  int _int(String key) => int.tryParse(_read(key) ?? '') ?? 0;

  Map<String, dynamic> _jsonMap(String key) {
    final raw = _read(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {}; // 脏数据不能让磨耳朵打不开
    }
  }

  List<dynamic> _jsonList(String key) {
    final raw = _read(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return jsonDecode(raw) as List;
    } catch (_) {
      return const [];
    }
  }

  int get totalSeconds => _int(kSeconds);

  /// 近 30 天每日浸泡秒数（date 'yyyy-MM-dd' → seconds）。
  Map<String, int> get secondsByDay => {
        for (final e in _jsonMap(kSecondsByDay).entries)
          if (e.value is num) e.key: (e.value as num).toInt(),
      };

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 记录一段实际播放时长；负值/零值忽略。
  Future<void> addSeconds(int seconds, {DateTime? at}) async {
    if (seconds <= 0) return;
    final now = at ?? _clock();
    final days = secondsByDay;
    final key = _dayKey(now);
    days[key] = (days[key] ?? 0) + seconds;
    if (days.length > kDayKeep) {
      final keys = days.keys.toList()..sort();
      for (final k in keys.take(days.length - kDayKeep)) {
        days.remove(k);
      }
    }
    await _write(kSeconds, '${totalSeconds + seconds}');
    await _write(kSecondsByDay, jsonEncode(days));
  }

  /// 上次退出时的续播点。
  ListeningPosition? positionFor(String articleId) {
    final m = _jsonMap(kPositions)[articleId];
    if (m is! Map) return null;
    final ms = (m['ms'] as num?)?.toInt();
    final ts = (m['ts'] as num?)?.toInt();
    if (ms == null || ts == null) return null;
    return ListeningPosition(
      positionMs: ms.clamp(0, 1 << 30),
      sentenceIndex: (m['i'] as num?)?.toInt() ?? 0,
      updatedAt: ts,
    );
  }

  Future<void> savePosition(String articleId, int positionMs, int sentenceIndex,
      {DateTime? at}) async {
    final map = _jsonMap(kPositions);
    map[articleId] = {
      'ms': positionMs < 0 ? 0 : positionMs,
      'i': sentenceIndex < 0 ? 0 : sentenceIndex,
      'ts': (at ?? _clock()).millisecondsSinceEpoch,
    };
    await _write(kPositions, jsonEncode(map));
  }

  /// 上次听到的篇目（按续播点时间），供「继续听」。
  String? get lastHeardArticleId {
    var bestTs = -1;
    String? best;
    for (final e in _jsonMap(kPositions).entries) {
      final m = e.value;
      final ts = (m is Map ? (m['ts'] as num?)?.toInt() : null) ?? -1;
      if (ts > bestTs) {
        bestTs = ts;
        best = e.key;
      }
    }
    return best;
  }

  int? lastHeardAt(String articleId) {
    final m = _jsonMap(kPositions)[articleId];
    return m is Map ? (m['ts'] as num?)?.toInt() : null;
  }

  /// 篇目最近一次收听时间（续播点与完听取较晚者），供首页推荐分日。
  Map<String, int> get lastListenedAt {
    final out = <String, int>{};
    for (final e in _jsonMap(kPositions).entries) {
      final m = e.value;
      final ts = m is Map ? (m['ts'] as num?)?.toInt() : null;
      if (ts != null) out[e.key] = ts;
    }
    for (final e in _completedRaw.entries) {
      final cur = out[e.key];
      if (cur == null || e.value > cur) out[e.key] = e.value;
    }
    return out;
  }

  /// 本周（或指定起始日之后）的实际浸泡秒数，按日汇总口径。
  int secondsSince(DateTime start) {
    final from = _dayKey(DateTime(start.year, start.month, start.day));
    var sum = 0;
    for (final e in secondsByDay.entries) {
      if (e.key.compareTo(from) >= 0) sum += e.value;
    }
    return sum;
  }

  /// 完听：一篇自然播到尾时记一次；重听只更新时间，不重复计数。
  Map<String, int> get _completedRaw => {
        for (final e in _jsonMap(kCompleted).entries)
          if (e.value is num) e.key: (e.value as num).toInt(),
      };

  int get completedCount => _completedRaw.length;

  bool isCompleted(String articleId) => _completedRaw.containsKey(articleId);

  Future<void> markCompleted(String articleId, {DateTime? at}) async {
    final map = _completedRaw;
    map[articleId] = (at ?? _clock()).millisecondsSinceEpoch;
    await _write(kCompleted, jsonEncode(map));
  }

  int completedSince(int epochMs) =>
      _completedRaw.values.where((ts) => ts >= epochMs).length;

  List<CollectedChunk> get collected {
    return [
      for (final e in _jsonList(kCollected))
        if (e is Map)
          CollectedChunk(
            chunkId: '${e['id']}',
            articleId: '${e['a'] ?? ''}',
            at: (e['ts'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  Set<String> get collectedIds => {for (final c in collected) c.chunkId};

  bool isCollected(String chunkId) => collectedIds.contains(chunkId);

  /// 本篇已收词块数（按块去重；跨篇重复收词不占第二篇名额）。
  int collectedCountFor(String articleId) =>
      {for (final c in collected) if (c.articleId == articleId) c.chunkId}
          .length;

  /// 本篇是否已把该块收进学习（用于「已加入」态与 8 块上限判定）。
  bool isCollectedIn(String chunkId, String articleId) =>
      collected.any((c) => c.chunkId == chunkId && c.articleId == articleId);

  /// 收词：按块去重，重复点击不重复计数（观测量诚实）。
  Future<bool> markCollected(String chunkId, String articleId,
      {DateTime? at}) async {
    if (isCollected(chunkId)) return false;
    final list = collected
      ..add(CollectedChunk(
        chunkId: chunkId,
        articleId: articleId,
        at: (at ?? _clock()).millisecondsSinceEpoch,
      ));
    if (list.length > kMaxCollectEntries) {
      list.removeRange(0, list.length - kMaxCollectEntries);
    }
    await _write(kCollected,
        jsonEncode([for (final c in list) {'id': c.chunkId, 'a': c.articleId, 'ts': c.at}]));
    return true;
  }

  Set<String> get convertedIds =>
      {for (final e in _jsonList(kConverted)) '$e'};

  bool isConverted(String chunkId) => convertedIds.contains(chunkId);

  /// 六步完成后回填。只认已收词的块：未收词的完成属于常规学习，不进本漏斗。
  Future<bool> markConverted(String chunkId) async {
    if (!isCollected(chunkId) || isConverted(chunkId)) return false;
    final ids = convertedIds..add(chunkId);
    await _write(kConverted, jsonEncode(ids.toList()));
    return true;
  }

  Set<String> get sixStartedIds =>
      {for (final e in _jsonList(kSixStarted)) '$e'};

  bool isSixStarted(String chunkId) => sixStartedIds.contains(chunkId);

  /// 收词后首次进入六步：只记已收词的块，按块去重（重进断点不重复计数）。
  Future<bool> markSixStarted(String chunkId) async {
    if (!isCollected(chunkId) || isSixStarted(chunkId)) return false;
    final ids = sixStartedIds..add(chunkId);
    await _write(kSixStarted, jsonEncode(ids.toList()));
    return true;
  }

  List<CandidateWish> get candidateWishes => [
        for (final e in _jsonList(kCandidateWishes))
          if (e is Map)
            CandidateWish(
              articleId: '${e['a'] ?? ''}',
              text: '${e['t'] ?? ''}',
              at: (e['ts'] as num?)?.toInt() ?? 0,
            ),
      ];

  int wishCount(String articleId, String text) => candidateWishes
      .where((w) => w.articleId == articleId && w.text == text)
      .length;

  bool isWished(String articleId, String text) => wishCount(articleId, text) > 0;

  int get totalWishes => candidateWishes.length;

  /// 候选块意愿：只记「文章 id + 块文本」，不建词块、不写学习轴；
  /// 同篇同文本重复点击不重复计数（反哺内容排产的口径要干净）。
  Future<bool> markWish(String articleId, String text, {DateTime? at}) async {
    if (articleId.isEmpty || text.trim().isEmpty) return false;
    if (isWished(articleId, text)) return false;
    final list = candidateWishes
      ..add(CandidateWish(
        articleId: articleId,
        text: text,
        at: (at ?? _clock()).millisecondsSinceEpoch,
      ));
    if (list.length > kMaxWishEntries) {
      list.removeRange(0, list.length - kMaxWishEntries);
    }
    await _write(
        kCandidateWishes,
        jsonEncode([
          for (final w in list)
            {'a': w.articleId, 't': w.text, 'ts': w.at}
        ]));
    return true;
  }

  int totalReunions() {
    final m = _jsonMap(kReunions);
    return m.values.fold<int>(
        0, (s, v) => s + (v is num ? v.toInt() : 0));
  }

  int reunionsFor(String articleId) {
    final v = _jsonMap(kReunions)[articleId];
    return v is num ? v.toInt() : 0;
  }

  Future<void> markReunion(String articleId) async {
    final map = _jsonMap(kReunions);
    map[articleId] = (reunionsFor(articleId)) + 1;
    await _write(kReunions, jsonEncode(map));
  }

  ListeningStats get stats => ListeningStats(
        totalSeconds: totalSeconds,
        collected: collectedIds.length,
        sixStarted: sixStartedIds.intersection(collectedIds).length,
        converted: convertedIds.intersection(collectedIds).length,
        wishes: totalWishes,
        reunions: totalReunions(),
        articlesHeard: _jsonMap(kPositions).length,
      );
}

class CandidateWish {
  final String articleId;
  final String text;
  final int at;

  const CandidateWish({
    required this.articleId,
    required this.text,
    required this.at,
  });
}

class ListeningPosition {
  final int positionMs;
  final int sentenceIndex;
  final int updatedAt;

  const ListeningPosition({
    required this.positionMs,
    required this.sentenceIndex,
    required this.updatedAt,
  });
}

class CollectedChunk {
  final String chunkId;
  final String articleId;
  final int at;

  const CollectedChunk({
    required this.chunkId,
    required this.articleId,
    required this.at,
  });
}

class ListeningStats {
  final int totalSeconds;
  final int collected;
  final int sixStarted;
  final int converted;
  final int wishes;
  final int reunions;
  final int articlesHeard;

  const ListeningStats({
    this.totalSeconds = 0,
    this.collected = 0,
    this.sixStarted = 0,
    this.converted = 0,
    this.wishes = 0,
    this.reunions = 0,
    this.articlesHeard = 0,
  });

  /// 收词→完成六步的转化率；无收词时为 null（展示「—」，不伪造 0%）。
  double? get conversionRate => collected == 0 ? null : converted / collected;
}

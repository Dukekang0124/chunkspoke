import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/content_pack.dart';
import 'database.dart';

Future<ContentPack> loadContentPack() async {
  final str = await rootBundle.loadString('assets/content_pack.json');
  return ContentPack.fromJson(jsonDecode(str) as Map<String, dynamic>);
}

class Appeal {
  final String levelId;
  final String expected;
  final String audioPath;
  final int ts;
  Appeal(
      {required this.levelId,
      required this.expected,
      required this.audioPath,
      required this.ts});
  Map<String, dynamic> toJson() => {
        'levelId': levelId,
        'expected': expected,
        'audioPath': audioPath,
        'ts': ts,
      };
  factory Appeal.fromJson(Map<String, dynamic> j) => Appeal(
        levelId: j['levelId'] as String,
        expected: j['expected'] as String,
        audioPath: j['audioPath'] as String,
        ts: j['ts'] as int,
      );
}

// ProgressService: storage backend replaced Hive -> SQLite (M1).
// Public interface (getters/methods) is intentionally UNCHANGED so UI and
// service call sites keep working; an in-memory cache backs the synchronous
// getters, while mutations persist to SQLite and update the cache.
class ProgressService {
  final AppDatabase _db = AppDatabase();
  final Map<String, String> _cache = {};

  Future<void> init() async {
    await _db.db;
    _cache.addAll(await _db.getAllKv());
  }

  String? _kv(String k) => _cache[k];
  Future<void> _put(String k, String v) async {
    _cache[k] = v;
    await _db.setKv(k, v);
  }

  Set<String> get completedLevels => Set<String>.from(
      (jsonDecode(_kv('completed') ?? '[]') as List).cast<String>());

  Future<void> markCompleted(String id) async {
    final set = completedLevels;
    set.add(id);
    await _put('completed', jsonEncode(set.toList()));
  }

  bool get seenFtue => _kv('seenFtue') == 'true';
  Future<void> setSeenFtue(bool v) => _put('seenFtue', v.toString());

  // Empty/unset key reads back as null to keep "无 Key 回显" behavior identical.
  String? get azureKey {
    final v = _kv('azureKey');
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setAzureKey(String? k) => _put('azureKey', k ?? '');

  String? get azureRegion {
    final v = _kv('azureRegion');
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setAzureRegion(String? r) => _put('azureRegion', r ?? '');

  String? get updateUrl {
    final v = _kv('updateUrl');
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setUpdateUrl(String? u) => _put('updateUrl', u ?? '');

  int get hintCount => int.tryParse(_kv('hintCount') ?? '') ?? 0;
  Future<void> incHint() => _put('hintCount', (hintCount + 1).toString());

  int get sayCount => int.tryParse(_kv('sayCount') ?? '') ?? 0;
  Future<void> incSay() => _put('sayCount', (sayCount + 1).toString());

  // —— 掌握度四维：recognize / build / say / swap ——
  static const List<String> _dims = ['recognize', 'build', 'say', 'swap'];
  List<bool> dimsFor(String levelId) {
    final map =
        jsonDecode(_kv('dims') ?? '{}') as Map<String, dynamic>;
    final raw = map[levelId];
    if (raw == null) return const [false, false, false, false];
    final list = (raw as List).cast<bool>();
    return [for (var i = 0; i < 4; i++) i < list.length ? list[i] : false];
  }

  Future<void> recordDim(String levelId, String dim) async {
    final map = Map<String, dynamic>.from(
        jsonDecode(_kv('dims') ?? '{}') as Map<String, dynamic>);
    final list = (map[levelId] as List? ?? [false, false, false, false])
        .cast<bool>()
        .toList();
    while (list.length < 4) list.add(false);
    final idx = _dims.indexOf(dim);
    if (idx >= 0) list[idx] = true;
    map[levelId] = list;
    await _put('dims', jsonEncode(map));
  }

  // —— 申诉收件箱 ——
  List<Appeal> appeals() {
    final raw = jsonDecode(_kv('appeals') ?? '[]') as List;
    return raw.map((j) => Appeal.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<void> addAppeal(String levelId, String expected, String audioPath) async {
    final list = (jsonDecode(_kv('appeals') ?? '[]') as List)
        .cast<Map<String, dynamic>>()
        .toList();
    list.add(Appeal(
            levelId: levelId,
            expected: expected,
            audioPath: audioPath,
            ts: DateTime.now().millisecondsSinceEpoch).toJson());
    await _put('appeals', jsonEncode(list));
  }

  int get appealCount => appeals().length;

  // —— 申诉：仅记事件日志，不存音频（超出本期音频存储范围） ——
  Future<void> logAppeal(String levelId, String expected) async {
    final list = (jsonDecode(_kv('appeals') ?? '[]') as List)
        .cast<Map<String, dynamic>>()
        .toList();
    list.add({
      'levelId': levelId,
      'expected': expected,
      'ts': DateTime.now().millisecondsSinceEpoch
    });
    await _put('appeals', jsonEncode(list));
  }

  // —— 复习队列（次日到期，兼容旧接口；M4 起以 chunks.due_date 为准） ——
  Map<String, int> _reviewMap() =>
      Map<String, int>.from(jsonDecode(_kv('review') ?? '{}') as Map<String, dynamic>);

  Future<void> scheduleReview(List<String> chunkKeys) async {
    final map = _reviewMap();
    final next =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    for (final k in chunkKeys) map.putIfAbsent(k, () => next);
    await _put('review', jsonEncode(map));
  }

  List<String> dueReviews() {
    final map = _reviewMap();
    final now = DateTime.now().millisecondsSinceEpoch;
    return map.entries
        .where((e) => e.value <= now)
        .map((e) => e.key)
        .toList();
  }

  Future<void> removeReview(String key) async {
    final map = _reviewMap();
    map.remove(key);
    await _put('review', jsonEncode(map));
  }

  int get dueReviewCount => dueReviews().length;

  // —— 连续天数（streak） ——
  String? get lastActiveDay => _kv('lastActiveDay');
  int get streak => int.tryParse(_kv('streak') ?? '') ?? 0;
  Future<void> bumpStreak() async {
    final today = _dateKey(DateTime.now());
    if (lastActiveDay == today) return;
    final last = lastActiveDay;
    final s = (last != null &&
            last ==
                _dateKey(DateTime.now()
                    .subtract(const Duration(days: 1))))
        ? streak + 1
        : 1;
    await _put('streak', s.toString());
    await _put('lastActiveDay', today);
  }

  String _dateKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  // —— 发音分数（用于 Accuracy average） ——
  Future<void> recordScore(int s) async {
    final list = (jsonDecode(_kv('scores') ?? '[]') as List).cast<int>().toList();
    list.add(s.clamp(0, 100));
    await _put('scores', jsonEncode(list));
  }

  double get avgScore {
    final list = (jsonDecode(_kv('scores') ?? '[]') as List).cast<int>();
    if (list.isEmpty) return 0;
    return list.reduce((a, b) => a + b) / list.length;
  }

  int chunksMastered(ContentPack content) {
    int n = 0;
    for (final lv in content.levels) {
      if (completedLevels.contains(lv.id)) n += lv.chunks.length;
    }
    return n;
  }
}

class TtsService {
  final FlutterTts _tts = FlutterTts();

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.9);
    await _tts.setPitch(1.0);
  }

  Future<void> speak(String text) async {
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
  }
}

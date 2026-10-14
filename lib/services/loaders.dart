import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/content_pack.dart';

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

class ProgressService {
  late Box _box;

  Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox('cs_progress');
  }

  Set<String> get completedLevels =>
      Set<String>.from((_box.get('completed', defaultValue: <String>[]) as List).cast<String>());

  Future<void> markCompleted(String id) async {
    final set = completedLevels;
    set.add(id);
    await _box.put('completed', set.toList());
  }

  bool get seenFtue => _box.get('seenFtue', defaultValue: false) as bool;
  Future<void> setSeenFtue(bool v) => _box.put('seenFtue', v);

  String? get azureKey => _box.get('azureKey') as String?;
  Future<void> setAzureKey(String? k) => _box.put('azureKey', k);

  String? get azureRegion => _box.get('azureRegion') as String?;
  Future<void> setAzureRegion(String? r) => _box.put('azureRegion', r);

  // —— 更新源（远端 version.json 地址，可在设置页改动，便于免重装测试更新链路） ——
  String? get updateUrl => _box.get('updateUrl') as String?;
  Future<void> setUpdateUrl(String? u) => _box.put('updateUrl', u);

  int get hintCount => _box.get('hintCount', defaultValue: 0) as int;
  Future<void> incHint() => _box.put('hintCount', hintCount + 1);

  int get sayCount => _box.get('sayCount', defaultValue: 0) as int;
  Future<void> incSay() => _box.put('sayCount', sayCount + 1);

  // —— 掌握度四维：recognize / build / say / swap ——
  static const List<String> _dims = ['recognize', 'build', 'say', 'swap'];
  List<bool> dimsFor(String levelId) {
    final map =
        (_box.get('dims', defaultValue: <String, dynamic>{}) as Map).cast<String, dynamic>();
    final raw = map[levelId];
    if (raw == null) return const [false, false, false, false];
    final list = (raw as List).cast<bool>();
    return [for (var i = 0; i < 4; i++) i < list.length ? list[i] : false];
  }

  Future<void> recordDim(String levelId, String dim) async {
    final map = Map<String, dynamic>.from(
        (_box.get('dims', defaultValue: <String, dynamic>{}) as Map).cast<String, dynamic>());
    final list = (map[levelId] as List? ?? [false, false, false, false])
        .cast<bool>()
        .toList();
    while (list.length < 4) list.add(false);
    final idx = _dims.indexOf(dim);
    if (idx >= 0) list[idx] = true;
    map[levelId] = list;
    await _box.put('dims', map);
  }

  // —— 申诉收件箱 ——
  List<Appeal> appeals() {
    final raw =
        (_box.get('appeals', defaultValue: <dynamic>[]) as List).cast<Map<String, dynamic>>();
    return raw.map((j) => Appeal.fromJson(j)).toList();
  }

  Future<void> addAppeal(String levelId, String expected, String audioPath) async {
    final list = (_box.get('appeals', defaultValue: <dynamic>[]) as List)
        .cast<Map<String, dynamic>>()
        .toList();
    list.add(Appeal(
            levelId: levelId,
            expected: expected,
            audioPath: audioPath,
            ts: DateTime.now().millisecondsSinceEpoch).toJson());
    await _box.put('appeals', list);
  }

  int get appealCount =>
      (_box.get('appeals', defaultValue: <dynamic>[]) as List).length;

  // —— 复习队列（次日到期） ——
  Map<String, int> _reviewMap() =>
      Map<String, int>.from((_box.get('review', defaultValue: <String, int>{})
          as Map).cast<String, int>());

  Future<void> scheduleReview(List<String> chunkKeys) async {
    final map = _reviewMap();
    final next =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
    for (final k in chunkKeys) map.putIfAbsent(k, () => next);
    await _box.put('review', map);
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
    await _box.put('review', map);
  }

  int get dueReviewCount => dueReviews().length;

  // —— 连续天数（streak） ——
  String? get lastActiveDay => _box.get('lastActiveDay') as String?;
  int get streak => _box.get('streak', defaultValue: 0) as int;
  Future<void> bumpStreak() async {
    final today = _dateKey(DateTime.now());
    if (lastActiveDay == today) return;
    final last = lastActiveDay;
    final s = (last != null &&
            last == _dateKey(DateTime.now().subtract(const Duration(days: 1))))
        ? streak + 1
        : 1;
    await _box.put('streak', s);
    await _box.put('lastActiveDay', today);
  }

  String _dateKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  // —— 发音分数（用于 Accuracy average） ——
  Future<void> recordScore(int s) async {
    final list =
        (_box.get('scores', defaultValue: <int>[]) as List).cast<int>().toList();
    list.add(s.clamp(0, 100));
    await _box.put('scores', list);
  }

  double get avgScore {
    final list = (_box.get('scores', defaultValue: <int>[]) as List).cast<int>();
    if (list.isEmpty) return 0;
    return list.reduce((a, b) => a + b) / list.length;
  }

  // —— 申诉：仅记事件日志，不存音频（超出本期音频存储范围） ——
  Future<void> logAppeal(String levelId, String expected) async {
    final list = (_box.get('appeals', defaultValue: <dynamic>[])
            as List)
        .cast<Map<String, dynamic>>()
        .toList();
    list.add({
      'levelId': levelId,
      'expected': expected,
      'ts': DateTime.now().millisecondsSinceEpoch
    });
    await _box.put('appeals', list);
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

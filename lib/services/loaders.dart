import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/content_pack.dart';
import 'database.dart';
import 'chunk_progress.dart';
import 'session.dart';

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
    await ensureMigrated();
  }

  /// M4：v1.1.0 首启检测旧数据 → 重置学习进度（保留 Azure Key / 更新源 / FTUE 等设置）。
  /// 返回 true 表示本次发生了重置（供 UI 提示"训练系统升级，从第一课重新开始"）。
  Future<bool> ensureMigrated() async {
    if (!Migration.needsReset(_kv('dataVersion'))) return false;
    await _db.setKv('completed', jsonEncode([]));
    await _db.setKv('dims', jsonEncode({}));
    await _db.setKv('streak', '0');
    await _db.setKv('lastActiveDay', '');
    await _db.setKv('scores', jsonEncode([]));
    await _db.setKv('review', jsonEncode({}));
    await _db.resetChunks();
    await _db.setKv('dataVersion', Migration.currentDataVersion);
    _cache.addAll(await _db.getAllKv());
    return true;
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

  // —— M7 双层 AI 服务配置 ——
  // 自定义层：用户自配 OpenAI 兼容服务（baseUrl + model + key），开关默认关。
  // 内置层：编译期注入（见 builtin_llm.dart），此处只存「失败时间戳 / 整体不可用」状态。
  // 所有 Key 仅存于本地 kv，绝不打印 / 写日志；仓库内永不出现明文。

  String? _blank(String? v) => (v == null || v.isEmpty) ? null : v;

  bool get customLlmEnabled => _kv('customLlmEnabled') == 'true';
  Future<void> setCustomLlmEnabled(bool v) => _put('customLlmEnabled', v.toString());

  String? get customLlmUrl => _blank(_kv('customLlmUrl'));
  Future<void> setCustomLlmUrl(String? v) => _put('customLlmUrl', v ?? '');

  String? get customLlmModel => _blank(_kv('customLlmModel'));
  Future<void> setCustomLlmModel(String? v) => _put('customLlmModel', v ?? '');

  String? get customLlmKey => _blank(_kv('customLlmKey'));
  Future<void> setCustomLlmKey(String? v) => _put('customLlmKey', v ?? '');

  /// 清除自定义配置（含开关关闭），回落到内置层。
  Future<void> clearCustomLlm() async {
    await setCustomLlmEnabled(false);
    await setCustomLlmUrl(null);
    await setCustomLlmModel(null);
    await setCustomLlmKey(null);
  }

  // —— 内置层可用性状态（失败时间戳用于 ≥60s 退避，避免重试风暴）——
  int builtinFailTs(int i) =>
      int.tryParse(_kv('builtinFail_$i') ?? '') ?? 0;
  Future<void> setBuiltinFailTs(int i, int ts) =>
      _put('builtinFail_$i', ts.toString());

  bool get builtinUnavailable => _kv('builtinUnavailable') == 'true';
  Future<void> setBuiltinUnavailable(bool v) =>
      _put('builtinUnavailable', v.toString());

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

  // —— 每日目标（留存钩子，D10）：默认 5 句/天，存 kv ——
  int get dailyGoal => int.tryParse(_kv('dailyGoal') ?? '') ?? 5;
  Future<void> setDailyGoal(int n) async => await _put('dailyGoal', n.toString());

  String _dateKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  // —— 发音分数（用于 Accuracy average） ——
  Future<void> recordScore(int s) async {
    final list = (jsonDecode(_kv('scores') ?? '[]') as List).cast<int>().toList();
    list.add(s.clamp(0, 100));
    if (list.length > 50) list.removeAt(0); // 保留最近 50 条，避免 kv 膨胀（D11）
    await _put('scores', jsonEncode(list));
  }

  double get avgScore {
    final list = (jsonDecode(_kv('scores') ?? '[]') as List).cast<int>();
    if (list.isEmpty) return 0;
    return list.reduce((a, b) => a + b) / list.length;
  }

  /// M7：已掌握词块数 = 达到 mastered 等级的 chunk 总数（硬门槛统计）。
  Future<int> chunksMastered(ContentPack content) async {
    final set = (await chunkStore.allMasteredKeys()).toSet();
    int n = 0;
    for (final lv in content.levels) {
      n += lv.chunks.where((c) => set.contains(c.id)).length;
    }
    return n;
  }

  // 结构化进度存储（M1 状态机/调度后端），与 ProgressService 共享同一 SQLite 库。
  ChunkProgressStore get chunkStore => ChunkProgressStore(_db);
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

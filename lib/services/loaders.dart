import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/content_pack.dart';
import 'crash_log.dart';
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
  final AppDatabase _db;
  final Map<String, String> _cache = {};
  ProgressService({AppDatabase? db}) : _db = db ?? AppDatabase();

  Future<void> init() async {
    await _db.db;
    _cache.addAll(await _db.getAllKv());
    await ensureMigrated();
    await _migrateSchema();
  }

  /// 非破坏式 schema 版本管理（A0 红线）：只做增量/幂等升级，绝不破坏现有进度。
  /// 未来新增列一律走「ALTER ADD COLUMN + 默认值」，在此按版本逐级追加。
  Future<void> _migrateSchema() async {
    final stored = int.tryParse(_kv('schemaVersion') ?? '') ?? 0;
    if (stored >= SchemaMigration.currentSchema) return;
    // v1.4.0（schema=1）：无结构变更，仅落版本号。后续版本在此追加 1→2、2→3…
    await _put('schemaVersion', '${SchemaMigration.currentSchema}');
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

  /// 今日已开口句数（跨日自动归零，供每日目标进度展示）。
  int get todaySpoken {
    if (_kv('todaySpokenDate') != _dateKey(DateTime.now())) return 0;
    return int.tryParse(_kv('todaySpoken') ?? '') ?? 0;
  }

  /// 记一次「开口成功」：今日计数 +1，并顺带完成当日打卡
  /// （streak 同日只记一次，故任意一次开口都算打卡，不再只认「掌握」）。
  Future<void> noteSpoken() async {
    final today = _dateKey(DateTime.now());
    final same = _kv('todaySpokenDate') == today;
    final cur = same ? (int.tryParse(_kv('todaySpoken') ?? '') ?? 0) : 0;
    await _put('todaySpokenDate', today);
    await _put('todaySpoken', (cur + 1).toString());
    await bumpStreak();
  }

  // —— 留存通知设置（默认关；默认 20:00）——
  bool get notifEnabled => _kv('notifEnabled') == 'true';
  Future<void> setNotifEnabled(bool v) => _put('notifEnabled', v.toString());

  int get notifHour => int.tryParse(_kv('notifHour') ?? '') ?? 20;
  int get notifMinute => int.tryParse(_kv('notifMinute') ?? '') ?? 0;
  Future<void> setNotifTime(int h, int m) async {
    await _put('notifHour', h.toString());
    await _put('notifMinute', m.toString());
  }

  // —— 新手引导（P0-二）：复用 seenFtue 语义（首次启动 3 屏引导）——
  bool get onboardingDone => seenFtue;
  Future<void> setOnboardingDone() => setSeenFtue(true);

  // —— 今日新学词块数（P0-一.1）：当日「新掌握」的词块计数 ——
  int get dailyNewCount {
    if (_kv('dailyNewDate') != _dateKey(DateTime.now())) return 0;
    return int.tryParse(_kv('dailyNewCount') ?? '') ?? 0;
  }

  Future<void> bumpDailyNew() async {
    final today = _dateKey(DateTime.now());
    final same = _kv('dailyNewDate') == today;
    final cur = same ? (int.tryParse(_kv('dailyNewCount') ?? '') ?? 0) : 0;
    await _put('dailyNewDate', today);
    await _put('dailyNewCount', (cur + 1).toString());
  }

  // —— 自由造句（P0-四 / v1.4.0 沙盒）——
  int get freeBuildCount => int.tryParse(_kv('freeBuildCount') ?? '') ?? 0;
  Future<void> incFreeBuild() =>
      _put('freeBuildCount', (freeBuildCount + 1).toString());
  bool get freeBuildBadge => _kv('freeBuildBadge') == 'true';
  Future<void> awardFreeBuildBadge() => _put('freeBuildBadge', 'true');

  // —— 里程碑（A4）：累计掌握 10/25/50/100 块各庆祝一次，数字全部真实 ——
  static const List<int> kMilestones = [10, 25, 50, 100];
  Set<int> get celebratedMilestones {
    final raw = jsonDecode(_kv('milestones') ?? '[]') as List;
    return raw.cast<int>().toSet();
  }

  Future<void> markMilestoneCelebrated(int n) async {
    final set = celebratedMilestones..add(n);
    await _put('milestones', jsonEncode(set.toList()));
  }

  /// 当前应触发、且尚未庆祝的最小里程碑（无则 null）。
  Future<int?> pendingMilestone() async {
    final total = (await chunkStore.allMasteredKeys()).length;
    for (final m in kMilestones) {
      if (total >= m && !celebratedMilestones.contains(m)) return m;
    }
    return null;
  }

  // —— 升级亮点（A6）：v1.4.0 首启一次性清单，看过记忆不再弹 ——
  bool get seenChangelog140 => _kv('seenChangelog140') == 'true';
  Future<void> setSeenChangelog140() => _put('seenChangelog140', 'true');

  // —— 体验开关（B7）：音效开关（震动跟随系统，无需独立开关）——
  bool get soundOn => _kv('soundOn') != 'false'; // 默认开
  Future<void> setSoundOn(bool v) => _put('soundOn', v.toString());

  // —— 首次练习漏斗标记（P0-七）——
  bool get firstPracticeStarted => _kv('firstPracticeStarted') == 'true';
  Future<void> setFirstPracticeStarted() =>
      _put('firstPracticeStarted', 'true');
  bool get firstPracticeDone => _kv('firstPracticeDone') == 'true';
  Future<void> setFirstPracticeDone() => _put('firstPracticeDone', 'true');

  // —— 数据埋点（P0-七）：本地事件日志，无服务端成本 ——
  List<Map<String, dynamic>> get analyticsEvents =>
      (jsonDecode(_kv('analytics_events') ?? '[]') as List)
          .cast<Map<String, dynamic>>()
          .toList();

  Future<void> logEvent(String name, [Map<String, dynamic>? params]) async {
    final list = analyticsEvents;
    list.add({
      'n': name,
      'ts': DateTime.now().millisecondsSinceEpoch,
      if (params != null) 'p': params,
    });
    if (list.length > 500) list.removeRange(0, list.length - 500);
    await _put('analytics_events', jsonEncode(list));
  }

  /// 一次性事件（P0-七）：如 day2/day7 回访，只记首次。
  Future<void> logOnce(String name, [Map<String, dynamic>? params]) async {
    if (_kv('evt_$name') == '1') return;
    await _put('evt_$name', '1');
    await logEvent(name, params);
  }

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
  // onNewMastery：词块「当日新学」计数钩子（P0-一.1）。
  ChunkProgressStore get chunkStore =>
      ChunkProgressStore(_db, onNewMastery: () { bumpDailyNew(); });
}

/// A1：自由造句沙盒解锁阈值（累计掌握 ≥10 块）。
const int kFreeBuildUnlockMastered = 10;
bool freeBuildUnlocked(int masteredCount) =>
    masteredCount >= kFreeBuildUnlockMastered;

class TtsService {
  final FlutterTts _tts = FlutterTts();

  /// 英语语音变体回退顺序：en-US 优先，设备不支持时逐级降级。
  static const List<String> _enVariants = [
    'en-US', 'en-GB', 'en-AU', 'en-CA', 'en-IN', 'en',
  ];

  String? _language;
  String? _lastError;
  bool _available = false;

  /// 实际选用的 TTS 语言（en-US 不可用时自动回退到其他英语变体）。
  String? get language => _language;

  /// TTS 是否可用（已找到可用的英语语音）。
  bool get available => _available;

  /// 最近一次播放失败原因（供诊断 / UI 提示「无法播放」）。
  String? get lastError => _lastError;

  /// 初始化：检测英语语音可用性，en-US 不可用则回退到其他英语变体。
  /// 全程非致命：任何异常都记为不可用，绝不阻塞启动。
  Future<void> init() async {
    try {
      for (final lang in _enVariants) {
        final ok = await _tts.isLanguageAvailable(lang);
        if (ok == true) {
          await _tts.setLanguage(lang);
          await _tts.setSpeechRate(0.9);
          await _tts.setPitch(1.0);
          _language = lang;
          _available = true;
          _lastError = null;
          return;
        }
      }
      _available = false;
      _lastError = 'no-english-tts';
    } catch (e, st) {
      _available = false;
      _lastError = '$e';
      CrashLog.write('TtsService.init: $e', st);
    }
  }

  /// 播放文本。成功返回 true；引擎不可用或播放失败返回 false，
  /// 并记录 lastError（供 UI 提示「无法播放」，避免点喇叭无声且无任何反馈）。
  Future<bool> speak(String text) async {
    if (!_available) {
      _lastError ??= 'tts-unavailable';
      return false;
    }
    try {
      final r = await _tts.speak(text);
      // flutter_tts 的 speak 返回 1（成功）或 0（失败）。
      if (r == 0) {
        _lastError = 'tts-speak-returned-0';
        return false;
      }
      _lastError = null;
      return true;
    } catch (e, st) {
      _lastError = '$e';
      CrashLog.write('TtsService.speak: $e', st);
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (e, st) {
      CrashLog.write('TtsService.stop: $e', st);
    }
  }
}

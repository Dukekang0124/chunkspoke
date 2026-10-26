import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/content_pack.dart';
import '../models/listening_article.dart';
import 'crash_log.dart';
import 'database.dart';
import 'chunk_asset.dart';
import 'chunk_progress.dart';
import 'hd_voice_types.dart';
import 'listening_audio.dart';
import 'listening_store.dart';
import 'sandbox_store.dart';
import 'secure_store.dart';
import 'session.dart';
import 'tts_voice.dart';

Future<ContentPack> loadContentPack() async {
  final str = await rootBundle.loadString('assets/content_pack.json');
  return ContentPack.fromJson(jsonDecode(str) as Map<String, dynamic>);
}

/// 收听文章（磨耳朵 · 浸泡层）。schema 校验在 test 与 debug 启动时执行。
Future<ListeningPack> loadListeningPack() async {
  final str = await rootBundle.loadString('assets/listening_articles.json');
  return ListeningPack.fromJson(jsonDecode(str) as Map<String, dynamic>);
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
  final DateTime Function() _clock;
  final KeyCipher _cipher;
  final Map<String, String> _cache = {};
  /// 自定义模型 Key 的明文只活在内存；落库永远是 enc:v1: 密文。
  String? _llmKeyPlain;
  /// 词块层级表（id → T0/T1/T2），启动时由内容包灌入；复习播单据此 T0 优先。
  Map<String, String> _chunkTiers = const {};
  ProgressService({AppDatabase? db, DateTime Function()? clock, KeyCipher? cipher})
      : _clock = clock ?? DateTime.now,
        _cipher = cipher ?? const KeystoreCipher(),
        _db = db ?? AppDatabase(clock: clock);

  /// 启动装配：内容包 → 层级表（只存 id/层级，无用户数据）。
  void setChunkTiers(ContentPack content) {
    _chunkTiers = {
      for (final lv in content.levels)
        for (final c in lv.chunks) c.id: c.tier,
    };
  }

  /// 统一时钟（E2E 时间加速/单测可注入；生产恒为真实时间）。
  DateTime get now => _clock();

  Future<void> init() async {
    await _db.db;
    _cache.addAll(await _db.getAllKv());
    await _loadLlmKey();
    await ensureMigrated();
    await _migrateSchema();
  }

  /// 启动时把 Key 解到内存；历史明文值就地加密回写（一次性迁移）。
  Future<void> _loadLlmKey() async {
    final raw = _kv('customLlmKey');
    if (raw == null || raw.isEmpty) {
      _llmKeyPlain = null;
      return;
    }
    if (raw.startsWith(kEncPrefix)) {
      _llmKeyPlain = await _cipher.decrypt(raw);
      return;
    }
    _llmKeyPlain = raw;
    try {
      await _put('customLlmKey', await _cipher.encrypt(raw));
    } catch (_) {
      // 加密不可用：宁可丢弃让用户重填，也不把明文留在磁盘。
      _llmKeyPlain = null;
      await _put('customLlmKey', '');
    }
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

  /// TTS 引导页已读/已跳过：只在用户点「先继续使用」时置位，
  /// 避免每次启动都拦截；修好后检测为 ready 时自然不再展示。
  bool get ttsGuideDone => _kv('ttsGuideDone') == 'true';
  Future<void> setTtsGuideDone(bool v) => _put('ttsGuideDone', v.toString());

  /// 发音音色（引擎|名称|locale）；null = 自动优选。
  String? get ttsVoiceKey {
    final v = _kv('ttsVoice');
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setTtsVoiceKey(String? key) => _put('ttsVoice', key ?? '');

  /// 高清发音包开关：默认开（下载完成后即生效，可随时切回系统引擎）。
  bool get hdVoiceEnabled => _kv('hdVoiceEnabled') != 'false';
  Future<void> setHdVoiceEnabled(bool v) =>
      _put('hdVoiceEnabled', v.toString());

  /// 当前选中的自然人声音色（模型目录名）；未选过为空。
  String? get hdVoiceId {
    final v = _kv('hdVoiceId');
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setHdVoiceId(String? id) => _put('hdVoiceId', id ?? '');

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

  // —— AI 服务配置（1.5.8 起只有用户自定义层）——
  // 用户自配 OpenAI 兼容服务（baseUrl + model + key），开关默认关。
  // Key 落库为 Android Keystore 密文（见 secure_store.dart），内存里才短暂是明文；
  // 绝不打印 / 写日志 / 进导出。未配置时 AI 功能走本机规则引擎，不联网。

  String? _blank(String? v) => (v == null || v.isEmpty) ? null : v;

  bool get customLlmEnabled => _kv('customLlmEnabled') == 'true';
  Future<void> setCustomLlmEnabled(bool v) =>
      _put('customLlmEnabled', v.toString());

  String? get customLlmUrl => _blank(_kv('customLlmUrl'));
  Future<void> setCustomLlmUrl(String? v) => _put('customLlmUrl', v ?? '');

  String? get customLlmModel => _blank(_kv('customLlmModel'));
  Future<void> setCustomLlmModel(String? v) => _put('customLlmModel', v ?? '');

  String? get customLlmKey => _blank(_llmKeyPlain);
  Future<void> setCustomLlmKey(String? v) async {
    final k = _blank(v);
    _llmKeyPlain = k;
    await _put('customLlmKey', k == null ? '' : await _cipher.encrypt(k));
  }

  /// 清除自定义配置（含开关关闭），回落到本地统计。
  Future<void> clearCustomLlm() async {
    await setCustomLlmEnabled(false);
    await setCustomLlmUrl(null);
    await setCustomLlmModel(null);
    await setCustomLlmKey(null);
  }

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
    final map = jsonDecode(_kv('dims') ?? '{}') as Map<String, dynamic>;
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
    while (list.length < 4) {
      list.add(false);
    }
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

  Future<void> addAppeal(
      String levelId, String expected, String audioPath) async {
    final list = (jsonDecode(_kv('appeals') ?? '[]') as List)
        .cast<Map<String, dynamic>>()
        .toList();
    list.add(Appeal(
            levelId: levelId,
            expected: expected,
            audioPath: audioPath,
            ts: _clock().millisecondsSinceEpoch)
        .toJson());
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
      'ts': _clock().millisecondsSinceEpoch
    });
    await _put('appeals', jsonEncode(list));
  }

  // —— 复习队列（次日到期，兼容旧接口；M4 起以 chunks.due_date 为准） ——
  Map<String, int> _reviewMap() => Map<String, int>.from(
      jsonDecode(_kv('review') ?? '{}') as Map<String, dynamic>);

  Future<void> scheduleReview(List<String> chunkKeys) async {
    final map = _reviewMap();
    final next =
        _clock().add(const Duration(days: 1)).millisecondsSinceEpoch;
    for (final k in chunkKeys) {
      map.putIfAbsent(k, () => next);
    }
    await _put('review', jsonEncode(map));
  }

  List<String> dueReviews() {
    final map = _reviewMap();
    final now = _clock().millisecondsSinceEpoch;
    return map.entries.where((e) => e.value <= now).map((e) => e.key).toList();
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
    final today = _dateKey(_clock());
    if (lastActiveDay == today) return;
    final last = lastActiveDay;
    final s = (last != null &&
            last == _dateKey(_clock().subtract(const Duration(days: 1))))
        ? streak + 1
        : 1;
    await _put('streak', s.toString());
    await _put('lastActiveDay', today);
  }

  // —— 每日目标（留存钩子，D10）：默认 5 句/天，存 kv ——
  int get dailyGoal => int.tryParse(_kv('dailyGoal') ?? '') ?? 5;
  Future<void> setDailyGoal(int n) async =>
      await _put('dailyGoal', n.toString());

  /// 今日已开口句数（跨日自动归零，供每日目标进度展示）。
  int get todaySpoken {
    if (_kv('todaySpokenDate') != _dateKey(_clock())) return 0;
    return int.tryParse(_kv('todaySpoken') ?? '') ?? 0;
  }

  /// 记一次「开口成功」：今日计数 +1，并顺带完成当日打卡
  /// （streak 同日只记一次，故任意一次开口都算打卡，不再只认「掌握」）。
  Future<void> noteSpoken() async {
    final today = _dateKey(_clock());
    final same = _kv('todaySpokenDate') == today;
    final cur = same ? (int.tryParse(_kv('todaySpoken') ?? '') ?? 0) : 0;
    await _put('todaySpokenDate', today);
    await _put('todaySpoken', (cur + 1).toString());
    await bumpStreak();
  }

  // —— 留存通知设置（默认关；默认 20:00）——
  /// M1（#64）：首次完听后只问一次通知，不在进页面时静默索取。
  bool get notifAskDone => _kv('notifAskDone') == 'true';
  Future<void> setNotifAskDone() => _put('notifAskDone', 'true');

  bool get notifEnabled => _kv('notifEnabled') == 'true';
  Future<void> setNotifEnabled(bool v) => _put('notifEnabled', v.toString());

  int get notifHour => int.tryParse(_kv('notifHour') ?? '') ?? 20;
  int get notifMinute => int.tryParse(_kv('notifMinute') ?? '') ?? 0;
  Future<void> setNotifTime(int h, int m) async {
    await _put('notifHour', h.toString());
    await _put('notifMinute', m.toString());
  }

  // —— 到期复习提醒（1.5 · 模块 C）：默认关，用户可单独开关 ——
  bool get reviewNotifEnabled => _kv('reviewNotifEnabled') == 'true';
  Future<void> setReviewNotifEnabled(bool v) =>
      _put('reviewNotifEnabled', v.toString());

  // —— 新手引导（P0-二）：复用 seenFtue 语义（首次启动 3 屏引导）——
  bool get onboardingDone => seenFtue;
  Future<void> setOnboardingDone() => setSeenFtue(true);

  // —— 今日新学词块数（P0-一.1）：当日「新掌握」的词块计数 ——
  int get dailyNewCount {
    if (_kv('dailyNewDate') != _dateKey(_clock())) return 0;
    return int.tryParse(_kv('dailyNewCount') ?? '') ?? 0;
  }

  Future<void> bumpDailyNew() async {
    final today = _dateKey(_clock());
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
  /// W2-1：里程碑「累计掌握」按资产轴（走完复习阶梯）计数。
  Future<int?> pendingMilestone() async {
    final total = await chunkStore.assetMasteredCount();
    for (final m in kMilestones) {
      if (total >= m && !celebratedMilestones.contains(m)) return m;
    }
    return null;
  }

  // —— 升级亮点（A6）：v1.4.0 首启一次性清单，看过记忆不再弹 ——
  /// M1（#64）：权限前说明每个权限只弹一次，说明过就记下来。
  bool get prepromptSeenMic => _kv('prepromptMic') == 'true';
  Future<void> setPrepromptSeenMic() => _put('prepromptMic', 'true');
  bool get prepromptSeenNotify => _kv('prepromptNotify') == 'true';
  Future<void> setPrepromptSeenNotify() => _put('prepromptNotify', 'true');

  bool get seenChangelog140 => _kv('seenChangelog140') == 'true';
  Future<void> setSeenChangelog140() => _put('seenChangelog140', 'true');

  // —— 体验开关（B7）：音效开关（震动跟随系统，无需独立开关）——
  bool get soundOn => _kv('soundOn') != 'false'; // 默认开
  Future<void> setSoundOn(bool v) => _put('soundOn', v.toString());

  // —— 隐私开关：AI 联网点评。关闭后「自由造句」只用本机规则引擎判定，不发任何请求 ——
  bool get aiNetOn => _kv('aiNetOn') != 'false'; // 默认开
  Future<void> setAiNetOn(bool v) => _put('aiNetOn', v.toString());

  // —— 六步学习断点（按场景存，完成整关后清除）——
  String? learnResume(String levelId) {
    final v = _kv('learnResume_$levelId');
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setLearnResume(String levelId, String? encoded) =>
      _put('learnResume_$levelId', encoded ?? '');

  Future<void> clearLearnResume(String levelId) =>
      _put('learnResume_$levelId', '');

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
      'ts': _clock().millisecondsSinceEpoch,
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
    final list =
        (jsonDecode(_kv('scores') ?? '[]') as List).cast<int>().toList();
    list.add(s.clamp(0, 100));
    if (list.length > 50) list.removeAt(0); // 保留最近 50 条，避免 kv 膨胀（D11）
    await _put('scores', jsonEncode(list));
  }

  double get avgScore {
    final list = (jsonDecode(_kv('scores') ?? '[]') as List).cast<int>();
    if (list.isEmpty) return 0;
    return list.reduce((a, b) => a + b) / list.length;
  }

  /// W2-1：已掌握词块数 = 资产轴 mastered 状态的块数（内容包内）。
  Future<int> chunksMastered(ContentPack content) async {
    final ids = <String>{
      for (final lv in content.levels)
        for (final c in lv.chunks) c.id,
    };
    final rows = await chunkStore.allRows();
    return rows
        .where((r) =>
            ids.contains(r.chunkKey) &&
            r.assetState == ChunkAssetState.mastered)
        .length;
  }

  /// 已学完（资产轴非 learning）：六步走完或已进入复习周期的块数。
  Future<int> chunksLearned(ContentPack content) async {
    final ids = <String>{
      for (final lv in content.levels)
        for (final c in lv.chunks) c.id,
    };
    final rows = await chunkStore.allRows();
    return rows
        .where((r) =>
            ids.contains(r.chunkKey) &&
            r.assetState != ChunkAssetState.learning)
        .length;
  }

  // 结构化进度存储（M1 状态机/调度后端），与 ProgressService 共享同一 SQLite 库。
  // onNewMastery：词块「当日新学」计数钩子（P0-一.1）。
  ChunkProgressStore get chunkStore => ChunkProgressStore(_db,
      clock: _clock,
      tierOf: (key) => _chunkTiers[key] ?? '',
      onNewMastery: () {
        bumpDailyNew();
      });

  /// T0 核心库总量（分母，随内容包变化）。同一块面在包内重复登记时只算一块，
  /// 与《T0 核心库清单》的「100 块」口径一致。
  static Map<String, List<String>> _coreByText(ContentPack content) {
    final map = <String, List<String>>{};
    for (final lv in content.levels) {
      for (final c in lv.chunks) {
        if (!c.isCore) continue;
        map.putIfAbsent(c.text.trim().toLowerCase(), () => []).add(c.id);
      }
    }
    return map;
  }

  static int coreTotal(ContentPack content) => _coreByText(content).length;

  /// T0 核心库已掌握数（仅统计页/导出使用）。同块面任一条 id 掌握即算覆盖。
  Future<int> coreMastered(ContentPack content) async {
    final byText = _coreByText(content);
    final rows = await chunkStore.allRows();
    final mastered = {
      for (final r in rows)
        if (r.assetState == ChunkAssetState.mastered) r.chunkKey,
    };
    return byText.values.where((ids) => ids.any(mastered.contains)).length;
  }

  /// 沙盒（自由造句）：通过校验的句子入库 + 串联计量 + 四项本地统计。
  late final SandboxStore sandbox =
      SandboxStore(read: _kv, write: _put, clock: _clock);

  /// 浸泡层（磨耳朵）：独立账本，只记收听/收词/重逢，不写学习会话轴。
  late final ListeningStore listening =
      ListeningStore(read: _kv, write: _put, clock: _clock);
}

/// A1：自由造句沙盒解锁阈值（累计学完 ≥10 块，资产轴非新学）。
const int kFreeBuildUnlockLearned = 10;
bool freeBuildUnlocked(int learnedCount) =>
    learnedCount >= kFreeBuildUnlockLearned;

/// TTS 检测结果：启动预检 / 引导页 / 错误对话框共用同一状态源。
enum TtsStatus {
  unknown, // 尚未检测
  ready, // 已找到可用的英语语音
  noEngine, // 设备上没有任何 TTS 引擎
  noEnglish, // 有引擎，但没有英文语音数据
  error, // 检测过程异常（非致命）
}

/// 薄适配层：把 flutter_tts 的平台调用隔离出来，检测分支可用假实现单测。
abstract class TtsAdapter {
  Future<String?> getDefaultEngine();
  Future<List<String>> getEngines();
  Future<bool> isLanguageAvailable(String lang);
  Future<bool> setLanguage(String lang);
  Future<void> setEngine(String engine);
  Future<void> setSpeechRate(double rate);
  Future<void> setPitch(double pitch);
  Future<int> speak(String text);
  Future<void> stop();
}

/// 声音枚举/切换能力（仅系统 TTS 引擎具备）。
/// 独立于 [TtsAdapter]，既有假实现无需新增方法即可继续编译。
abstract class TtsVoiceAdapter {
  Future<List<Map<String, String>>> fetchVoices();
  Future<bool> setVoice(TtsVoice voice);
  Future<void> clearVoice();
}

/// 离线合成到 WAV（浸泡层缓存管线用）。
/// 独立于 [TtsAdapter]，既有假实现无需新增方法即可继续编译。
abstract class TtsSynthAdapter {
  Future<bool> synthesizeToFile(String text, String fileName);
}

/// 读到句末才返回的朗读（浸泡层直播降级顺序播放用）。
abstract class TtsAwaitAdapter {
  Future<bool> speakAndWait(String text);
}

class FlutterTtsAdapter
    implements TtsAdapter, TtsVoiceAdapter, TtsSynthAdapter, TtsAwaitAdapter {
  final FlutterTts _tts = FlutterTts();

  @override
  Future<String?> getDefaultEngine() async {
    final v = await _tts.getDefaultEngine; // getter，非方法
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  @override
  Future<List<String>> getEngines() async {
    final v = await _tts.getEngines;
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }

  @override
  Future<bool> isLanguageAvailable(String lang) async =>
      await _tts.isLanguageAvailable(lang) == true;

  @override
  Future<bool> setLanguage(String lang) async {
    final r = await _tts.setLanguage(lang);
    return r == 1 || r == true;
  }

  @override
  Future<void> setEngine(String engine) => _tts.setEngine(engine);

  @override
  Future<void> setSpeechRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<void> setPitch(double pitch) => _tts.setPitch(pitch);

  @override
  Future<int> speak(String text) async {
    // flutter_tts 返回 1（已入队）或 0（失败）。
    final r = await _tts.speak(text);
    return r == 1 || r == true ? 1 : 0;
  }

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<List<Map<String, String>>> fetchVoices() async {
    final v = await _tts.getVoices;
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) e.map((k, val) => MapEntry(k.toString(), val.toString())),
    ];
  }

  @override
  Future<bool> setVoice(TtsVoice voice) async {
    final r = await _tts.setVoice({
      'name': voice.name,
      'locale': voice.locale,
    });
    return r == 1 || r == true;
  }

  @override
  Future<void> clearVoice() async {
    await _tts.clearVoice();
  }

  @override
  Future<bool> synthesizeToFile(String text, String fileName) async {
    // awaitSynthCompletion 让平台调用在文件真正写完才返回；
    // 结束后恢复，避免影响普通 speak 的既有语义。
    await _tts.awaitSynthCompletion(true);
    try {
      final r = await _tts.synthesizeToFile(text, fileName, true);
      return r == 1 || r == true;
    } finally {
      try {
        await _tts.awaitSynthCompletion(false);
      } catch (_) {}
    }
  }

  @override
  Future<bool> speakAndWait(String text) async {
    await _tts.awaitSpeakCompletion(true);
    try {
      final r = await _tts.speak(text);
      return r == 1 || r == true;
    } finally {
      try {
        await _tts.awaitSpeakCompletion(false);
      } catch (_) {}
    }
  }
}

class TtsService implements ListeningVoice {
  TtsService({
    TtsAdapter? adapter,
    String? Function()? preferredVoice,
    HdVoiceSpeaker? hdVoice,
  })  : _tts = adapter ?? FlutterTtsAdapter(),
        _preferredVoice = preferredVoice,
        _hdVoice = hdVoice;

  final TtsAdapter _tts;

  /// 高清发音包（已下载且启用时优先接管发音；失败回落系统引擎）。
  final HdVoiceSpeaker? _hdVoice;

  /// 读取用户持久化的音色（引擎|名称|locale）。为 null 表示自动优选。
  final String? Function()? _preferredVoice;

  /// 自然朗读参数（见 DDS「发音体系」章）。flutter_tts 在 Android 侧把
  /// rate×2 再交给系统引擎，0.22 → Android 0.44，实测 154 wpm（14 词 / 5.46s），
  /// 落在真人对话 140–160 wpm 区间；旧值 0.9 实际是 1.8 倍速（约 420 wpm）。
  static const double kRate = 0.22;
  static const double kPitch = 1.0;

  /// 英语语音变体回退顺序：en-US 优先，设备不支持时逐级降级。
  static const List<String> _enVariants = [
    'en-US',
    'en-GB',
    'en-AU',
    'en-CA',
    'en-IN',
    'en',
  ];

  /// 音色选择器逐行试听文本（与声音审计同一句）。
  static const String kAuditionText = "I'd like a cup of coffee.";

  /// 指定语速播放（六步听辨的慢/常/快三档）。高清包固定语速，
  /// 变速一律走系统引擎；播放后恢复默认语速，避免污染后续朗读。
  Future<bool> speakAtRate(String text, double rate) async {
    if ((rate - kRate).abs() < 0.001) return speak(text);
    if (_status != TtsStatus.ready) await init();
    if (_status != TtsStatus.ready) {
      // 系统引擎不可用但高清包可用：退回默认语速，至少能听到。
      if (_hdVoice?.active ?? false) return speak(text);
      _lastError ??=
          _status == TtsStatus.noEngine ? 'no-tts-engine' : 'tts-unavailable';
      return false;
    }
    try {
      await _tts.stop();
      await _tts.setSpeechRate(rate);
      final r = await _tts.speak(text);
      _lastError = r == 0 ? 'tts-speak-returned-0' : null;
      return r != 0;
    } catch (e, st) {
      _lastError = '$e';
      CrashLog.write('TtsService.speakAtRate: $e', st);
      return false;
    } finally {
      try {
        await _tts.setSpeechRate(kRate);
      } catch (_) {}
    }
  }

  String? _language;
  String? _lastError;
  TtsStatus _status = TtsStatus.unknown;
  String _activeEngine = '';
  List<String> _engines = const [];
  List<String> _engineOrder = const [];
  List<TtsVoice> _voices = const [];
  List<TtsVoice> _ranked = const [];
  TtsVoice? _selected;
  Future<void>? _initInFlight; // 并发保护：同一时刻只跑一次初始化

  /// 实际选用的 TTS 语言（en-US 不可用时自动回退到其他英语变体）。
  String? get language => _language;

  /// 检测状态（引导页据此区分「无引擎」与「无英文语音包」）。
  TtsStatus get status => _status;

  /// TTS 是否可用（系统英语语音或已启用的高清发音包）。
  bool get available =>
      _status == TtsStatus.ready || (_hdVoice?.active ?? false);

  /// 高清发音包当前是否接管发音（设置页展示用）。
  bool get hdActive => _hdVoice?.active ?? false;

  HdVoiceSynthesizer? get _hdSynth {
    final Object? h = _hdVoice;
    return h is HdVoiceSynthesizer ? h : null;
  }

  /// 浸泡层首选音源是否有高清包可离线合成。
  @override
  bool get preferHd => _hdSynth != null && (_hdVoice?.active ?? false);

  /// 浸泡层音频缓存键：HD 用模型版本；系统用引擎|声音|locale。
  /// 音色切换后键随之变化，缓存整篇失效重合成。
  @override
  String get voiceKey {
    final s = _hdSynth;
    if (s != null && (_hdVoice?.active ?? false)) return 'hd:${s.modelTag}';
    return systemVoiceKey;
  }

  @override
  String get systemVoiceKey {
    final v = _selected;
    if (v != null) return 'sys:${v.engine}|${v.name}|${v.locale}';
    final engine = _activeEngine.isEmpty ? 'default' : _activeEngine;
    return 'sys:$engine|auto|${_language ?? 'none'}';
  }

  /// 最近一次播放失败原因（供诊断 / UI 提示「无法播放」）。
  String? get lastError => _lastError;

  /// 当前选用/尝试的引擎包名（诊断用）。
  String get activeEngine => _activeEngine;

  /// 设备上已安装的 TTS 引擎包名（诊断/兼容清单取证用）。
  List<String> get engines => List.unmodifiable(_engines);

  /// 当前引擎下按自动优选顺序排列的英文声音（设置页选择器数据源）。
  List<TtsVoice> get voices => List.unmodifiable(_ranked);

  /// 实际生效的声音；null 表示回落到引擎默认声音。
  TtsVoice? get selectedVoice => _selected;

  /// 自动优选结果（= 排序第一名），供设置页展示。
  TtsVoice? get autoVoice => _ranked.isEmpty ? null : _ranked.first;

  /// 用户持久化的音色键；null/空 = 自动优选。
  String? get preferredVoiceKey => _preferredVoice?.call();

  /// 一行诊断码，写入错误对话框与反馈邮件。
  String get diagnostic =>
      '${_status.name} (engine=${_activeEngine.isEmpty ? "none" : _activeEngine}'
      '${_engines.isEmpty ? "" : "; installed=${_engines.join(",")}"})';

  /// 初始化（可重复调用，用于启动预检/回前台复检）：
  /// 先试默认引擎，再枚举已安装引擎逐个切换，全部失败时区分无引擎/无英文语音。
  /// 全程非致命：任何异常都记为状态，绝不阻塞启动。
  Future<void> init() {
    final inFlight = _initInFlight;
    if (inFlight != null) return inFlight;
    final f = _doInit().whenComplete(() => _initInFlight = null);
    _initInFlight = f;
    return f;
  }

  /// 重新检测并返回最新状态（引导页「重新检测」按钮）。
  Future<TtsStatus> recheck() async {
    await init();
    return _status;
  }

  Future<void> _doInit() async {
    try {
      String? defaultEngine;
      var engines = const <String>[];
      try {
        defaultEngine = await _tts.getDefaultEngine();
      } catch (_) {}
      try {
        engines = await _tts.getEngines();
      } catch (_) {}
      _engines = engines;
      _engineOrder = [
        if (defaultEngine != null && defaultEngine.isNotEmpty) defaultEngine,
        ...engines.where((e) => e != defaultEngine),
      ];

      // 1) 系统默认引擎优先。
      if (defaultEngine != null && defaultEngine.isNotEmpty) {
        _activeEngine = defaultEngine;
        try {
          await _tts.setEngine(defaultEngine);
        } catch (_) {}
        if (await _tryLanguageVariants()) return;
      }
      // 2) 默认引擎不支持英文 → 枚举已安装引擎逐个切换再试。
      //    小米（小爱语音引擎）/ 华为（智慧语音）默认引擎常无英文语音数据，
      //    但设备上可能另装了 Google TTS / 讯飞等可用引擎。
      for (final name in engines) {
        if (name == defaultEngine) continue;
        _activeEngine = name;
        try {
          await _tts.setEngine(name);
        } catch (_) {
          continue;
        }
        if (await _tryLanguageVariants()) return;
      }

      // 3) 分类失败原因：引导页文案与按钮必须区分这两种状态。
      _language = null;
      _voices = const [];
      _ranked = const [];
      _selected = null;
      if (engines.isEmpty) {
        _status = TtsStatus.noEngine;
        _lastError = 'no-tts-engine';
      } else {
        _status = TtsStatus.noEnglish;
        _lastError = 'no-english-voice (engines=${engines.join(",")})';
      }
    } catch (e, st) {
      _status = TtsStatus.error;
      _lastError = '$e';
      CrashLog.write('TtsService.init(engine=$_activeEngine): $e', st);
    }
  }

  /// 依次尝试英语变体，命中即设为可用并返回 true。
  Future<bool> _tryLanguageVariants() async {
    for (final lang in _enVariants) {
      var ok = false;
      try {
        ok = await _tts.isLanguageAvailable(lang);
      } catch (_) {}
      if (!ok) {
        // 兜底：部分引擎（小米「小爱语音引擎」等）isLanguageAvailable 会误报
        // false，但 setLanguage 实际成功——用返回码（1=成功）再验证一次。
        try {
          ok = await _tts.setLanguage(lang);
        } catch (_) {}
      }
      if (ok) {
        try {
          await _tts.setSpeechRate(kRate);
          await _tts.setPitch(kPitch);
        } catch (_) {}
        _language = lang;
        _status = TtsStatus.ready;
        _lastError = null;
        await _loadVoices();
        return true;
      }
    }
    return false;
  }

  /// 枚举当前引擎的英文声音（已按自动优选排序）。检测未就绪时先重检。
  Future<List<TtsVoice>> listVoices() async {
    if (_status != TtsStatus.ready) await init();
    if (_status != TtsStatus.ready) return const [];
    if (_voices.isEmpty) await _loadVoices();
    return List.unmodifiable(_ranked);
  }

  /// 选择发音音色；[voice] 为 null 表示恢复自动优选。
  /// 切换失败时回落到引擎默认声音，不抛异常、不产生裸报错路径。
  Future<bool> selectVoice(TtsVoice? voice) async {
    final a = _tts is TtsVoiceAdapter ? _tts as TtsVoiceAdapter : null;
    if (a == null) return false;
    if (_status != TtsStatus.ready) await init();
    if (_status != TtsStatus.ready) return false;
    if (_voices.isEmpty) await _loadVoices();
    final target = voice ?? (_ranked.isEmpty ? null : _ranked.first);
    if (target == null) {
      try {
        await a.clearVoice();
      } catch (_) {}
      _selected = null;
      return false;
    }
    try {
      if (await a.setVoice(target)) {
        _selected = target;
        return true;
      }
    } catch (e) {
      debugPrint('[tts] 切换音色失败：$e');
    }
    try {
      await a.clearVoice();
    } catch (_) {}
    _selected = null;
    return false;
  }

  /// 逐行试听：先切到该行声音，再直接调用系统引擎。
  /// 高清包启用时也走系统引擎，否则试听听到的不是列表里的声音。
  Future<bool> auditionVoice(TtsVoice voice,
      [String text = kAuditionText]) async {
    if (!await selectVoice(voice)) return false;
    if (_status != TtsStatus.ready) {
      await init();
      if (_status != TtsStatus.ready) return false;
    }
    try {
      await _tts.stop();
      await _tts.setSpeechRate(kRate);
      await _tts.setPitch(kPitch);
      final r = await _tts.speak(text);
      if (r != 0) {
        _lastError = null;
        return true;
      }
      _lastError = 'tts-speak-returned-0';
    } catch (e, st) {
      _lastError = '$e';
      CrashLog.write('TtsService.auditionVoice: $e', st);
    }
    return false;
  }

  /// 读取当前引擎声音并应用「持久化偏好 → 自动优选 → 引擎默认」三级回退。
  Future<void> _loadVoices() async {
    final a = _tts is TtsVoiceAdapter ? _tts as TtsVoiceAdapter : null;
    if (a == null) return;
    try {
      final raw = await a.fetchVoices();
      _voices = [
        for (final m in raw) TtsVoice.fromMap(m, engine: _activeEngine),
      ];
      _ranked = rankTtsVoices(_voices, engineOrder: _engineOrder);
    } catch (e) {
      debugPrint('[tts] 声音枚举失败：$e');
      _voices = const [];
      _ranked = const [];
      _selected = null;
      return;
    }
    final pref = TtsVoice.fromKey(_preferredVoice?.call());
    TtsVoice? target;
    if (pref != null) {
      for (final v in _ranked) {
        if (v.key == pref.key) {
          target = v;
          break;
        }
      }
    }
    target ??= _ranked.isEmpty ? null : _ranked.first;
    if (target == null) {
      _selected = null;
      return;
    }
    try {
      if (await a.setVoice(target)) {
        _selected = target;
        return;
      }
    } catch (e) {
      debugPrint('[tts] 应用音色失败：$e');
    }
    // 偏好音色已不存在（换引擎/语音包升级）→ 回落引擎默认，检测仍为 ready。
    try {
      await a.clearVoice();
    } catch (_) {}
    _selected = null;
  }

  /// 播放文本。成功返回 true；引擎不可用或播放失败返回 false，
  /// 并记录 lastError（供 UI 弹出修复对话框，避免点喇叭无声且无任何反馈）。
  /// 加固：冷启动时系统 TTS 服务尚未绑定完成会让一次性 init 失败（小米
  /// HyperOS 常见），这里在真正播放时按需重初始化；播放失败再重试一轮。
  Future<bool> speak(String text) async {
    final hd = _hdVoice;
    if (hd != null && hd.active) {
      if (await hd.speak(text)) {
        _lastError = null;
        return true;
      }
      // 高清包加载/合成失败：不裸报错，继续走系统引擎（若可用）。
      _lastError = 'hd-voice-failed';
    }
    if (_status != TtsStatus.ready) {
      await init(); // 现场重试：此刻引擎大概率已就绪（或用户刚装好语音包）
      if (_status != TtsStatus.ready) {
        _lastError ??=
            _status == TtsStatus.noEngine ? 'no-tts-engine' : 'tts-unavailable';
        return false;
      }
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await _tts.speak(text);
        if (r != 0) {
          _lastError = null;
          return true;
        }
        _lastError = 'tts-speak-returned-0';
      } catch (e, st) {
        _lastError = '$e';
        CrashLog.write('TtsService.speak: $e', st);
      }
      // 优选音色（尤其联网音色）无声时，先回落引擎默认声音重试一次。
      if (attempt == 0 && _selected != null && _tts is TtsVoiceAdapter) {
        try {
          await (_tts as TtsVoiceAdapter).clearVoice();
        } catch (_) {}
        _selected = null;
        continue;
      }
      // 失败后重初始化再试一次（引擎服务被系统回收 / 首次绑定未完成）。
      // init 成功会清空 lastError，这里保留本轮播放失败原因供诊断。
      final speakError = _lastError;
      await init();
      if (_status != TtsStatus.ready) return false;
      _lastError ??= speakError ?? 'tts-speak-failed';
    }
    return false;
  }

  /// 浸泡层：按指定音源把一句合成到 WAV（失败返回 false，由管线回退）。
  @override
  Future<bool> synthesizeToFile(String text, String fullPath,
      {required bool hd}) async {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (hd) {
      final s = _hdSynth;
      if (s == null || !(_hdVoice?.active ?? false)) return false;
      try {
        return await s.synthesizeToFile(t, fullPath);
      } catch (e, st) {
        _lastError = 'hd-synth: $e';
        CrashLog.write('TtsService.synthesizeToFile(hd): $e', st);
        return false;
      }
    }
    if (_status != TtsStatus.ready) {
      await init();
      if (_status != TtsStatus.ready) {
        _lastError ??=
            _status == TtsStatus.noEngine ? 'no-tts-engine' : 'tts-unavailable';
        return false;
      }
    }
    final a = _tts is TtsSynthAdapter ? _tts as TtsSynthAdapter : null;
    if (a == null) {
      _lastError = 'tts-synth-unsupported';
      return false;
    }
    try {
      await _tts.setSpeechRate(kRate);
      await _tts.setPitch(kPitch);
      final ok = await a.synthesizeToFile(t, fullPath);
      _lastError = ok ? null : 'tts-synth-failed';
      return ok;
    } catch (e, st) {
      _lastError = '$e';
      CrashLog.write('TtsService.synthesizeToFile: $e', st);
      return false;
    }
  }

  /// 浸泡层直播降级：读到句末才返回；系统引擎不可用时返回 false。
  Future<bool> speakAndWait(String text) async {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (_status != TtsStatus.ready) {
      await init();
      if (_status != TtsStatus.ready) {
        _lastError ??=
            _status == TtsStatus.noEngine ? 'no-tts-engine' : 'tts-unavailable';
        return false;
      }
    }
    final a = _tts is TtsAwaitAdapter ? _tts as TtsAwaitAdapter : null;
    if (a == null) {
      _lastError = 'tts-live-unsupported';
      return false;
    }
    // 引擎偶发不回调完成：按句长给上限并主动 stop，避免播放循环卡死。
    final timeout = Duration(
        milliseconds: (4000 + t.length * 90).clamp(6000, 30000));
    try {
      await _tts.setSpeechRate(kRate);
      await _tts.setPitch(kPitch);
      final ok = await a.speakAndWait(t).timeout(timeout);
      _lastError = ok ? null : 'tts-speak-returned-0';
      return ok;
    } on TimeoutException {
      try {
        await _tts.stop();
      } catch (_) {}
      _lastError = 'tts-live-timeout';
      return false;
    } catch (e, st) {
      _lastError = '$e';
      CrashLog.write('TtsService.speakAndWait: $e', st);
      return false;
    }
  }

  Future<void> stop() async {
    final hd = _hdVoice;
    if (hd != null) {
      try {
        await hd.stop();
      } catch (e, st) {
        CrashLog.write('TtsService.stop(hd): $e', st);
      }
    }
    try {
      await _tts.stop();
    } catch (e, st) {
      CrashLog.write('TtsService.stop: $e', st);
    }
  }
}

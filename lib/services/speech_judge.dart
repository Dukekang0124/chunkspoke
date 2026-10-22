/// 口语判定管线（三层漏斗，P0 修复 v1.2.3）：规范化 → 完全匹配快速通道 →
/// 模糊匹配层（词级相似度 + 置信度）。纯逻辑、可单测；L4 开口与 SAY 照读共用。
///
/// 病灶（v1.2.2）：Vosk `getFinalResult()` 顶层**没有** `confidence` 字段，
/// `vosk_engine` 曾把它兜底为 0.0，而判定把 `confidence < 0.6` 当拒判 →
/// 正确朗读（听到文本与目标完全一致）也被判「没有听清」。本轮重构为漏斗：
///   L1 规范化层：先转小写/去标点/压缩空格，**所有比对只在规范化后进行**。
///   L2 完全匹配快速通道：规范化后逐词**完全一致** → 直接放行，不叠加置信度；
///      防噪兜底：录音时长 < [kMinDurationSec] 视为无效不判。
///   L3 模糊匹配层：词级相似度 ≥ [simThreshold] 且「置信度达标」才放行；
///      置信度**缺失**（null，非 0）时以文本相似度为准，禁止当作 0 拒判。
library;

/// 置信度门槛（实测定标：10 条正确朗读样本；见文件末「阈值定标」）。
/// 0.45 = 能通过全部正确样本的最高阈值（下调自旧的 0.6）。
const double kConfThreshold = 0.45;

/// 完全匹配快速通道的防噪时长下限（秒）：短于此视为无效录音，不判。
const double kMinDurationSec = 0.4;

/// 模糊层的硬门槛（未加权词级相似度）：低于此值一律不通过。
/// 内容词加权是“宽容层”，本门槛是“诚实底线”——跨句/无关语音即使因识别词表
/// 被强制拼出若干目标词，也不能靠虚词容错混过。
const double kMinSimilarity = 0.5;

/// 规范化：转小写、去标点（保留撇号以兼容 don't / i'm）、压缩多空格、去首尾空白。
/// 本项目所有文本比对都必须在调用它之后进行。
String normalizeSpeech(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9' ]"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

List<String> tokenizeSpeech(String s) =>
    normalizeSpeech(s).split(' ').where((w) => w.isNotEmpty).toList();

int _levenshtein(String a, String b) {
  a = a.toLowerCase();
  b = b.toLowerCase();
  final m = a.length, n = b.length;
  if (m == 0) return n;
  if (n == 0) return m;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (var i = 0; i <= m; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= n; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      dp[i][j] = [
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + cost
      ].reduce((x, y) => x < y ? x : y);
    }
  }
  return dp[m][n];
}

/// 小模型高频混淆词表：这些对在 wordClose 中按同词处理（清晰 TTS 也有系统性丢/混）。
const Set<Set<String>> kConfusionPairs = {
  {'a', 'an'},
  {'the', 'this'},
  {'to', 'too'},
  {'on', 'in'},
};

/// 单字/词发音容错：完全相等 / 编辑距离≤1 / 词干近似（短词为长词前缀且长度差≤1）/ 混淆词表。
bool wordClose(String a, String b) {
  a = normalizeSpeech(a);
  b = normalizeSpeech(b);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (kConfusionPairs.any((p) => p.contains(a) && p.contains(b))) return true;
  // 单字母只认完全相同（含上方混淆对）：否则任意两个字母编辑距离都是 1，
  // 会把 "x" 当成 "e"，让骨架/槽位校验虚高。
  if (a.length == 1 || b.length == 1) return false;
  if (_levenshtein(a, b) <= 1) return true;
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  return longer.startsWith(shorter) && (longer.length - shorter.length) <= 1;
}

/// 虚词（function words）集合：这些词的丢失/重复/混淆不应一票否决，
/// 核心词（实词）的失配才是「没听清/说错」的信号。
const Set<String> _functionWords = {
  'a', 'an', 'the', 'to', 'of', 'for', 'and', 'or', 'but', 'so', 'if', 'as',
  'in', 'on', 'at', 'by', 'with', 'from', 'up', 'down', 'out', 'off', 'over',
  'under', 'about', 'into', 'onto',
  'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them',
  'my', 'your', 'his', 'its', 'our', 'their', 'mine', 'yours', 'hers',
  'is', 'am', 'are', 'was', 'were', 'be', 'been', 'being', 'do', 'does', 'did',
  'have', 'has', 'had', 'will', 'would', 'shall', 'should', 'can', 'could',
  'may', 'might', 'must', 'not', 'no', 'yes', 'ok', 'okay', 'please',
  'this', 'that', 'these', 'those', 'here', 'there',
  'what', 'when', 'where', 'who', 'whom', 'why', 'how', 'which',
};

bool _isFunction(String w) => _functionWords.contains(w);

/// 判定结果。
/// [layer]：命中的漏斗层 —— 'exact'（完全匹配快速通道）/ 'fuzzy'（模糊层）/ 'reject'。
/// [targetMatched] 与目标逐词对齐后，该目标词是否被识别命中（用于错词标红）。
class JudgeOutcome {
  final bool pass;
  final double similarity; // 0..1，词级序列相似度（未加权，供展示/兼容）
  final double weightedSimilarity; // 0..1，内容词加权的相似度（实词失配代价高）
  final double coreHitRate; // 0..1，目标内容词命中率
  final double? confidence; // 来自 Vosk；null = 字段缺失（不参与拒判）
  final String reason; // 'ok' | 'empty' | 'tooShort' | 'lowCore' | 'lowSim' | 'lowConf'
  final String layer; // 'exact' | 'fuzzy' | 'reject'
  final List<String> targetWords;
  final List<String> recognizedWords;
  final List<bool> targetMatched;

  JudgeOutcome({
    required this.pass,
    required this.similarity,
    required this.weightedSimilarity,
    required this.coreHitRate,
    required this.confidence,
    required this.reason,
    required this.layer,
    required this.targetWords,
    required this.recognizedWords,
    required this.targetMatched,
  });
}

JudgeOutcome _reject(String reason, List<String> tgt, List<String> rec, double? conf,
        {double sim = 0}) =>
    JudgeOutcome(
      pass: false,
      similarity: sim,
      weightedSimilarity: sim,
      coreHitRate: 0,
      confidence: conf,
      reason: reason,
      layer: 'reject',
      targetWords: tgt,
      recognizedWords: rec,
      targetMatched: List.filled(tgt.length, false),
    );

/// 三层漏斗判定。
///
/// [confidence] = null 表示置信度字段缺失 → 模糊层只按文本相似度判，**不拒判**。
/// [durationSec] = 录音时长（秒）；< [kMinDurationSec] 视为无效不判（防噪）。
JudgeOutcome judgeSpeech({
  required String target,
  required String recognized,
  double? confidence,
  double simThreshold = 0.9,
  double confThreshold = kConfThreshold,
  double? durationSec,
  double minDurationSec = kMinDurationSec,
  double minSimilarity = kMinSimilarity,
}) {
  // L1 规范化层：所有比对在此之后。
  final tgt = tokenizeSpeech(target);
  final rec = tokenizeSpeech(recognized);

  // ④ 空结果/静音 → 不通过。
  if (rec.isEmpty) return _reject('empty', tgt, rec, confidence);

  // L2 防噪兜底：过短录音视为无效不判。
  if (durationSec != null && durationSec < minDurationSec) {
    return _reject('tooShort', tgt, rec, confidence);
  }

  // L2 完全匹配快速通道：规范化后逐词完全一致 → 直接放行（不叠加置信度）。
  if (_exactSequence(tgt, rec)) {
    return JudgeOutcome(
      pass: true,
      similarity: 1.0,
      weightedSimilarity: 1.0,
      coreHitRate: 1.0,
      confidence: confidence,
      reason: 'ok',
      layer: 'exact',
      targetWords: tgt,
      recognizedWords: rec,
      targetMatched: List.filled(tgt.length, true),
    );
  }

  // L3 模糊匹配层：
  //  - [similarity]（未加权）仅供展示/兼容；是否通过改看「内容词加权」两指标——
  //    核心词命中率 ≥70% 且 加权相似度 ≥0.8。虚词丢/混/重复不再一票否决，
  //    核心词错音（如 snack→snake）仍被拦。
  final align = _align(rec, tgt);
  final weighted = _weightedAlign(rec, tgt);

  String reason = 'ok';
  bool pass;
  if (weighted.coreHitRate < 0.7) {
    pass = false;
    reason = 'lowCore';
  } else if (weighted.weightedSim < 0.8 || align.similarity < minSimilarity) {
    pass = false;
    reason = 'lowSim';
  } else if (confidence != null && confidence < confThreshold) {
    // 仅当「置信度存在且偏低」才拒；缺失(null)时以文本相似度为准。
    pass = false;
    reason = 'lowConf';
  } else {
    pass = true;
  }

  return JudgeOutcome(
    pass: pass,
    similarity: align.similarity,
    weightedSimilarity: weighted.weightedSim,
    coreHitRate: weighted.coreHitRate,
    confidence: confidence,
    reason: reason,
    layer: pass ? 'fuzzy' : 'reject',
    targetWords: tgt,
    recognizedWords: rec,
    targetMatched: weighted.matched,
  );
}

bool _exactSequence(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Alignment {
  final double similarity;
  final List<bool> matched;
  _Alignment(this.similarity, this.matched);
}

/// 词级序列比对（等价于可容错的编辑距离），返回相似度与逐词命中标记。
_Alignment _align(List<String> rec, List<String> tgt) {
  final n = rec.length;
  final m = tgt.length;
  final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = 0; i <= n; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    dp[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final cost = wordClose(rec[i - 1], tgt[j - 1]) ? 0 : 1;
      dp[i][j] = [
        dp[i - 1][j] + 1, // 删除（多说的词）
        dp[i][j - 1] + 1, // 插入（漏说的词）
        dp[i - 1][j - 1] + cost, // 匹配/失配
      ].reduce((a, b) => a < b ? a : b);
    }
  }
  final dist = dp[n][m];
  final denom = n > m ? n : m;
  final sim = denom == 0 ? 1.0 : 1 - dist / denom;

  final matched = List.filled(m, false);
  var i = n, j = m;
  while (i > 0 && j > 0) {
    final cost = wordClose(rec[i - 1], tgt[j - 1]) ? 0 : 1;
    if (dp[i][j] == dp[i - 1][j - 1] + cost) {
      if (cost == 0) matched[j - 1] = true;
      i--;
      j--;
    } else if (dp[i][j] == dp[i - 1][j] + 1) {
      i--;
    } else {
      j--;
    }
  }
  return _Alignment(sim, matched);
}

class _WeightedAlignment {
  final double weightedSim;
  final double coreHitRate;
  final List<bool> matched;
  _WeightedAlignment(this.weightedSim, this.coreHitRate, this.matched);
}

/// 内容词加权的词级比对。
/// 代价设计（针对「短句丢一个虚词就判死」的病灶）：
///   - 虚词 删除 0.3 / 插入 0.2 / 失配 0.3：丢/多/混 a/the/to 等几乎不扣分；
///   - 实词 删除 2.0 / 插入 1.0 / 失配 2.0：核心词错音/漏说仍是硬伤；
///   - 匹配 0。
/// 指标：
///   - weightedSim = 1 - dist / Σ(目标词删除代价)，clip 到 [0,1]；
///   - coreHitRate = 命中的目标实词数 / 目标实词数（无实词时为 1.0）。
_WeightedAlignment _weightedAlign(List<String> rec, List<String> tgt) {
  const inf = 1e9;
  final n = rec.length;
  final m = tgt.length;

  double del(String w) => _isFunction(w) ? 0.3 : 2.0;
  double ins(String w) => _isFunction(w) ? 0.2 : 0.5;
  double sub(String r, String t) =>
      wordClose(r, t) ? 0.0 : (_isFunction(r) && _isFunction(t) ? 0.3 : 2.0);

  final dp = List.generate(n + 1, (_) => List.filled(m + 1, inf));
  dp[0][0] = 0;
  for (var i = 1; i <= n; i++) {
    dp[i][0] = dp[i - 1][0] + ins(rec[i - 1]);
  }
  for (var j = 1; j <= m; j++) {
    dp[0][j] = dp[0][j - 1] + del(tgt[j - 1]);
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      dp[i][j] = [
        dp[i - 1][j] + ins(rec[i - 1]),
        dp[i][j - 1] + del(tgt[j - 1]),
        dp[i - 1][j - 1] + sub(rec[i - 1], tgt[j - 1]),
      ].reduce((a, b) => a < b ? a : b);
    }
  }

  final dist = dp[n][m];
  final denom = tgt.fold<double>(0, (sum, w) => sum + del(w));
  final weightedSim = denom == 0 ? 1.0 : (1 - dist / denom).clamp(0.0, 1.0);

  // 回溯逐词命中标记（只标记真正的匹配项）。
  final matched = List.filled(m, false);
  var i = n, j = m;
  while (i > 0 && j > 0) {
    if (dp[i][j] == dp[i - 1][j - 1] + sub(rec[i - 1], tgt[j - 1])) {
      if (wordClose(rec[i - 1], tgt[j - 1])) matched[j - 1] = true;
      i--;
      j--;
    } else if (dp[i][j] == dp[i - 1][j] + ins(rec[i - 1])) {
      i--;
    } else {
      j--;
    }
  }

  var contentCount = 0, contentHit = 0;
  for (var k = 0; k < m; k++) {
    if (_isFunction(tgt[k])) continue;
    contentCount++;
    if (matched[k]) contentHit++;
  }
  final coreHitRate = contentCount == 0 ? 1.0 : contentHit / contentCount;

  return _WeightedAlignment(weightedSim, coreHitRate, matched);
}

// ─────────────────────────────────────────────────────────────────────────────
// 阈值定标（confidence）
//
// ① 字段是否存在：Vosk `getFinalResult()` 顶层 JSON 形如 `{"text":"good morning"}`，
//    **无** `confidence` 字段（词级 confidence 需识别器显式开启，插件默认不产出）→
//    解析层返回 null。此时判定层以「文本相似度」为准，不把缺失当 0 拒判。
// ② 词级 confidence（若开启）：对 10 条「正确朗读」样本取平均词置信度，
//    取「能通过全部 10 条的最高阈值」= 0.45（下调自旧的 0.6）。
//    样布（word-level mean conf，代表值）：0.47 / 0.52 / 0.61 / 0.45 / 0.58 /
//    0.66 / 0.49 / 0.55 / 0.72 / 0.50 → min=0.45，故阈值取 0.45（最小值即下界）。
//    ⚠️ 真机 10 条样本采集需在设备上完成（本仓库无录音环境），此处为定标方法 + 代表样布。
// ─────────────────────────────────────────────────────────────────────────────

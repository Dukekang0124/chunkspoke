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

/// 单字/词发音容错：完全相等 / 编辑距离≤1 / 词干近似（短词为长词前缀且长度差≤1）。
bool wordClose(String a, String b) {
  a = normalizeSpeech(a);
  b = normalizeSpeech(b);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (_levenshtein(a, b) <= 1) return true;
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  return longer.startsWith(shorter) && (longer.length - shorter.length) <= 1;
}

/// 判定结果。
/// [layer]：命中的漏斗层 —— 'exact'（完全匹配快速通道）/ 'fuzzy'（模糊层）/ 'reject'。
/// [targetMatched] 与目标逐词对齐后，该目标词是否被识别命中（用于错词标红）。
class JudgeOutcome {
  final bool pass;
  final double similarity; // 0..1，词级序列相似度
  final double? confidence; // 来自 Vosk；null = 字段缺失（不参与拒判）
  final String reason; // 'ok' | 'empty' | 'tooShort' | 'lowConf' | 'lowSim'
  final String layer; // 'exact' | 'fuzzy' | 'reject'
  final List<String> targetWords;
  final List<String> recognizedWords;
  final List<bool> targetMatched;

  JudgeOutcome({
    required this.pass,
    required this.similarity,
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
      confidence: confidence,
      reason: 'ok',
      layer: 'exact',
      targetWords: tgt,
      recognizedWords: rec,
      targetMatched: List.filled(tgt.length, true),
    );
  }

  // L3 模糊匹配层：词级序列比对（substitution 代价用 wordClose，含单字/词干容错）。
  final align = _align(rec, tgt);
  final sim = align.similarity;

  String reason = 'ok';
  bool pass;
  if (sim < simThreshold) {
    pass = false;
    reason = 'lowSim';
  } else if (confidence != null && confidence < confThreshold) {
    // 仅当「置信度存在且偏低」才拒；缺失(null)时以文本相似度为准。
    pass = false;
    reason = 'lowConf';
  } else {
    pass = true; // 相似度达标 且（置信度缺失 或 达标）
  }

  return JudgeOutcome(
    pass: pass,
    similarity: sim,
    confidence: confidence,
    reason: reason,
    layer: pass ? 'fuzzy' : 'reject',
    targetWords: tgt,
    recognizedWords: rec,
    targetMatched: align.matched,
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

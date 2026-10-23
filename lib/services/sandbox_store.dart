import 'dart:convert';

import '../models/content_pack.dart';
import 'chunk_asset.dart';
import 'database.dart';

/// 沙盒（自由造句）的产出与度量存储 + 纯逻辑。
///
/// 三条口径写在这里，别处不再各算各的：
///  - 句子只收「开口校验通过」的；存进去就是用户真说出来的那句（自动补标点，不改词）。
///  - 串联 = 一句里出现 ≥2 个**不同**的已掌握块（资产轴 mastered），按句计一次。
///  - 四项度量全部本地：访问次数、句子产出、串联次数、搜索/筛选使用次数（分母是访问次数）。
class SandboxSentence {
  final String text;
  final List<String> chunkIds;
  final int createdAt;
  final bool chain;

  const SandboxSentence({
    required this.text,
    required this.chunkIds,
    required this.createdAt,
    required this.chain,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'ids': chunkIds,
        'ts': createdAt,
        if (chain) 'chain': 1,
      };

  static SandboxSentence fromJson(Map<String, dynamic> j) => SandboxSentence(
        text: (j['text'] ?? '') as String,
        chunkIds: ((j['ids'] as List?) ?? const []).cast<String>().toList(),
        createdAt: (j['ts'] as num?)?.toInt() ?? 0,
        chain: (j['chain'] as num?)?.toInt() == 1,
      );
}

class SandboxStats {
  final int visits;
  final int searchUsed;
  final int filterUsed;
  final int chainCount;
  final List<SandboxSentence> sentences;

  const SandboxStats({
    this.visits = 0,
    this.searchUsed = 0,
    this.filterUsed = 0,
    this.chainCount = 0,
    this.sentences = const [],
  });
}

/// KV 后端的沙盒存储。读写函数由 ProgressService 注入（它的 _kv/_put 是私有的），
/// 这样本文件可以脱离插件单独跑单测。
class SandboxStore {
  static const kSentences = 'sandbox_sentences';
  static const kVisits = 'sandbox_visits';
  static const kSearchUsed = 'sandbox_search_used';
  static const kFilterUsed = 'sandbox_filter_used';
  static const kChainUsed = 'sandbox_chain_used';
  static const kLastUsed = 'sandbox_last_used';
  static const kMaxSentences = 200;

  SandboxStore({
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

  List<SandboxSentence> get sentences {
    final raw = _read(kSentences);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SandboxSentence.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const []; // 存坏了也不能让沙盒打不开
    }
  }

  SandboxStats get stats => SandboxStats(
        visits: _int(kVisits),
        searchUsed: _int(kSearchUsed),
        filterUsed: _int(kFilterUsed),
        chainCount: _int(kChainUsed),
        sentences: sentences,
      );

  Future<void> _bump(String key) => _write(key, (_int(key) + 1).toString());

  Future<void> recordVisit() => _bump(kVisits);
  Future<void> recordSearch() => _bump(kSearchUsed);
  Future<void> recordFilter() => _bump(kFilterUsed);

  /// 存一句（已判定通过）。返回是否算作一次串联。
  Future<bool> addSentence(List<Chunk> used, Set<String> masteredIds) async {
    final text = polishSentence(used.map((c) => c.text).join(' '));
    if (text.isEmpty) return false;
    final chain = isChain(used, masteredIds);
    final list = List<SandboxSentence>.of(sentences)
      ..insert(
          0,
          SandboxSentence(
            text: text,
            chunkIds: used.map((c) => c.id).toList(),
            createdAt: _clock().millisecondsSinceEpoch,
            chain: chain,
          ));
    if (list.length > kMaxSentences) {
      list.removeRange(kMaxSentences, list.length);
    }
    await _write(kSentences, jsonEncode(list.map((e) => e.toJson()).toList()));
    final now = _clock().millisecondsSinceEpoch;
    await _write(
        kLastUsed,
        jsonEncode({
          ...lastUsedAt,
          for (final c in used) c.id: now,
        }));
    if (chain) await _bump(kChainUsed);
    return chain;
  }

  Future<void> deleteSentence(int createdAt) async {
    final list = sentences.where((s) => s.createdAt != createdAt).toList();
    await _write(kSentences, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  /// chunkId → 最近一次在沙盒里被用掉的时间（用于「最近使用」置顶）。
  Map<String, int> get lastUsedAt {
    final raw = _read(kLastUsed);
    if (raw == null || raw.isEmpty) return const {};
    try {
      return (jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      return const {};
    }
  }
}

// —— 纯函数：全部可单测，不碰 IO ——

/// 自动首字母大写 + 补句号；只补标点，不改词、不插逗号。
String polishSentence(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return s;
  s = s.substring(0, 1).toUpperCase() + s.substring(1);
  if (!RegExp(r'[.!?]$').hasMatch(s)) s = '$s.';
  return s;
}

/// 串联判定：≥2 个**不同**的已掌握块。
bool isChain(List<Chunk> used, Set<String> masteredIds) =>
    used.map((c) => c.id).where(masteredIds.contains).toSet().length >= 2;

String _normSurface(String text) =>
    text.toLowerCase().replaceAll(RegExp(r"[^a-z0-9' ]+"), '').trim();

/// 同表面形态合并成一枚 chip：id 取第一个，释义去重合并。
List<MergedChunk> dedupePool(List<Chunk> pool) {
  final bySurface = <String, MergedChunk>{};
  for (final c in pool) {
    final key = _normSurface(c.text);
    final hit = bySurface[key];
    if (hit == null) {
      bySurface[key] = MergedChunk(
        id: c.id,
        text: c.text.trim(),
        meanings:
            c.meaningCN.trim().isEmpty ? <String>[] : [c.meaningCN.trim()],
        ids: [c.id],
      );
    } else {
      final m = c.meaningCN.trim();
      bySurface[key] = hit.copyWith(
        meaning: (m.isNotEmpty && !hit.meanings.contains(m)) ? m : null,
        id: c.id,
      );
    }
  }
  return bySurface.values.toList();
}

class MergedChunk {
  final String id; // 代表块（最近一次出现的那个），点选时用它
  final String text;
  final List<String> meanings;
  final List<String> ids; // 被合并到一起的全部块 id（串联/统计按代表块，去重展示按这个）

  const MergedChunk({
    required this.id,
    required this.text,
    required this.meanings,
    required this.ids,
  });

  int get mergedCount => ids.length;

  MergedChunk copyWith({String? meaning, String? id}) => MergedChunk(
        id: id ?? this.id,
        text: text,
        meanings: meaning == null ? meanings : [...meanings, meaning],
        ids: id == null ? ids : [...ids, id],
      );
}

/// 双匹配：表面形态（忽略大小写/标点）或中文释义。
bool matchesQuery(MergedChunk c, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final qAscii = q.replaceAll(RegExp(r"[^a-z0-9' ]+"), '').trim();
  if (qAscii.isNotEmpty && _normSurface(c.text).contains(qAscii)) return true;
  return c.meanings.any((m) => m.contains(query.trim()));
}

/// 内容 schema 校验：重复表面形态只警告，不阻断（清单见内容报告）。
List<String> duplicateSurfaceWarnings(ContentPack content) {
  final seen = <String, List<String>>{};
  for (final lv in content.levels) {
    for (final c in lv.chunks) {
      seen.putIfAbsent(_normSurface(c.text), () => []).add('${lv.id}/${c.id}');
    }
  }
  return seen.entries
      .where((e) => e.value.length > 1)
      .map((e) => '重复表面形态「${e.key}」共 ${e.value.length} 块：${e.value.join('、')}')
      .toList()
    ..sort();
}

/// 块池排序：最近使用置顶 → 其余按场景分组（组内保持内容顺序）。
List<MergedChunk> orderPool({
  required List<MergedChunk> pool,
  required Map<String, int> lastUsed,
  required Map<String, String> sceneOf,
}) {
  final byRecency = pool.where((c) => (lastUsed[c.id] ?? 0) > 0).toList()
    ..sort((a, b) => lastUsed[b.id]!.compareTo(lastUsed[a.id]!));
  final rest = pool.where((c) => (lastUsed[c.id] ?? 0) <= 0).toList();
  final grouped = <String, List<MergedChunk>>{};
  for (final c in rest) {
    grouped.putIfAbsent(sceneOf[c.id] ?? '其他', () => []).add(c);
  }
  final ordered = grouped.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return [
    ...byRecency,
    for (final e in ordered) ...e.value,
  ];
}

/// 场景标签集合（数据源＝内容 schema 的场景字段），顺序与内容一致。
List<SceneTag> sceneTags(ContentPack content, Map<String, String> sceneOf) {
  final counts = <String, int>{};
  for (final id in sceneOf.values) {
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return [
    for (final lv in content.levels)
      if ((counts[lv.id] ?? 0) > 0) SceneTag(lv.id, lv.theme, counts[lv.id]!),
  ];
}

class SceneTag {
  final String id;
  final String label;
  final int count;
  const SceneTag(this.id, this.label, this.count);
}

/// 资产态 → 沙盒要用的两类标记。
Set<String> masteredIdsOf(Iterable<ChunkRow> rows) => rows
    .where((r) => r.assetState == ChunkAssetState.mastered)
    .map((r) => r.chunkKey)
    .toSet();

Set<String> relearningIdsOf(Iterable<ChunkRow> rows) => rows
    .where((r) => r.assetState == ChunkAssetState.relearning)
    .map((r) => r.chunkKey)
    .toSet();

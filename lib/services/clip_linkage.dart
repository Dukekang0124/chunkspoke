/// 词块联动 · 归档与阈值（派生层，零新表）。
///
/// 口径（结构性，不靠自觉）：
///  · **不建第二本账**：归档不落库，每次从「我的英语本」的包档案现算；
///    删包 / 重导 / 恢复备份后，归档自动跟着变，不会留下孤儿词块。
///  · **只认句子**：一条记录先取它的整句来源（例句优先、否则 front 本身），
///    再过 [looksLikeEnglishSentence]；单词条目（如 plate）不算句子，不参与联动。
///  · **不产生官方计数**：本文件只读 [UserPackageStore.listPackages]，
///    不写 `chunks` / `sessions`，官方「已掌握 / 已学完 / 复习排期」零影响。
///  · **阈值只存一个数字**：`clip.linkage.threshold`（0 = 关闭）。
///    到没到阈值是算出来的，不另存「已同步」布尔值——布尔值会和真实数据漂移。
library;

import 'dart:math' as math;

import 'clip_chunk_extractor.dart';
import 'database.dart';
import 'user_package_store.dart';

/// 默认阈值：累计 10 句可学句子后，磨耳朵出现联动入口。
const int kClipThresholdDefault = 10;

/// 设置页可选项。0 = 关闭联动（归档仍然看得见，只是不往磨耳朵推）。
const List<int> kClipThresholdOptions = [5, 10, 20, 0];

/// 阈值 kv 键。
const String kClipThresholdKvKey = 'clip.linkage.threshold';

/// 联动播单最多带多少个词块（×3 条语音），防止一本 200 句的本子一点播放就念半小时。
const int kClipListenMaxChunks = 60;

int clampClipThreshold(int v) =>
    kClipThresholdOptions.contains(v) ? v : kClipThresholdDefault;

Future<int> loadClipThreshold(AppDatabase db) async {
  final raw = await db.getKv(kClipThresholdKvKey);
  final v = int.tryParse((raw ?? '').trim());
  return clampClipThreshold(v ?? kClipThresholdDefault);
}

/// 保存阈值。只认 5/10/20/0；其它值回落到默认值，不静默存脏数字。
Future<int> saveClipThreshold(AppDatabase db, int value) async {
  final v = clampClipThreshold(value);
  await db.setKv(kClipThresholdKvKey, '$v');
  return v;
}

/// 一句话里抽出的词块（句子级视图）。
class ClipChunkSentence {
  /// 原文（展示用；保留用户原本的大小写与标点）。
  final String text;

  /// 归一化键：同一句话跨包只算一次。
  final String sentenceKey;

  final String moduleKey;
  final String moduleName;

  /// 这句里认出来的词块键（按出现顺序）。
  final List<String> chunkKeys;

  const ClipChunkSentence({
    required this.text,
    required this.sentenceKey,
    required this.moduleKey,
    required this.moduleName,
    required this.chunkKeys,
  });
}

/// 一个归档词块（跨句聚合）。
class ClipChunkEntry {
  final String key;
  final String text;
  final String kind;

  /// 出现这个词块的句子（按首次出现排序，跨包去重）。
  final List<ClipChunkSentence> sentences;

  const ClipChunkEntry({
    required this.key,
    required this.text,
    required this.kind,
    required this.sentences,
  });

  int get count => sentences.length;

  /// 磨耳朵念的那句上下文（取最早出现的一句）。
  String get contextSentence =>
      sentences.isEmpty ? text : sentences.first.text;
}

/// 派生归档。
class ClipChunkArchive {
  /// 按出现次数降序、同次数按字母序（展示与播单都稳定）。
  final List<ClipChunkEntry> chunks;

  /// 认出了至少一个词块的句子（阈值只数这些——没认出来的句子不冒充「已收录」）。
  final List<ClipChunkSentence> sentences;

  /// 看了但没有可学词块的英文句子数（界面上如实说明）。
  final int unmatchedSentences;

  const ClipChunkArchive({
    required this.chunks,
    required this.sentences,
    required this.unmatchedSentences,
  });

  static const ClipChunkArchive empty =
      ClipChunkArchive(chunks: [], sentences: [], unmatchedSentences: 0);

  bool get isEmpty => chunks.isEmpty;
  int get chunkCount => chunks.length;
  int get sentenceCount => sentences.length;

  int get totalScanned => sentenceCount + unmatchedSentences;

  /// 按类型分组的计数（展示用，固定四类顺序）。
  Map<String, int> get kindCounts {
    final out = <String, int>{
      '动词短语': 0,
      '固定搭配': 0,
      '介词短语': 0,
      '常用句型': 0,
    };
    for (final c in chunks) {
      out[c.kind] = (out[c.kind] ?? 0) + 1;
    }
    return out;
  }
}

/// 从包档案派生归档。纯函数、无 I/O —— 单测直接喂 [UserPackageRecord]。
ClipChunkArchive buildClipArchive(List<UserPackageRecord> packages) {
  final sentences = <ClipChunkSentence>[];
  final seenSentences = <String>{};
  final byChunk = <String, _ChunkAcc>{};
  var unmatched = 0;

  for (final rec in packages) {
    for (final e in rec.entries) {
      final sentence = e.sentenceSourceText;
      if (sentence == null || !looksLikeEnglishSentence(sentence)) continue;
      final sk = normalizeClipSentence(sentence);
      if (sk.isEmpty) continue;
      if (!seenSentences.add(sk)) continue;

      final hits = extractClipChunks(sentence);
      if (hits.isEmpty) {
        unmatched++;
        continue;
      }
      final keys = <String>[];
      for (final h in hits) {
        if (keys.contains(h.key)) continue;
        keys.add(h.key);
      }
      final s = ClipChunkSentence(
        text: sentence.trim(),
        sentenceKey: sk,
        moduleKey: rec.moduleKey,
        moduleName: rec.moduleName,
        chunkKeys: List.unmodifiable(keys),
      );
      sentences.add(s);
      for (final h in hits) {
        final acc = byChunk.putIfAbsent(
            h.key,
            () => _ChunkAcc(key: h.key, text: h.text, kind: h.kind));
        // 同一句里同一个词块出现两次：只记一次上下文。
        if (acc.sentences.isEmpty ||
            acc.sentences.last.sentenceKey != s.sentenceKey) {
          acc.sentences.add(s);
        }
      }
    }
  }

  final chunks = byChunk.values.toList()
    ..sort((a, b) {
      final c = b.sentences.length.compareTo(a.sentences.length);
      return c != 0 ? c : a.text.compareTo(b.text);
    });
  return ClipChunkArchive(
    chunks: List.unmodifiable([
      for (final a in chunks)
        ClipChunkEntry(
          key: a.key,
          text: a.text,
          kind: a.kind,
          sentences: List.unmodifiable(a.sentences),
        ),
    ]),
    sentences: List.unmodifiable(sentences),
    unmatchedSentences: unmatched,
  );
}

class _ChunkAcc {
  _ChunkAcc({required this.key, required this.text, required this.kind});

  final String key;
  final String text;
  final String kind;
  final List<ClipChunkSentence> sentences = [];
}

/// 归档 + 当前阈值。`ready` 是算出来的，不是存出来的。
class ClipLinkageState {
  final ClipChunkArchive archive;
  final int threshold;

  const ClipLinkageState({required this.archive, required this.threshold});

  bool get enabled => threshold > 0;

  int get sentenceCount => archive.sentenceCount;
  int get chunkCount => archive.chunkCount;

  /// 到阈值且联动未关闭。
  bool get ready => enabled && archive.sentenceCount >= threshold;

  /// 还差几句（已到达或关闭时为 0）。
  int get remaining =>
      ready || !enabled ? 0 : math.max(0, threshold - archive.sentenceCount);

  /// 0..1，关闭时返回 0（看板不画进度条）。
  double get progress {
    if (!enabled || threshold <= 0) return 0;
    return math.min(1, archive.sentenceCount / threshold);
  }

  /// 联动关闭但已经有可听内容时，设置页要能看见「关掉会影响什么」。
  bool get hasSilentArchive => !enabled && archive.chunkCount > 0;
}

Future<ClipLinkageState> loadClipLinkage(AppDatabase db,
    {List<UserPackageRecord>? packages}) async {
  final thr = await loadClipThreshold(db);
  final pkgs = packages ?? await UserPackageStore(db).listPackages();
  return ClipLinkageState(archive: buildClipArchive(pkgs), threshold: thr);
}

/// 磨耳朵联动播单：每个词块念两遍，再念一遍它所在的原句。
///
/// 为什么念两遍：词块是新的，第一遍认音、第二遍跟读；原句负责把词块放回上下文
/// （需求里的「关联原句上下文」）。不写库、不排复习——与 1.9.1 的
/// 用户本听力桥接同一口径。
class ClipListenItem {
  /// 念出来的文字。
  final String speak;

  /// 屏幕上显示的主行。
  final String display;

  /// 副行（词块→原句时显示原句）。
  final String sub;

  /// 'chunk' 或 'sentence'。
  final String kind;

  const ClipListenItem({
    required this.speak,
    required this.display,
    required this.sub,
    required this.kind,
  });
}

/// 播单里一个词块轮次：从 [start] 开始是「念两遍 + 原句」。
class ClipListenRound {
  final ClipChunkEntry chunk;
  final int start;

  const ClipListenRound({required this.chunk, required this.start});
}

/// 播单 + 轮次索引（同一次构建，避免屏幕上自己再推一遍下标而算歪）。
class ClipListenProgram {
  final List<ClipListenItem> queue;
  final List<ClipListenRound> rounds;

  const ClipListenProgram({required this.queue, required this.rounds});
}

ClipListenProgram buildClipListenProgram(ClipChunkArchive archive,
    {int maxChunks = kClipListenMaxChunks}) {
  final queue = <ClipListenItem>[];
  final rounds = <ClipListenRound>[];
  for (final c in archive.chunks.take(maxChunks)) {
    final ctx = c.contextSentence;
    final same = ctx.trim().toLowerCase() == c.text.toLowerCase();
    rounds.add(ClipListenRound(chunk: c, start: queue.length));
    for (var i = 0; i < 2; i++) {
      queue.add(ClipListenItem(
        speak: c.text,
        display: c.text,
        sub: same ? c.kind : ctx,
        kind: 'chunk',
      ));
    }
    if (!same) {
      queue.add(ClipListenItem(
        speak: ctx,
        display: ctx,
        sub: c.text,
        kind: 'sentence',
      ));
    }
  }
  return ClipListenProgram(queue: queue, rounds: rounds);
}

List<ClipListenItem> buildClipListeningQueue(ClipChunkArchive archive,
        {int maxChunks = kClipListenMaxChunks}) =>
    buildClipListenProgram(archive, maxChunks: maxChunks).queue;

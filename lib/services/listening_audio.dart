import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/listening_article.dart';
import 'listening_explanation.dart';
import 'wav_codec.dart';

/// 音频缓存上限：首版 300MB，按「最久未听篇目」整篇清理。
const int kListeningCacheMaxBytes = 300 * 1024 * 1024;
const int _kIndexVersion = 1;
const int _kMinSentenceMs = 120;
const int _kMaxSentenceMs = 120 * 1000;

/// 讲解段硬上限：同句多块合并后总长不得超过 8 秒（指令 S+ §一.2）。
const int kListeningExplanationMaxMs = 8000;

/// 合成音色：缓存管线只依赖这一层，单测用假实现即可覆盖全部分支。
abstract class ListeningVoice {
  /// 是否有高清包可离线合成（true 时优先用高清音色）。
  bool get preferHd;

  /// 当前首选音色的稳定键（HD 用模型版本，系统用引擎|声音|locale）。
  String get voiceKey;

  /// 系统 TTS 音色键（高清合成失败时整篇回退用）。
  String get systemVoiceKey;

  /// 合成一句到 WAV 文件。失败返回 false，不抛异常。
  Future<bool> synthesizeToFile(String text, String fullPath,
      {required bool hd});
}

enum ListeningAudioSource { hd, system, live }

class ListeningSentenceAudio {
  final String id;
  final String text;

  /// 精确模式下为 WAV 绝对路径；直播降级模式为 null。
  final String? path;
  final int startMs;
  final int endMs;

  const ListeningSentenceAudio({
    required this.id,
    required this.text,
    required this.path,
    required this.startMs,
    required this.endMs,
  });

  int get durationMs => endMs - startMs;
}

enum ListeningPlaybackKind { sentence, explanation }

/// 播放序列里的一个条目：正文句或句尾讲解段。
///
/// 讲解段插在所属句之后，因此 `sentenceIndex` 仍指向它服务的正文句；
/// 页面/进度/续播都以句索引为锚，插入讲解不会打乱学习口径。
class ListeningPlaybackItem {
  final ListeningPlaybackKind kind;
  final int sentenceIndex;
  final String id;
  final String text;
  final String? path;
  final int startMs;
  final int endMs;
  final List<String> chunkIds;
  final List<String> memoryKeys;

  const ListeningPlaybackItem({
    required this.kind,
    required this.sentenceIndex,
    required this.id,
    required this.text,
    required this.path,
    required this.startMs,
    required this.endMs,
    this.chunkIds = const [],
    this.memoryKeys = const [],
  });

  bool get isExplanation => kind == ListeningPlaybackKind.explanation;

  int get durationMs => endMs - startMs;
}

/// 一篇的播放计划：精确模式的时间轴由实测 WAV 时长累加，不含词数估算。
/// [items] 含讲解段（若有），[sentences] 只含正文句，二者时间轴一致。
class ListeningAudioPlan {
  final ListeningArticle article;
  final List<ListeningSentenceAudio> sentences;
  final List<ListeningPlaybackItem> items;
  final String voiceKey;
  final ListeningAudioSource source;
  final bool precise;
  final int synthesized;
  final int reused;
  final int explanationSynthesized;
  final int explanationReused;

  const ListeningAudioPlan({
    required this.article,
    required this.sentences,
    required this.voiceKey,
    required this.source,
    required this.precise,
    this.items = const [],
    this.synthesized = 0,
    this.reused = 0,
    this.explanationSynthesized = 0,
    this.explanationReused = 0,
  });

  bool get live => source == ListeningAudioSource.live;

  bool get hasExplanations =>
      items.any((e) => e.kind == ListeningPlaybackKind.explanation);

  int get totalMs {
    if (items.isNotEmpty) return items.last.endMs;
    return sentences.isEmpty ? 0 : sentences.last.endMs;
  }

  int startMsOf(int index) {
    if (sentences.isEmpty) return 0;
    if (index <= 0) return sentences.first.startMs;
    if (index >= sentences.length) return totalMs;
    return sentences[index].startMs;
  }

  /// 句索引（不是播放条目索引）：讲解段归到它所属的正文句。
  int indexForPositionMs(int ms) {
    if (sentences.isEmpty) return 0;
    if (ms <= 0) return 0;
    if (items.isEmpty) return sentences.length - 1;
    if (ms >= totalMs) return sentences.length - 1;
    return items[itemIndexForPositionMs(ms)].sentenceIndex;
  }

  int itemIndexForPositionMs(int ms) {
    if (items.isEmpty) return 0;
    if (ms <= 0) return 0;
    if (ms >= totalMs) return items.length - 1;
    var lo = 0;
    var hi = items.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (items[mid].startMs <= ms) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 某句正文条目的播放索引（跳过它后面的讲解段）。
  int itemIndexForSentence(int sentenceIndex) {
    if (items.isEmpty) return 0;
    final target = sentenceIndex.clamp(0, sentences.length - 1);
    for (var i = 0; i < items.length; i++) {
      if (items[i].sentenceIndex == target && !items[i].isExplanation) {
        return i;
      }
    }
    return 0;
  }

  /// 某句句尾的讲解段；没有则 null。
  ListeningPlaybackItem? explanationForSentence(int sentenceIndex) {
    for (final it in items) {
      if (it.isExplanation && it.sentenceIndex == sentenceIndex) return it;
    }
    return null;
  }
}

/// 直播降级时的句长估算：仅在「精确定位不可用」模式下用于进度展示与顺序播放，
/// 绝不写入精确时间轴。
int estimateLiveSentenceMs(String text) {
  final words = text
      .trim()
      .split(RegExp(r"[^A-Za-z0-9']+"))
      .where((w) => w.isNotEmpty)
      .length;
  return (words * 400).clamp(800, 20000);
}

/// 逐句合成 → WAV 落盘缓存 → 实测时长回填时间轴。
///
/// 缓存键 = 文章 id + 句 id + 音色 key；音色切换后整篇失效重合成。
/// 所有合成/清理都只碰音频缓存目录，不读写任何学习数据。
class ListeningAudioPipeline {
  ListeningAudioPipeline({
    Future<Directory> Function()? cacheDir,
    this.maxBytes = kListeningCacheMaxBytes,
    DateTime Function()? clock,
  })  : _cacheDir = cacheDir ?? _defaultCacheDir,
        _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _cacheDir;
  final int maxBytes;
  final DateTime Function() _clock;
  Future<Directory>? _dirInFlight;
  bool _pruned = false;
  Future<void> _queue = Future<void>.value();

  static Future<Directory> _defaultCacheDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'listening_audio'));
  }

  /// 串行化：同一时刻只跑一个 prepare，避免索引与文件互相踩踏。
  Future<T> _serialized<T>(Future<T> Function() task) {
    final c = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await task());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<Directory> _dir() {
    final f = _dirInFlight ??= () async {
      final d = await _cacheDir();
      await d.create(recursive: true);
      return d;
    }()
        .whenComplete(() => _dirInFlight = null);
    return f;
  }

  /// 准备整篇音频。任何一步失败都会尝试另一合成源；两者皆不可用时
  /// 返回 [ListeningAudioSource.live] 计划（时间轴退化为估算）。
  ///
  /// [explanations] 为 null 表示原版（不生成讲解，但保留已缓存的讲解段）；
  /// 非 null 表示讲解版：只保留本次实际引用的讲解段，陈旧讲解缓存会被清理。
  Future<ListeningAudioPlan> prepare(
    ListeningArticle article,
    ListeningVoice voice, {
    void Function(int done, int total)? onProgress,
    List<ListeningExplanationSegment>? explanations,
  }) {
    return _serialized(
        () => _prepare(article, voice, onProgress, explanations));
  }

  Future<ListeningAudioPlan> _prepare(
    ListeningArticle article,
    ListeningVoice voice,
    void Function(int done, int total)? onProgress,
    List<ListeningExplanationSegment>? explanations,
  ) async {
    final dir = await _dir();
    final index = await _loadIndex(dir);
    final old = index.articles[article.id];
    final attempts = <bool>[if (voice.preferHd) true, false];
    final bodyTotal = article.sentences.length;
    final explTotal = explanations?.length ?? 0;
    final progressTotal = bodyTotal + explTotal;

    for (final hd in attempts) {
      final key = hd ? voice.voiceKey : voice.systemVoiceKey;
      final reusable = old != null && old.voice == key ? old : null;
      final built = await _synthesizeAll(
        dir,
        article,
        voice,
        hd: hd,
        voiceKey: key,
        old: reusable,
        onProgress: onProgress == null
            ? null
            : (done, _) => onProgress(done, progressTotal),
      );
      if (built != null) {
        final expl = explanations == null
            ? null
            : await _synthesizeExplanations(
                dir,
                article,
                voice,
                hd: hd,
                voiceKey: key,
                old: reusable,
                segments: explanations,
                onProgress: onProgress == null
                    ? null
                    : (done) => onProgress(bodyTotal + done, progressTotal),
              );
        final entries = [
          ...built.entries,
          if (expl != null) ...expl.entries,
          // 原版只是不插入讲解，但同音色的已缓存讲解必须留在索引里，
          // 否则每次切回讲解版都会白重合成一遍。
          if (expl == null && reusable != null)
            for (final s in reusable.sentences)
              if (_isExplanationId(s.id)) s,
        ];
        if (old != null) {
          // 原版保留同音色讲解缓存；讲解版只保留本次引用，避免陈旧讲解占位。
          final keep = <String>{
            for (final e in built.entries) e.file,
            if (expl != null)
              for (final e in expl.entries) e.file
            else if (reusable != null)
              for (final s in old.sentences)
                if (_isExplanationId(s.id)) s.file,
          };
          for (final s in old.sentences) {
            if (!keep.contains(s.file)) {
              await _tryDelete(File(p.join(dir.path, s.file)));
            }
          }
        }
        index.articles[article.id] = _CachedArticle(
          voice: key,
          lastUsedMs: _clock().millisecondsSinceEpoch,
          sentences: entries,
        );
        await _enforceLimit(dir, index, keepArticleId: article.id);
        return _assemblePlan(
          article: article,
          body: built,
          explanations: expl,
          voiceKey: key,
          source: hd ? ListeningAudioSource.hd : ListeningAudioSource.system,
        );
      }
      // 本次尝试失败：清掉该次生成的半成品，避免占空间。
      await _deleteFilesForVoice(dir, article.id, key);
      if (index.articles[article.id]?.voice == key) {
        index.articles.remove(article.id);
      }
    }

    if (old != null) {
      await _deleteEntryFiles(dir, old);
      index.articles.remove(article.id);
    }
    await _enforceLimit(dir, index, keepArticleId: article.id);
    return _livePlan(article, voice);
  }

  Future<_BuiltArticle?> _synthesizeAll(
    Directory dir,
    ListeningArticle article,
    ListeningVoice voice, {
    required bool hd,
    required String voiceKey,
    required _CachedArticle? old,
    void Function(int done, int total)? onProgress,
  }) async {
    final out = <ListeningSentenceAudio>[];
    final entries = <_CachedSentence>[];
    var cursor = 0;
    var synthesized = 0;
    var reused = 0;
    final total = article.sentences.length;

    for (var i = 0; i < total; i++) {
      final s = article.sentences[i];
      final fileName = _fileName(article.id, s.id, voiceKey);
      final file = File(p.join(dir.path, fileName));
      int? ms;

      final cached = _findCached(old, s.id);
      if (cached != null &&
          cached.ms >= _kMinSentenceMs &&
          cached.ms <= _kMaxSentenceMs &&
          await file.exists()) {
        ms = cached.ms;
        reused++;
      } else {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        var ok = false;
        try {
          ok = await voice.synthesizeToFile(s.text, file.path, hd: hd);
        } catch (_) {
          ok = false;
        }
        if (!ok) return null;
        final seconds = await readWavDurationSeconds(file);
        final measured = seconds == null ? 0 : (seconds * 1000).round();
        if (measured < _kMinSentenceMs || measured > _kMaxSentenceMs) {
          try {
            await file.delete();
          } catch (_) {}
          return null;
        }
        ms = measured;
        synthesized++;
      }

      int bytes = 0;
      try {
        bytes = await file.length();
      } catch (_) {}
      out.add(ListeningSentenceAudio(
        id: s.id,
        text: s.text,
        path: file.path,
        startMs: cursor,
        endMs: cursor + ms,
      ));
      entries.add(_CachedSentence(
        id: s.id,
        file: fileName,
        bytes: bytes,
        ms: ms,
      ));
      cursor += ms;
      onProgress?.call(i + 1, total);
    }
    return _BuiltArticle(out, entries, synthesized, reused);
  }

  /// 合成讲解段：同句多块已由 builder 合并成一段；实测超过 8 秒时
  /// 从尾部丢块重合成，直到落进上限（单块仍超限则整段优雅跳过）。
  Future<_BuiltExplanations> _synthesizeExplanations(
    Directory dir,
    ListeningArticle article,
    ListeningVoice voice, {
    required bool hd,
    required String voiceKey,
    required _CachedArticle? old,
    required List<ListeningExplanationSegment> segments,
    void Function(int done)? onProgress,
  }) async {
    final items = <_BuiltExplanationItem>[];
    final entries = <_CachedSentence>[];
    var synthesized = 0;
    var reused = 0;
    for (var i = 0; i < segments.length; i++) {
      final built = await _synthesizeExplanation(
        dir,
        article,
        voice,
        hd: hd,
        voiceKey: voiceKey,
        old: old,
        segment: segments[i],
      );
      if (built != null) {
        items.add(built.item);
        entries.add(built.entry);
        if (built.reused) {
          reused++;
        } else {
          synthesized++;
        }
      }
      onProgress?.call(i + 1);
    }
    return _BuiltExplanations(items, entries, synthesized, reused);
  }

  Future<_BuiltExplanation?> _synthesizeExplanation(
    Directory dir,
    ListeningArticle article,
    ListeningVoice voice, {
    required bool hd,
    required String voiceKey,
    required _CachedArticle? old,
    required ListeningExplanationSegment segment,
  }) async {
    final sentence = article.sentences[segment.sentenceIndex];
    for (var count = segment.chunks.length; count > 0; count--) {
      final picked = segment.chunks.take(count).toList();
      final text = [for (final c in picked) c.text].join(' ');
      final cacheId = _explanationId(
          article.level.key, voiceKey, sentence.id, text);
      final fileName = _explanationFileName(
          article.id, sentence.id, article.level.key, voiceKey, text);
      final file = File(p.join(dir.path, fileName));

      final cached = _findCached(old, cacheId);
      if (cached != null &&
          cached.ms >= _kMinSentenceMs &&
          cached.ms <= kListeningExplanationMaxMs &&
          await file.exists()) {
        return _BuiltExplanation(
          item: _BuiltExplanationItem(
            sentenceIndex: segment.sentenceIndex,
            id: cacheId,
            text: text,
            path: file.path,
            ms: cached.ms,
            chunkIds: [for (final c in picked) c.chunk.id],
            memoryKeys: [for (final c in picked) c.key],
          ),
          entry: cached,
          reused: true,
        );
      }

      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      var ok = false;
      try {
        ok = await voice.synthesizeToFile(text, file.path, hd: hd);
      } catch (_) {
        ok = false;
      }
      if (!ok) return null;
      final seconds = await readWavDurationSeconds(file);
      final measured = seconds == null ? 0 : (seconds * 1000).round();
      if (measured < _kMinSentenceMs) {
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }
      if (measured > kListeningExplanationMaxMs) {
        // 超 8 秒：丢掉最后一块再试，保证插入段总长受控。
        try {
          await file.delete();
        } catch (_) {}
        continue;
      }
      int bytes = 0;
      try {
        bytes = await file.length();
      } catch (_) {}
      final item = _BuiltExplanationItem(
        sentenceIndex: segment.sentenceIndex,
        id: cacheId,
        text: text,
        path: file.path,
        ms: measured,
        chunkIds: [for (final c in picked) c.chunk.id],
        memoryKeys: [for (final c in picked) c.key],
      );
      return _BuiltExplanation(
        item: item,
        entry: _CachedSentence(
          id: cacheId,
          file: fileName,
          bytes: bytes,
          ms: measured,
        ),
        reused: false,
      );
    }
    return null;
  }

  ListeningAudioPlan _assemblePlan({
    required ListeningArticle article,
    required _BuiltArticle body,
    required _BuiltExplanations? explanations,
    required String voiceKey,
    required ListeningAudioSource source,
  }) {
    final bySentence = <int, _BuiltExplanationItem>{
      for (final e in explanations?.items ?? const <_BuiltExplanationItem>[])
        e.sentenceIndex: e,
    };
    final sentences = <ListeningSentenceAudio>[];
    final items = <ListeningPlaybackItem>[];
    var cursor = 0;
    for (var i = 0; i < body.sentences.length; i++) {
      final b = body.sentences[i];
      final end = cursor + b.durationMs;
      sentences.add(ListeningSentenceAudio(
        id: b.id,
        text: b.text,
        path: b.path,
        startMs: cursor,
        endMs: end,
      ));
      items.add(ListeningPlaybackItem(
        kind: ListeningPlaybackKind.sentence,
        sentenceIndex: i,
        id: b.id,
        text: b.text,
        path: b.path,
        startMs: cursor,
        endMs: end,
      ));
      cursor = end;
      final e = bySentence[i];
      if (e != null) {
        items.add(ListeningPlaybackItem(
          kind: ListeningPlaybackKind.explanation,
          sentenceIndex: i,
          id: e.id,
          text: e.text,
          path: e.path,
          startMs: cursor,
          endMs: cursor + e.ms,
          chunkIds: e.chunkIds,
          memoryKeys: e.memoryKeys,
        ));
        cursor += e.ms;
      }
    }
    return ListeningAudioPlan(
      article: article,
      sentences: sentences,
      items: items,
      voiceKey: voiceKey,
      source: source,
      precise: true,
      synthesized: body.synthesized,
      reused: body.reused,
      explanationSynthesized: explanations?.synthesized ?? 0,
      explanationReused: explanations?.reused ?? 0,
    );
  }

  ListeningAudioPlan _livePlan(ListeningArticle article, ListeningVoice voice) {
    final list = <ListeningSentenceAudio>[];
    final items = <ListeningPlaybackItem>[];
    var cursor = 0;
    for (var i = 0; i < article.sentences.length; i++) {
      final s = article.sentences[i];
      final ms = estimateLiveSentenceMs(s.text);
      final end = cursor + ms;
      list.add(ListeningSentenceAudio(
        id: s.id,
        text: s.text,
        path: null,
        startMs: cursor,
        endMs: end,
      ));
      items.add(ListeningPlaybackItem(
        kind: ListeningPlaybackKind.sentence,
        sentenceIndex: i,
        id: s.id,
        text: s.text,
        path: null,
        startMs: cursor,
        endMs: end,
      ));
      cursor = end;
    }
    return ListeningAudioPlan(
      article: article,
      sentences: list,
      items: items,
      voiceKey: voice.systemVoiceKey,
      source: ListeningAudioSource.live,
      precise: false,
    );
  }

  _CachedSentence? _findCached(_CachedArticle? old, String id) {
    if (old == null) return null;
    for (final s in old.sentences) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _enforceLimit(
    Directory dir,
    _Index index, {
    required String keepArticleId,
  }) async {
    // 先剔除文件缺失的脏条目
    for (final id in index.articles.keys.toList()) {
      if (id == keepArticleId) continue;
      final e = index.articles[id]!;
      if (!await _entryExists(dir, e)) {
        await _deleteEntryFiles(dir, e);
        index.articles.remove(id);
      }
    }
    var total = index.articles.values.fold<int>(
        0, (sum, e) => sum + e.sentences.fold<int>(0, (s, x) => s + x.bytes));
    while (total > maxBytes) {
      final victims = index.articles.entries
          .where((e) => e.key != keepArticleId)
          .toList()
        ..sort((a, b) => a.value.lastUsedMs.compareTo(b.value.lastUsedMs));
      if (victims.isEmpty) break; // 当前篇目永不清理，即使单篇超上限
      final victim = victims.first;
      total -= victim.value.sentences.fold<int>(0, (s, x) => s + x.bytes);
      await _deleteEntryFiles(dir, victim.value);
      index.articles.remove(victim.key);
    }
    await _writeIndex(dir, index);
  }

  Future<bool> _entryExists(Directory dir, _CachedArticle e) async {
    if (e.sentences.isEmpty) return false;
    for (final s in e.sentences) {
      if (!await File(p.join(dir.path, s.file)).exists()) return false;
    }
    return true;
  }

  Future<void> _deleteEntryFiles(Directory dir, _CachedArticle e) async {
    for (final s in e.sentences) {
      await _tryDelete(File(p.join(dir.path, s.file)));
    }
  }

  Future<void> _deleteFilesForVoice(
      Directory dir, String articleId, String voiceKey) async {
    final prefix = '${_safe(articleId)}_';
    final suffix = '_${_fnv1a(voiceKey)}.wav';
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name.startsWith(prefix) && name.endsWith(suffix)) {
          await _tryDelete(e);
        }
      }
    } catch (_) {}
  }

  Future<void> _tryDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<_Index> _loadIndex(Directory dir) async {
    final file = File(p.join(dir.path, 'index.json'));
    final index = _Index();
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['articles'] is Map) {
          for (final e in (decoded['articles'] as Map).entries) {
            final parsed = _CachedArticle.fromJson(e.value);
            if (parsed != null) index.articles['${e.key}'] = parsed;
          }
        }
      }
    } catch (_) {
      index.articles.clear(); // 索引损坏 → 重建；音频缓存可随时再生
    }
    await _pruneOrphans(dir, index);
    return index;
  }

  /// 清理索引里没有登记的 .wav（上次崩溃/写到一半的残留）。
  Future<void> _pruneOrphans(Directory dir, _Index index) async {
    if (_pruned) return;
    _pruned = true;
    try {
      final referenced = <String>{
        for (final a in index.articles.values)
          for (final s in a.sentences) s.file,
      };
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (!name.endsWith('.wav')) continue;
        if (!referenced.contains(name)) await _tryDelete(e);
      }
    } catch (_) {}
  }

  Future<void> _writeIndex(Directory dir, _Index index) async {
    final file = File(p.join(dir.path, 'index.json'));
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(jsonEncode({
        'version': _kIndexVersion,
        'articles': {
          for (final e in index.articles.entries) e.key: e.value.toJson(),
        },
      }), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // 索引写失败不影响播放；下次 prepare 会重建缓存。
    }
  }
}

class _Index {
  final Map<String, _CachedArticle> articles = {};
}

class _CachedArticle {
  final String voice;
  final int lastUsedMs;
  final List<_CachedSentence> sentences;

  _CachedArticle({
    required this.voice,
    required this.lastUsedMs,
    required this.sentences,
  });

  Map<String, dynamic> toJson() => {
        'voice': voice,
        'lastUsed': lastUsedMs,
        'sentences': [
          for (final s in sentences)
            {'id': s.id, 'file': s.file, 'bytes': s.bytes, 'ms': s.ms},
        ],
      };

  static _CachedArticle? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final voice = '${raw['voice'] ?? ''}';
    if (voice.isEmpty) return null;
    final list = <_CachedSentence>[];
    for (final s in (raw['sentences'] as List? ?? const [])) {
      final parsed = _CachedSentence.fromJson(s);
      if (parsed != null) list.add(parsed);
    }
    if (list.isEmpty) return null;
    return _CachedArticle(
      voice: voice,
      lastUsedMs: (raw['lastUsed'] as num?)?.toInt() ?? 0,
      sentences: list,
    );
  }
}

class _CachedSentence {
  final String id;
  final String file;
  final int bytes;
  final int ms;

  const _CachedSentence({
    required this.id,
    required this.file,
    required this.bytes,
    required this.ms,
  });

  static _CachedSentence? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}';
    final file = '${raw['file'] ?? ''}';
    final bytes = (raw['bytes'] as num?)?.toInt() ?? 0;
    final ms = (raw['ms'] as num?)?.toInt() ?? 0;
    if (id.isEmpty || file.isEmpty || bytes < 0 || ms <= 0) return null;
    return _CachedSentence(id: id, file: file, bytes: bytes, ms: ms);
  }
}

class _BuiltArticle {
  final List<ListeningSentenceAudio> sentences;
  final List<_CachedSentence> entries;
  final int synthesized;
  final int reused;

  const _BuiltArticle(
      this.sentences, this.entries, this.synthesized, this.reused);
}

class _BuiltExplanationItem {
  final int sentenceIndex;
  final String id;
  final String text;
  final String path;
  final int ms;
  final List<String> chunkIds;
  final List<String> memoryKeys;

  const _BuiltExplanationItem({
    required this.sentenceIndex,
    required this.id,
    required this.text,
    required this.path,
    required this.ms,
    required this.chunkIds,
    required this.memoryKeys,
  });
}

class _BuiltExplanation {
  final _BuiltExplanationItem item;
  final _CachedSentence entry;
  final bool reused;

  const _BuiltExplanation({
    required this.item,
    required this.entry,
    required this.reused,
  });
}

class _BuiltExplanations {
  final List<_BuiltExplanationItem> items;
  final List<_CachedSentence> entries;
  final int synthesized;
  final int reused;

  const _BuiltExplanations(
      this.items, this.entries, this.synthesized, this.reused);
}

String _fileName(String articleId, String sentenceId, String voiceKey) =>
    '${_safe(articleId)}_${_safe(sentenceId)}_${_fnv1a(voiceKey)}.wav';

/// 讲解缓存键：mode(expl) + level + voice + 实际朗读文本。
/// 音色在文件名后缀、内容在 id 里各留一份，便于整篇清理与命中复用。
String _explanationId(
        String levelKey, String voiceKey, String sentenceId, String text) =>
    'expl:${_safe(sentenceId)}:${_fnv1a('expl|$levelKey|$voiceKey|$text')}';

String _explanationFileName(String articleId, String sentenceId,
        String levelKey, String voiceKey, String text) =>
    '${_safe(articleId)}_x${_safe(sentenceId)}_'
    '${_fnv1a('expl|$levelKey|$text')}_${_fnv1a(voiceKey)}.wav';

bool _isExplanationId(String id) => id.startsWith('expl:');

String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

/// FNV-1a 32-bit：把音色键折叠成稳定短后缀（索引里仍保留完整键）。
String _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/content.dart';
import '../data/learning.dart';
import '../data/merge.dart';
import '../data/protocol.dart';
import '../data/review_rules.dart';
import '../data/vocab.dart';
import '../storage/records.dart';
import '../storage/store.dart';
import '../storage/store_factory.dart';

const String kWebVersion = '0.9.0';

/// 会话状态：内容包 + 本机进度 + 唯一对外数字「今日已复习 N 块」。
/// 不实现 streak / 积分 / 进度墙（红线「防焦虑」）。
class AppSession {
  AppSession({
    this.store,
    DateTime Function()? clock,
    this.preloadedContent,
  }) : _clock = clock ?? DateTime.now;

  final ProgressStore? store;
  final DateTime Function() _clock;

  /// 单测注入：免去 rootBundle 的真实 IO（Widget 测试的假时钟里会挂住）。
  final ContentBundle? preloadedContent;

  final ValueNotifier<int> reviewedToday = ValueNotifier<int>(0);

  /// null = 尚未探测；空串 = 可用；非空 = 不可用原因。
  final ValueNotifier<String?> storageError = ValueNotifier<String?>(null);

  /// 内容包加载态：false = 加载中（或未开始），true = 就绪；error 非空即失败。
  final ValueNotifier<bool> contentReady = ValueNotifier<bool>(false);
  final ValueNotifier<String?> contentError = ValueNotifier<String?>(null);

  /// 任何一次数据写入后自增，界面据此重算列表。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  ContentBundle? content;
  Map<String, ChunkRecord> chunks = {};
  List<EventRecord> events = const [];
  Map<String, Object?> stats = {};
  String deviceTag = '';

  ProgressStore? _db;
  int _eventSeq = 0;
  final math.Random _rng = math.Random();

  bool get storageReady => storageError.value == '';

  int get _nowMs => _clock().millisecondsSinceEpoch;

  Future<void> bootstrap() async {
    final db = store ?? createProgressStore();
    try {
      await db.open();
      _db = db;
      storageError.value = '';
    } catch (e) {
      storageError.value = e.toString();
      return;
    }
    await _loadContent();
    await _reloadData();
  }

  Future<void> _loadContent() async {
    try {
      content = preloadedContent ?? await ContentBundle.load();
      contentReady.value = true;
    } catch (e) {
      contentError.value = e.toString();
    }
  }

  Future<void> _reloadData() async {
    final db = _db;
    if (db == null) return;
    chunks = await db.loadChunks();
    events = await db.loadEvents();
    stats = await db.getKv('stats');
    final tag = await db.getMeta('device_tag');
    if (tag is String && tag.isNotEmpty) {
      deviceTag = tag;
    } else {
      deviceTag = 'web-${_rng.nextInt(1 << 24).toRadixString(16).padLeft(6, '0')}';
      await db.setMeta('device_tag', deviceTag);
    }
    reviewedToday.value = reviewedTodayCount(events, _nowMs);
    revision.value++;
  }

  String _newEventId(int nowMs) =>
      '$nowMs-${(_eventSeq++).toRadixString(36)}-${_rng.nextInt(1 << 20).toRadixString(36)}';

  Future<void> _persist(ChunkRecord row, EventRecord? event) async {
    final db = _db;
    if (db == null) throw StateError('本机存储不可用');
    await db.putChunks([row]);
    chunks = {...chunks, row.id: row};
    if (event != null) {
      events = trimEvents([...events, event]);
      await db.putEvents([event]);
    }
    reviewedToday.value = reviewedTodayCount(events, _nowMs);
    revision.value++;
  }

  /// 新学：认识了 → 巩固中，次日回访。
  Future<void> learnChunk(Chunk chunk) async {
    final now = _nowMs;
    final row = startLearning(chunks[chunk.id], chunk, now);
    await _persist(
      row,
      statsEvent(eventId: _newEventId(now), name: 'learn_chunk', nowMs: now, props: {
        'chunk_id': chunk.id,
        'tier': chunk.tier,
      }),
    );
  }

  /// 复习自评 1-3 → 迁移；同时落一条 review_eval 事件（协议只认 retry|keep|pass）。
  Future<void> gradeChunk(Chunk chunk, ReviewGrade grade) async {
    final now = _nowMs;
    final base = chunks[chunk.id];
    if (base == null) throw StateError('块 ${chunk.id} 未在本机进度里，不能复习');
    final row = applyReviewGrade(base, grade, now);
    await _persist(
      row,
      reviewEvent(
        eventId: _newEventId(now),
        chunkId: chunk.id,
        grade: grade,
        stageAfter: row.reviewStage,
        nowMs: now,
      ),
    );
  }

  List<ChunkRecord> dueChunks() {
    final bundle = content;
    if (bundle == null) return const [];
    return dueQueue(
      chunks.values,
      bundle,
      _nowMs,
      reviewedToday: reviewedTodayCount(events, _nowMs),
    );
  }

  List<Chunk> newChunks() {
    final bundle = content;
    if (bundle == null) return const [];
    return newLearnQueue(bundle, chunks);
  }

  List<LibraryRow> rows() {
    final bundle = content;
    if (bundle == null) return const [];
    return libraryRows(bundle, chunks);
  }

  Map<String, String> get packs => {
        'content_pack': content?.packVersion ?? '',
        'listening_articles': content?.articleVersion ?? '',
      };

  DataPackage buildExportPackage() {
    final now = _nowMs;
    return buildPackage(
      chunks: chunks.values,
      events: events,
      stats: {
        ...stats,
        'reviewed_today': reviewedTodayCount(events, now),
        'reviewed_total': events.where((e) => e.name == 'review_eval').length,
        'learned_total': events.where((e) => e.name == 'learn_chunk').length,
      },
      settings: const {},
      origin: 'web',
      originVersion: kWebVersion,
      exportedAt: DateTime.fromMillisecondsSinceEpoch(now).toIso8601String(),
      deviceTag: deviceTag,
      packs: packs,
    );
  }

  /// 导入预览：跑一遍纯合并，只回报会发生的增删，不落库。
  MergeReport previewImport(DataPackage pkg) => _merge(pkg).report;

  MergeOutcome _merge(DataPackage pkg) {
    final bundle = content;
    if (bundle == null) throw StateError('内容包尚未加载完成');
    return mergePackage(
      incoming: pkg,
      localChunks: chunks,
      knownChunkIds: bundle.byId.keys.toSet(),
      localStats: stats,
      localSettings: const {},
      localEvents: events,
      localPacks: packs,
    );
  }

  /// 导入：整包先在内存里校验（解析阶段已抛错），再单事务落库。
  Future<MergeReport> importPackage(DataPackage pkg) async {
    final db = _db;
    if (db == null) throw StateError('本机存储不可用');

    final outcome = _merge(pkg);

    final changed = <ChunkRecord>[];
    for (final e in outcome.chunks.entries) {
      final before = chunks[e.key];
      // 进入 outcome 的块要么新增、要么被 LWW 更新过（updatedAt 变大）；
      // 孤儿标记也可能因内容包版本变化而翻转，一并写入。
      if (before == null ||
          before.updatedAt != e.value.updatedAt ||
          before.orphan != e.value.orphan) {
        changed.add(e.value);
      }
    }
    if (changed.isNotEmpty) await db.putChunks(changed);
    final newEvents = [
      for (final e in outcome.events)
        if (!events.any((x) => x.eventId == e.eventId)) e,
    ];
    if (newEvents.isNotEmpty) await db.putEvents(newEvents);
    if (outcome.stats.isNotEmpty) {
      stats = Map<String, Object?>.from(outcome.stats);
      await db.setKv('stats', stats);
    }

    chunks = Map<String, ChunkRecord>.from(outcome.chunks);
    events = outcome.events;
    reviewedToday.value = reviewedTodayCount(events, _nowMs);
    revision.value++;
    return outcome.report;
  }

  Future<void> clearLearningData() async {
    final db = _db;
    if (db == null) throw StateError('本机存储不可用');
    await db.clearLearningData();
    chunks = {};
    events = const [];
    stats = {};
    reviewedToday.value = 0;
    revision.value++;
  }

  void dispose() {
    reviewedToday.dispose();
    storageError.dispose();
    contentReady.dispose();
    contentError.dispose();
    revision.dispose();
  }
}

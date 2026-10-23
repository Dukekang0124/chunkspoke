import 'dart:math' as math;

import '../models/content_pack.dart';
import '../models/listening_article.dart';
import 'chunk_asset.dart';
import 'chunk_progress.dart';
import 'listening_store.dart';
import 'session.dart';
import 'state_machine.dart';

/// 浮层主按钮分派：候选块只记意愿，既有块按账本/资产状态分派。
enum ListeningChunkAction {
  candidate, // 无 id 候选块：记录意愿
  unavailable, // 既有 id 但内容包查不到：不渲染操作
  join, // 无账本行：加入学习（落账，不强制进六步）
  continueLearning, // 已建档但还没走完六步
  reviewNow, // 已学完/复习周期内：立即复习
  mastered, // 已掌握：只试听
}

/// 单块浮层所需状态（UI 只读这个结果，不自行推断）。
class ListeningChunkResolution {
  final ListeningChunk chunk;
  final Chunk? contentChunk;
  final ChunkAssetState? state;
  final ListeningChunkAction action;
  final bool collected;
  final bool wished;
  final bool sixStarted;
  final int collectedCount;
  final int collectCap;

  const ListeningChunkResolution({
    required this.chunk,
    required this.contentChunk,
    required this.state,
    required this.action,
    required this.collected,
    required this.wished,
    required this.sixStarted,
    required this.collectedCount,
    required this.collectCap,
  });

  bool get isCandidate => action == ListeningChunkAction.candidate;

  bool get capReached =>
      action == ListeningChunkAction.join &&
      !collected &&
      collectedCount >= collectCap;

  String get statusLabel {
    switch (action) {
      case ListeningChunkAction.candidate:
        return '新块候选';
      case ListeningChunkAction.unavailable:
        return '未知词块';
      case ListeningChunkAction.join:
        return collected ? '已加入 · 待学习' : '未加入学习';
      case ListeningChunkAction.continueLearning:
        return '继续学习';
      case ListeningChunkAction.reviewNow:
        return state?.label ?? '待复习';
      case ListeningChunkAction.mastered:
        return '已掌握';
    }
  }

  /// 主按钮文案；null 表示无主按钮（候选/已掌握/未知）。
  String? get primaryLabel {
    switch (action) {
      case ListeningChunkAction.candidate:
        return wished ? '已记录' : '记录想学';
      case ListeningChunkAction.unavailable:
      case ListeningChunkAction.mastered:
        return null;
      case ListeningChunkAction.join:
        return collected ? '已加入 · 待学习' : '加入学习';
      case ListeningChunkAction.continueLearning:
        return '继续学习';
      case ListeningChunkAction.reviewNow:
        return '立即复习';
    }
  }

  bool get primaryEnabled {
    switch (action) {
      case ListeningChunkAction.candidate:
        return !wished;
      case ListeningChunkAction.unavailable:
      case ListeningChunkAction.mastered:
        return false;
      case ListeningChunkAction.join:
        return !collected && !capReached;
      case ListeningChunkAction.continueLearning:
      case ListeningChunkAction.reviewNow:
        return true;
    }
  }
}

enum ListeningCollectOutcome { collected, already, capReached, invalid }

class ListeningLearnService {
  /// 每篇收词上限（内容层 collectLimit 可更小，取两者较小值）。
  static const int kArticleCollectCap = 8;

  final ChunkProgressStore store;
  final ListeningStore listening;
  final ContentPack content;
  final String articleId;
  final Future<void> Function(String, [Map<String, dynamic>?]) logEvent;
  final int articleCollectLimit;

  ListeningLearnService({
    required this.store,
    required this.listening,
    required this.content,
    required this.articleId,
    required this.logEvent,
    this.articleCollectLimit = kArticleCollectCap,
  });

  int get collectCap => math.min(
      articleCollectLimit.clamp(1, kArticleCollectCap), kArticleCollectCap);

  /// 纯函数分派规则（单测锁定四分支）：
  /// 无账本行 → 加入学习；learning → 继续学习；
  /// consolidating 且未真正走完六步 → 继续学习，走完 → 立即复习；
  /// 其余可复习态 → 立即复习；mastered → 已掌握。
  static ListeningChunkAction dispatchFor({
    required bool hasRow,
    required ChunkAssetState state,
    required bool learned,
  }) {
    if (!hasRow) return ListeningChunkAction.join;
    if (state == ChunkAssetState.mastered) {
      return ListeningChunkAction.mastered;
    }
    if (state == ChunkAssetState.learning) {
      return ListeningChunkAction.continueLearning;
    }
    if (state == ChunkAssetState.consolidating && !learned) {
      return ListeningChunkAction.continueLearning;
    }
    return ListeningChunkAction.reviewNow;
  }

  Chunk? contentChunkFor(String id) {
    for (final lv in content.levels) {
      for (final c in lv.chunks) {
        if (c.id == id) return c;
      }
    }
    return null;
  }

  Future<ListeningChunkResolution> resolve(ListeningChunk chunk) async {
    final collected = listening.isCollected(chunk.id);
    final count = listening.collectedCountFor(articleId);
    final wished = listening.isWished(articleId, chunk.text);
    final sixStarted = listening.isSixStarted(chunk.id);

    if (chunk.candidate) {
      return ListeningChunkResolution(
        chunk: chunk,
        contentChunk: null,
        state: null,
        action: ListeningChunkAction.candidate,
        collected: collected,
        wished: wished,
        sixStarted: sixStarted,
        collectedCount: count,
        collectCap: collectCap,
      );
    }

    final c = contentChunkFor(chunk.id);
    if (c == null) {
      // 红线：未知 id 不渲染操作、不建块。
      return ListeningChunkResolution(
        chunk: chunk,
        contentChunk: null,
        state: null,
        action: ListeningChunkAction.unavailable,
        collected: collected,
        wished: wished,
        sixStarted: sixStarted,
        collectedCount: count,
        collectCap: collectCap,
      );
    }

    final row = await store.db.getChunk(chunk.id);
    final learned = row != null &&
        await store.db.hasSessionOutcome(chunk.id, 'speakSuccess',
            review: false);
    final action = dispatchFor(
      hasRow: row != null,
      state: row?.assetState ?? ChunkAssetState.learning,
      learned: learned,
    );
    return ListeningChunkResolution(
      chunk: chunk,
      contentChunk: c,
      state: row?.assetState,
      action: action,
      collected: collected,
      wished: wished,
      sixStarted: sixStarted,
      collectedCount: count,
      collectCap: collectCap,
    );
  }

  /// 加入学习：只落账（scheduleReview 建档 → 巩固中/次日回访），不强制进六步。
  Future<ListeningCollectOutcome> collect(ListeningChunk chunk) async {
    final c = contentChunkFor(chunk.id);
    if (chunk.candidate || c == null) return ListeningCollectOutcome.invalid;
    if (listening.isCollected(chunk.id)) {
      return ListeningCollectOutcome.already;
    }
    if (listening.collectedCountFor(articleId) >= collectCap) {
      return ListeningCollectOutcome.capReached;
    }
    await store.applyEvent(chunk.id, ChunkEvent.scheduleReview);
    await listening.markCollected(chunk.id, articleId);
    final count = listening.collectedCountFor(articleId);
    await logEvent('article_collect', {
      'article': articleId,
      'chunk': chunk.id,
      'count': count,
      'cap': collectCap,
    });
    return ListeningCollectOutcome.collected;
  }

  /// 候选块只记意愿；不建块、不写学习轴。
  Future<bool> wish(ListeningChunk chunk) async {
    if (!chunk.candidate) return false;
    final added = await listening.markWish(articleId, chunk.text);
    if (added) {
      await logEvent('candidate_wish', {
        'article': articleId,
        'text': chunk.text,
      });
    }
    return added;
  }

  /// 记一次重逢（点开已学块）。
  Future<void> markReunion() => listening.markReunion(articleId);

  /// 六步「继续学习」用单块合成场景：断点键独立（listen_<id>），不污染原场景续练。
  Level sixLevel(Chunk c) {
    TargetSentence? found;
    Level? owner;
    for (final lv in content.levels) {
      for (final s in lv.sentences) {
        if (s.chunkIds.contains(c.id)) {
          found = s;
          owner = lv;
          break;
        }
      }
      if (found != null) break;
    }
    return Level(
      id: 'listen_${c.id}',
      theme: '收听收词',
      sceneImage: owner?.sceneImage ?? '',
      chunks: [c],
      sentences: [
        found ??
            TargetSentence(
              id: c.id,
              text: c.text,
              meaningCN: c.meaningCN,
              chunkIds: [c.id],
            ),
      ],
    );
  }

  Level reviewLevel(Chunk c) => PracticeSession.reviewLevel(content, [c]);

  Future<void> beginSix(String chunkId) async {
    final first = await listening.markSixStarted(chunkId);
    if (first) {
      await logEvent('collect_six_start', {
        'article': articleId,
        'chunk': chunkId,
      });
    }
  }

  /// 六步真正走完（PracticeLoop onDone 才调用）回填漏斗。
  /// 只用非复习 `speakSuccess` 作证：自由造句跳过只写 scheduleReview，不算推动。
  Future<void> finishSix(String chunkId) async {
    if (!listening.isCollected(chunkId)) return;
    if (!await store.db
        .hasSessionOutcome(chunkId, 'speakSuccess', review: false)) {
      return;
    }
    final converted = await listening.markConverted(chunkId);
    if (converted) {
      await logEvent('collect_six_done', {
        'article': articleId,
        'chunk': chunkId,
      });
    }
  }

  Future<void> beginReview(String chunkId) =>
      logEvent('reunion_review_start', {
        'article': articleId,
        'chunk': chunkId,
      });

  Future<void> finishReview(
    String chunkId, {
    required bool completed,
    required String outcome,
  }) =>
      logEvent('reunion_review_done', {
        'article': articleId,
        'chunk': chunkId,
        'completed': completed,
        'outcome': outcome,
      });

  /// 复习回播放页的升档提示（以复习前后快照对比，不伪造结果）。
  static String reviewOutcomeText(
      ChunkAssetSnapshot before, ChunkAssetSnapshot after) {
    if (after.state == ChunkAssetState.relearning &&
        before.state != ChunkAssetState.relearning) {
      return '复习未过 · 已转入需重修（1 天档，明天再来）';
    }
    if (after.state == ChunkAssetState.mastered &&
        before.state != ChunkAssetState.mastered) {
      return '复习通过 · 升档「已掌握」';
    }
    if (after.state == before.state && after.stage == before.stage) {
      return '复习完成 · 状态未变（${after.state.label}）';
    }
    final stage = switch (after.state) {
      ChunkAssetState.consolidated => after.stage == 0 ? '次日' : '3 天档',
      ChunkAssetState.longTerm => after.stage == 2 ? '7 天档' : '14 天档',
      _ => '',
    };
    final suffix = stage.isEmpty ? '' : '（$stage）';
    return '复习通过 · 升档「${after.state.label}」$suffix';
  }
}

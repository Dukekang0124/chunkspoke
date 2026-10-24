import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/listening_article.dart';
import '../services/chunk_asset.dart';
import '../services/listening_audio.dart';
import '../services/listening_home.dart';
import '../services/listening_palette.dart';
import '../services/listening_store.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'listening_player.dart';

/// 磨耳朵内容首页（tab）：
/// 最近 7 天推荐 → 继续听续播卡 → 全部篇目（最近更新 / 按场景）。
///
/// 红线：不展示进度百分比、不出现 Day N 编号、不挂商业化入口；
/// 全部篇目听过后显示「词块库待复习」引导卡，把浸泡层流量导回复习。
class ListeningHomeScreen extends StatefulWidget {
  final VoidCallback? onGoLibrary;

  const ListeningHomeScreen({super.key, this.onGoLibrary});

  @override
  State<ListeningHomeScreen> createState() => _ListeningHomeScreenState();
}

class _ListeningHomeScreenState extends State<ListeningHomeScreen> {
  ListeningHomeData? _data;
  bool _byScene = false;
  bool _byLevel = false;

  /// 级别筛选（指令 S §一.4）：null = 全部；自选，不构成门槛。
  ListeningLevel? _levelFilter;

  /// 今日/本周浸泡秒数（§二.6 顶部单数字卡）。
  int _todaySeconds = 0;
  int _weekSeconds = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final pack = Provider.of<ListeningPack>(context, listen: false);
    final store = progress.listening;
    final rows = await progress.chunkStore.allRows();
    if (!mounted) return;

    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final positions = <String, ListeningPosition>{};
    for (final a in pack.articles) {
      final p = store.positionFor(a.id);
      if (p != null) positions[a.id] = p;
    }
    final completed = {
      for (final a in pack.articles)
        if (store.isCompleted(a.id)) a.id,
    };
    final learned = {for (final r in rows) r.chunkKey};
    final mastered = {
      for (final r in rows)
        if (r.assetState == ChunkAssetState.mastered) r.chunkKey
    };
    final dueRows = rows
        .where((r) =>
            r.dueDate > 0 &&
            r.dueDate <= nowMs &&
            r.assetState.isReviewable)
        .toList();
    final weekStart =
        now.subtract(Duration(days: now.weekday - 1)).copyWith(hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0);

    final data = buildListeningHome(
      articles: pack.articles,
      lastListenedAt: store.lastListenedAt,
      positions: positions,
      completedIds: completed,
      learnedChunkIds: learned,
      now: now,
      dueReviews: dueRows.length,
      masteredChunkIds: mastered,
      dueChunkIds: {for (final r in dueRows) r.chunkKey},
    );
    setState(() {
      _data = data;
      _todaySeconds = store.todaySeconds;
      _weekSeconds = store.secondsSince(weekStart);
    });
  }

  Future<void> _open(ListeningArticle article, {bool reviewRun = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListeningPlayerPage(
          article: article,
          reviewRun: reviewRun,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  int _minutes(ListeningArticle a) {
    final ms = a.sentences.fold<int>(
        0, (sum, s) => sum + estimateLiveSentenceMs(s.text));
    return (ms / 60000).ceil().clamp(1, 999);
  }

  String _mmss(int ms) {
    final total = (ms / 1000).floor().clamp(0, 359999);
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _updated(ListeningArticle a) {
    final d = a.updatedDate;
    if (d == null) return '';
    return '更新 ${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return const Center(child: CircularProgressIndicator(color: kPrimary));
    }
    return RefreshIndicator(
      color: kPrimary,
      backgroundColor: kCard,
      onRefresh: _load,
      child: ListView(
        key: const Key('listening_home'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        children: [
          const Text('磨耳朵',
              style: TextStyle(
                  color: kText, fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('听场景，让词块先混个耳熟',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 12),
          _immersionCard(),
          if (data.noNewContent) ...[
            const SizedBox(height: 14),
            _noNewContentCard(data),
          ],
          const SizedBox(height: 18),
          _sectionTitle('最近 7 天推荐'),
          const SizedBox(height: 10),
          _picks(data),
          if (data.resume != null) ...[
            const SizedBox(height: 16),
            _continueCard(data.resume!),
          ],
          if (data.reviewPlaylist.show) ...[
            const SizedBox(height: 16),
            _reviewPlaylistCard(data.reviewPlaylist),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _sectionTitle('全部篇目')),
              _modeChip('最近更新', !_byScene && !_byLevel, () {
                setState(() {
                  _byScene = false;
                  _byLevel = false;
                });
              }, const Key('listening_mode_recent')),
              const SizedBox(width: 6),
              _modeChip('按场景', _byScene, () {
                setState(() {
                  _byScene = true;
                  _byLevel = false;
                });
              }, const Key('listening_mode_scene')),
              const SizedBox(width: 6),
              _modeChip('按级别', _byLevel, () {
                setState(() {
                  _byScene = false;
                  _byLevel = true;
                });
              }, const Key('listening_mode_level')),
            ],
          ),
          const SizedBox(height: 10),
          _levelChips(data),
          if (data.guidance != null && _levelFilter == null) ...[
            const SizedBox(height: 10),
            _guidanceCard(data.guidance!),
          ],
          const SizedBox(height: 10),
          if (_visible(data.recent).isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('暂无篇目',
                    style: TextStyle(color: Colors.white38)),
              ),
            )
          else if (_byLevel)
            for (final g in _visibleLevels(data)) ...[
              Padding(
                key: Key('listening_level_${g.level.key}'),
                padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
                child: Row(
                  children: [
                    _levelBadge(g.level),
                    const SizedBox(width: 8),
                    Text('${g.articles.length} 篇 · 默认 ${g.level.baseRate}x',
                        style: const TextStyle(
                            color: Colors.white30, fontSize: 11)),
                  ],
                ),
              ),
              for (final a in g.articles) ...[
                _articleTile(a, data),
                const SizedBox(height: 8),
              ],
            ]
          else if (_byScene)
            for (final g in data.scenes) ...[
              if (_visible(g.articles).isEmpty)
                const SizedBox.shrink()
              else ...[
                Padding(
                  key: Key('listening_scene_${g.scene}'),
                  padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
                  child: Row(
                    children: [
                      Text(g.label,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 6),
                      Text('${_visible(g.articles).length} 篇',
                          style: const TextStyle(
                              color: Colors.white30, fontSize: 11)),
                    ],
                  ),
                ),
                for (final a in _visible(g.articles)) ...[
                  _articleTile(a, data),
                  const SizedBox(height: 8),
                ],
              ],
            ]
          else
            for (final a in _visible(data.recent)) ...[
              _articleTile(a, data),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

  /// 级别筛选后的篇目列表。
  List<ListeningArticle> _visible(List<ListeningArticle> src) =>
      _levelFilter == null ? src : src.where((a) => a.level == _levelFilter).toList();

  List<ListeningLevelGroup> _visibleLevels(ListeningHomeData data) => [
        for (final g in data.levels)
          if (_visible(g.articles).isNotEmpty)
            ListeningLevelGroup(level: g.level, articles: _visible(g.articles)),
      ];

  /// 今日浸泡单数字卡（§二.6）：只有数字，没有日历、没有目标、没有连端口径。
  Widget _immersionCard() {
    return Semantics(
      container: true,
      child: Material(
        key: const Key('listening_immersion_card'),
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onGoLibrary,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '今日浸泡 ${_minutesOf(_todaySeconds)} 分钟 · '
                    '本周 ${_minutesOf(_weekSeconds)} 分钟',
                    style: const TextStyle(
                        color: kText, fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                const Text('看统计 ›',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static int _minutesOf(int seconds) => (seconds / 60).round();

  /// 级别筛选 chips（§一.4）：只列出库里真实存在的档位，避免空 chip。
  Widget _levelChips(ListeningHomeData data) {
    return Wrap(
      key: const Key('listening_level_chips'),
      spacing: 8,
      children: [
        _levelChip('全部', null),
        for (final l in data.levelsPresent) _levelChip(l.key, l),
      ],
    );
  }

  Widget _levelChip(String label, ListeningLevel? level) {
    final on = _levelFilter == level;
    return ChoiceChip(
      key: Key('listening_level_chip_${level?.key ?? 'all'}'),
      label: Text(label,
          style: TextStyle(fontSize: 12, color: on ? Colors.black : kText)),
      selected: on,
      onSelected: (_) => setState(() => _levelFilter = level),
      backgroundColor: kCard,
      selectedColor: kPrimary,
      showCheckmark: false,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: on ? kPrimary : Colors.white12),
      ),
    );
  }

  /// 卡片上的级别徽标。
  Widget _levelBadge(ListeningLevel level, {double fontSize = 10}) {
    final tone = listeningLevelColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tone.withValues(alpha: 0.6)),
      ),
      child: Text(
        level.key,
        style: TextStyle(
            color: tone, fontSize: fontSize, fontWeight: FontWeight.w700),
      ),
    );
  }

  /// 引导卡（§一.4）：0 掌握建议 A1；有掌握按场景匹配。点了就筛到那一档。
  Widget _guidanceCard(ListeningGuidance g) {
    return Material(
      key: const Key('listening_guidance_card'),
      color: kCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _levelFilter = g.level),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              _levelBadge(g.level, fontSize: 12),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.title,
                        style: const TextStyle(
                            color: kText,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(
                        g.sceneLabel == null
                            ? g.hint
                            : '${g.hint} · ${g.sceneLabel}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              const Text('筛给我也行',
                  style: TextStyle(color: kPrimary, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  /// 今日复习播单（§二.1）：无到期不显示；点进去仍走既有复习正路，不改到期时间。
  Widget _reviewPlaylistCard(ListeningReviewPlaylist pl) {
    return Material(
      key: const Key('listening_review_playlist'),
      color: kCard,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '今日复习播单 · ${pl.articles.length} 篇含 '
                    '${pl.dueChunks} 个到期块',
                    style: const TextStyle(
                        color: kText,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const Text('到期块会琥珀脉动',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in pl.articles.take(6))
                  ActionChip(
                    key: Key('listening_playlist_${a.id}'),
                    avatar: const Icon(Icons.headphones,
                        size: 16, color: kPrimary),
                    label: Text(a.title,
                        style: const TextStyle(
                            color: kText, fontSize: 12)),
                    onPressed: () => _open(a, reviewRun: true),
                    backgroundColor: kLocked,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: const BorderSide(color: Colors.white12),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(
            color: kText, fontSize: 15, fontWeight: FontWeight.w600),
      );

  Widget _picks(ListeningHomeData data) {
    if (data.picks.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: data.picks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) => _pickCard(data.picks[i]),
      ),
    );
  }

  Widget _pickCard(ListeningPick pick) {
    final accent = switch (pick.kind) {
      ListeningPickKind.today => kPrimary,
      ListeningPickKind.yesterday => Colors.white70,
      ListeningPickKind.reunion => kUnlocked,
    };
    return SizedBox(
      width: 232,
      child: Material(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: Key('listening_pick_${pick.kind.name}'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => _open(pick.article),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(pick.label,
                      style: TextStyle(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _levelBadge(pick.article.level),
                    const Spacer(),
                    Text('${_minutes(pick.article)} 分钟',
                        style: const TextStyle(
                            color: Colors.white30, fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(pick.article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: kText,
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                Text(pick.article.summaryCN,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11, height: 1.35)),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${pick.article.sceneLabel} · ${_minutes(pick.article)} 分钟',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ),
                    Icon(Icons.play_circle_outline, color: accent, size: 20),
                  ],
                ),
                const SizedBox(height: 4),
                Text(pick.hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: accent.withValues(alpha: 0.8), fontSize: 10)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _continueCard(ListeningResume resume) {
    final where = resume.completed
        ? '已听完 · 再听一遍'
        : '上次听到 ${_mmss(resume.positionMs)} · 第 ${resume.sentenceIndex + 1} 句';
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const Key('listening_continue'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => _open(resume.article),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kPrimary.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: kPrimary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: kPrimary, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('继续听',
                        style: TextStyle(
                            color: kPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(resume.article.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: kText,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(where,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _articleTile(ListeningArticle a, ListeningHomeData data) {
    final done = data.completedIds.contains(a.id);
    final heard = data.lastListenedAt.containsKey(a.id);
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('listening_tile_${a.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(a),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(a.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: kText,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 6),
                        _levelBadge(a.level),
                        if (done) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.check_circle,
                              size: 14, color: kUnlocked),
                        ] else if (heard) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.headphones,
                              size: 13, color: Colors.white30),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${a.sceneLabel} · ${_minutes(a)} 分钟'
                      '${_updated(a).isEmpty ? '' : ' · ${_updated(a)}'}',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.play_circle_outline,
                  color: kPrimary, size: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noNewContentCard(ListeningHomeData data) {
    return Container(
      key: const Key('listening_no_new'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kUnlocked.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.replay_circle_filled,
              color: kUnlocked, size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('词块库待复习',
                    style: TextStyle(
                        color: kText,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  data.dueReviews > 0
                      ? '${data.dueReviews} 个词块到期了。先把它们过一遍，再回来听会更顺。'
                      : '篇目都听过了。去词块库回看已学词块，再回来听会更顺。',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11, height: 1.45),
                ),
                if (widget.onGoLibrary != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const Key('listening_go_library'),
                      onPressed: widget.onGoLibrary,
                      child: const Text('去词块库',
                          style: TextStyle(color: kUnlocked, fontSize: 12)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeChip(String label, bool active, VoidCallback onTap, Key key) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(999),
      onTap: active ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? kPrimary.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? kPrimary.withValues(alpha: 0.4) : Colors.white12,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? kPrimary : Colors.white38,
            fontSize: 11,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

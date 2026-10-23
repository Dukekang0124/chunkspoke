import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/listening_article.dart';
import '../services/chunk_asset.dart';
import '../services/listening_audio.dart';
import '../services/listening_home.dart';
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
    final due = rows
        .where((r) =>
            r.dueDate > 0 &&
            r.dueDate <= nowMs &&
            r.assetState.isReviewable)
        .length;

    final data = buildListeningHome(
      articles: pack.articles,
      lastListenedAt: store.lastListenedAt,
      positions: positions,
      completedIds: completed,
      learnedChunkIds: learned,
      now: now,
      dueReviews: due,
    );
    setState(() => _data = data);
  }

  Future<void> _open(ListeningArticle article) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListeningPlayerPage(article: article),
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
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _sectionTitle('全部篇目')),
              _modeChip('最近更新', !_byScene, () {
                setState(() => _byScene = false);
              }, const Key('listening_mode_recent')),
              const SizedBox(width: 8),
              _modeChip('按场景', _byScene, () {
                setState(() => _byScene = true);
              }, const Key('listening_mode_scene')),
            ],
          ),
          const SizedBox(height: 10),
          if (data.recent.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text('暂无篇目',
                    style: TextStyle(color: Colors.white38)),
              ),
            )
          else if (_byScene)
            for (final g in data.scenes) ...[
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
                    Text('${g.articles.length} 篇',
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
          else
            for (final a in data.recent) ...[
              _articleTile(a, data),
              const SizedBox(height: 8),
            ],
        ],
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
      height: 168,
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

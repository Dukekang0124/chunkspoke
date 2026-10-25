import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../models/listening_article.dart';
import '../services/chunk_asset.dart';
import '../services/crash_log.dart';
import '../services/database.dart';
import '../services/learning_export.dart';
import '../services/loaders.dart';
import '../services/session.dart';
import '../steps/practice_loop.dart';
import '../ui/feedback.dart';
import '../ui/theme.dart';
import '../ui/copy_morph.dart';
import '../ui/count_up.dart';
import '../ui/pressable.dart';
import '../ui/stagger.dart';
import '../ui/widgets.dart';

/// 词块库（波 2 · 模块 D）：资产轴唯一口径。
/// 分组：需重修 / 巩固中 / 长期（已巩固+长期）/ 已掌握。
/// 每块展示首学日期、复习次数、连对、可组合块；需重修可一键复习。
class LibraryScreen extends StatefulWidget {
  final VoidCallback? onGoPractice;
  const LibraryScreen({this.onGoPractice, super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  Future<_LibraryData>? _future;
  bool _exporting = false;

  /// 「磨耳朵来源」筛选（指令 S §二.3）：只看从收听文章里收进来的块。
  bool _fromListeningOnly = false;

  /// 核心库筛选（指令 N §二.3）：层级 T0/T1/T2 + 功能八类。
  String _tierFilter = '全部';
  String _funcFilter = '全部';

  static const _tiers = ['T0', 'T1', 'T2'];
  static const _funcCats = [
    '寒暄开场',
    '应答回应',
    '观点立场',
    '请求协助',
    '确认澄清',
    '时间计划',
    '情绪评价',
    '委婉缓冲',
  ];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final p = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    final pack = Provider.of<ListeningPack>(context, listen: false);
    setState(() {
      _future = _load(p, content, pack);
    });
  }

  Future<_LibraryData> _load(
      ProgressService p, ContentPack content, ListeningPack pack) async {
    final rows = await p.chunkStore.allRows();
    final byKey = {for (final r in rows) r.chunkKey: r};
    final chunks = <Chunk>[];
    final combos = <String, int>{};
    final sentenceById = <String, List<TargetSentence>>{};
    for (final lv in content.levels) {
      for (final c in lv.chunks) {
        chunks.add(c);
      }
      for (final s in lv.sentences) {
        for (final id in s.chunkIds) {
          sentenceById.putIfAbsent(id, () => []).add(s);
        }
      }
    }
    // 「可组合」只数已学词块，避免把还没学的块算进可组合池。
    final learnedIds = {
      for (final c in chunks)
        if (byKey[c.id]?.assetState != null &&
            byKey[c.id]!.assetState != ChunkAssetState.learning)
          c.id,
    };
    void addLearnedPeer(Set<String> peers, String id, String self) {
      if (id != self && learnedIds.contains(id)) peers.add(id);
    }

    for (final c in chunks) {
      final peers = <String>{};
      for (final s in sentenceById[c.id] ?? const <TargetSentence>[]) {
        for (final id in s.chunkIds) {
          addLearnedPeer(peers, id, c.id);
        }
      }
      if (peers.isEmpty) {
        Level? lv;
        for (final l in content.levels) {
          if (l.chunks.any((x) => x.id == c.id)) {
            lv = l;
            break;
          }
        }
        if (lv != null) {
          for (final x in lv.chunks) {
            addLearnedPeer(peers, x.id, c.id);
          }
        }
      }
      combos[c.id] = peers.length;
    }
    // 来源互指：块 id → 出现过它的收听文章（最近更新在前，取第一篇 + 篇数）
    final sources = <String, List<ListeningArticle>>{};
    for (final a in pack.articles) {
      for (final c in a.chunks) {
        sources.putIfAbsent(c.id, () => <ListeningArticle>[]).add(a);
      }
    }
    for (final list in sources.values) {
      list.sort((x, y) {
        final xd = x.updatedDate ?? DateTime(1970);
        final yd = y.updatedDate ?? DateTime(1970);
        return yd.compareTo(xd);
      });
    }
    return _LibraryData(
        chunks: chunks, rows: byKey, combos: combos, sources: sources);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LibraryData>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: kPrimary));
        }
        final data = snap.data;
        if (data == null) {
          return const Center(
              child:
                  Text('词块库加载失败，请重试', style: TextStyle(color: Colors.white54)));
        }
        final shown = _LibraryData(
          chunks: data.chunks.where((c) {
            if (_fromListeningOnly && !data.sources.containsKey(c.id)) {
              return false;
            }
            if (_tierFilter != '全部' && c.tier != _tierFilter) return false;
            if (_funcFilter != '全部' && c.funcCat != _funcFilter) return false;
            return true;
          }).toList(),
          rows: data.rows,
          combos: data.combos,
          sources: data.sources,
        );
        final groups = _buildGroups(shown);
        final sourceCount =
            data.chunks.where((c) => data.sources.containsKey(c.id)).length;
        final total = data.chunks.length;
        final tierCounts = <String, int>{};
        final funcCounts = <String, int>{};
        for (final c in data.chunks) {
          tierCounts[c.tier] = (tierCounts[c.tier] ?? 0) + 1;
          if (c.funcCat.isNotEmpty) {
            funcCounts[c.funcCat] = (funcCounts[c.funcCat] ?? 0) + 1;
          }
        }
        final contentIds = {for (final c in data.chunks) c.id};
        final learned = data.rows.values
            .where((r) =>
                contentIds.contains(r.chunkKey) &&
                r.assetState != ChunkAssetState.learning)
            .length;
        final mastered = data.rows.values
            .where((r) =>
                contentIds.contains(r.chunkKey) &&
                r.assetState == ChunkAssetState.mastered)
            .length;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _header(mastered, learned, total),
            const SizedBox(height: 12),
            _exportCard(),
            const SizedBox(height: 12),
            Row(
              children: [
                PressableScale(
                  scale: 0.94,
                  child: FilterChip(
                    key: const Key('library_filter_listening'),
                    label: Text('磨耳朵来源 $sourceCount 块',
                        style: const TextStyle(fontSize: 12)),
                    selected: _fromListeningOnly,
                    onSelected: (v) => setState(() => _fromListeningOnly = v),
                    avatar:
                        const Icon(Icons.headphones, size: 16, color: kPrimary),
                    showCheckmark: false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _tierChip('全部', total),
                  for (final t in _tiers)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: _tierChip(t, tierCounts[t] ?? 0),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _funcChip('全部', total),
                  for (final f in _funcCats)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: _funcChip(f, funcCounts[f] ?? 0),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (groups.every((g) => g.chunks.isEmpty))
              _emptyState()
            else
              for (final g in groups)
                if (g.chunks.isNotEmpty) ...[
                  _GroupHeader(group: g),
                  const SizedBox(height: 8),
                  for (final (i, c) in g.chunks.indexed) ...[
                    StaggerIn(
                      index: i,
                      child: _libraryRow(c, shown.rows[c.id],
                          shown.combos[c.id] ?? 0, data.sources[c.id]),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 8),
                ],
          ],
        );
      },
    );
  }

  Widget _tierChip(String tier, int count) {
    final selected = _tierFilter == tier;
    return PressableScale(
      scale: 0.94,
      child: FilterChip(
        key: Key('library_filter_tier_$tier'),
        label: Text(tier == '全部' ? '全部层级' : '$tier $count',
            style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(() => _tierFilter = tier),
        showCheckmark: false,
      ),
    );
  }

  Widget _funcChip(String func, int count) {
    final selected = _funcFilter == func;
    return PressableScale(
      scale: 0.94,
      child: FilterChip(
        key: Key('library_filter_func_$func'),
        label: Text(func == '全部' ? '全部功能' : '$func $count',
            style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => setState(() => _funcFilter = func),
        showCheckmark: false,
      ),
    );
  }

  static Color _tierColor(String tier) => switch (tier) {
        'T0' => kPrimary,
        'T1' => const Color(0xFF7FB4FF),
        _ => Colors.white54,
      };

  Widget _tierBadge(Chunk c) {
    final color = _tierColor(c.tier);
    return Container(
      key: Key('library_tier_${c.id}'),
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(c.tier,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  Widget _header(int mastered, int learned, int total) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1B2E), Color(0xFF241A06)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kPrimary.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('词块资产库',
              style: TextStyle(
                  color: kPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          CountUpText(mastered,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w700),
              format: (v) => '已掌握 $v 个词块'),
          const SizedBox(height: 4),
          Text('已学完 $learned / $total 块 · 已掌握 = 走完 1/3/7/14 天复习',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _exportCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.ios_share, color: kPrimary, size: 22),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('导出学习数据',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
                SizedBox(height: 2),
                Text('复习保持率 + 六步漏斗汇总，纯本地生成，不会自动上传',
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _exporting ? null : _export,
            child: Text(_exporting ? '生成中…' : '导出',
                style: const TextStyle(color: kPrimary, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final p = Provider.of<ProgressService>(context, listen: false);
      final content = Provider.of<ContentPack>(context, listen: false);
      final export = await buildLearningExport(progress: p, content: content);
      final file = await saveLearningExport(export);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCard,
          title: const Text('学习数据已生成',
              style: TextStyle(color: Colors.white, fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('文件已保存到：',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(file.path,
                  style: const TextStyle(color: kPrimary, fontSize: 12)),
              const SizedBox(height: 10),
              const Text('不含录音和账号信息，是否分享由你决定。',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          actions: [
            // M1（#40 复制变勾）：反馈出现在按钮本身，不弹提示框、不关对话框。
            CopyMorphButton(
              variant: CopyMorphVariant.text,
              label: '复制内容',
              copy: () => Clipboard.setData(ClipboardData(text: export.text)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('完成', style: TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      );
    } catch (e, st) {
      CrashLog.write('Library.export: $e', st);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('导出失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  List<_AssetGroup> _buildGroups(_LibraryData data) {
    List<Chunk> of(Set<ChunkAssetState> states) => data.chunks.where((c) {
          final r = data.rows[c.id];
          return r != null && states.contains(r.assetState);
        }).toList()
          ..sort((a, b) {
            final ra = data.rows[a.id]!;
            final rb = data.rows[b.id]!;
            final da = ra.dueDate == 0 ? 1 << 62 : ra.dueDate;
            final db = rb.dueDate == 0 ? 1 << 62 : rb.dueDate;
            return da.compareTo(db);
          });
    return [
      _AssetGroup(
        state: ChunkAssetState.relearning,
        title: '需重修',
        subtitle: '复习没通过，回到 1 天档；点「立即复习」当天补回来',
        chunks: of({ChunkAssetState.relearning}),
      ),
      _AssetGroup(
        state: ChunkAssetState.consolidating,
        title: '巩固中',
        subtitle: '1 天档，明天会再见面',
        chunks: of({ChunkAssetState.consolidating}),
      ),
      _AssetGroup(
        state: ChunkAssetState.longTerm,
        title: '长期',
        subtitle: '已巩固 + 长期（3/7/14 天档；已巩固首档次日再见）',
        chunks: of({
          ChunkAssetState.consolidated,
          ChunkAssetState.longTerm,
        }),
      ),
      _AssetGroup(
        state: ChunkAssetState.mastered,
        title: '已掌握',
        subtitle: '走完全部复习间隔，进入长期记忆',
        chunks: of({ChunkAssetState.mastered}),
      ),
    ];
  }

  Widget _emptyState() => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          children: [
            const Icon(Icons.inventory_2_outlined,
                color: Colors.white38, size: 46),
            const SizedBox(height: 10),
            const Text('词块库还空着',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('完成一块的六步学习后，它会进入 1/3/7/14 天的巩固周期，并出现在这里。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 14),
            if (widget.onGoPractice != null)
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: widget.onGoPractice,
                child: const Text('去练习第一块',
                    style: TextStyle(color: Colors.black87)),
              ),
          ],
        ),
      );

  Widget _libraryRow(Chunk c, ChunkRow? row, int combos,
      [List<ListeningArticle>? from]) {
    final state = row?.assetState ?? ChunkAssetState.learning;
    final first =
        row == null || row.firstLearnedAt == 0 ? '—' : _md(row.firstLearnedAt);
    final due = row == null || row.dueDate == 0
        ? (state == ChunkAssetState.mastered ? '周期已完成' : '—')
        : '下次 ${_md(row.dueDate)}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: state == ChunkAssetState.relearning
                ? Colors.redAccent.withValues(alpha: 0.5)
                : Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _tierBadge(c),
              ChunkTile(c.text, c.semantic),
              const SizedBox(width: 8),
              Expanded(
                child: Text(c.meaningCN,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.volume_up, color: kPrimary, size: 20),
                onPressed: () => speakOrHint(context,
                    Provider.of<TtsService>(context, listen: false), c.text),
              ),
            ],
          ),
          if (from != null && from.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              from.length == 1
                  ? '来自《${from.first.sceneLabel} · ${from.first.title}》'
                  : '来自《${from.first.title}》等 ${from.length} 篇',
              key: Key('library_source_${c.id}'),
              style: const TextStyle(color: kPrimary, fontSize: 11),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '首学 $first · 复习 ${row?.reviewCount ?? 0} 次 · '
            '连对 ${row?.correctStreak ?? 0} · 可组合 $combos 块 · '
            '频表 ${c.freqRank > 0 ? '#${c.freqRank}' : '未收录'} · $due',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          if (state == ChunkAssetState.relearning) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => _reviewOne(c),
                icon: const Icon(Icons.replay, color: kPrimary, size: 16),
                label: const Text('立即复习',
                    style: TextStyle(color: kPrimary, fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _reviewOne(Chunk c) async {
    final content = Provider.of<ContentPack>(context, listen: false);
    final level = PracticeSession.reviewLevel(content, [c]);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('重修词块')),
        body: PracticeLoop(
          level: level,
          chunks: [c],
          reviewMode: true,
          onDone: (_) => Navigator.of(context).maybePop(),
        ),
      ),
    ));
    if (mounted) _reload();
  }

  String _md(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}月${d.day}日';
  }
}

class _LibraryData {
  final List<Chunk> chunks;
  final Map<String, ChunkRow> rows;
  final Map<String, int> combos;
  final Map<String, List<ListeningArticle>> sources;
  const _LibraryData({
    required this.chunks,
    required this.rows,
    required this.combos,
    this.sources = const {},
  });
}

class _AssetGroup {
  final ChunkAssetState state;
  final String title;
  final String subtitle;
  final List<Chunk> chunks;
  const _AssetGroup({
    required this.state,
    required this.title,
    required this.subtitle,
    required this.chunks,
  });
}

class _GroupHeader extends StatelessWidget {
  final _AssetGroup group;
  const _GroupHeader({required this.group});

  @override
  Widget build(BuildContext context) {
    final color =
        group.state == ChunkAssetState.relearning ? Colors.redAccent : kPrimary;
    return Row(
      children: [
        Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Text(group.title,
            style: TextStyle(
                color: color, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(width: 6),
        Text('${group.chunks.length} 块',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const Spacer(),
        Flexible(
          child: Text(group.subtitle,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ),
      ],
    );
  }
}

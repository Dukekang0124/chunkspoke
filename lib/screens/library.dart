import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../services/chunk_asset.dart';
import '../services/crash_log.dart';
import '../services/database.dart';
import '../services/learning_export.dart';
import '../services/loaders.dart';
import '../services/session.dart';
import '../steps/practice_loop.dart';
import '../ui/feedback.dart';
import '../ui/theme.dart';
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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final p = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    setState(() {
      _future = _load(p, content);
    });
  }

  Future<_LibraryData> _load(
      ProgressService p, ContentPack content) async {
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
    return _LibraryData(chunks: chunks, rows: byKey, combos: combos);
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
              child: Text('词块库加载失败，请重试',
                  style: TextStyle(color: Colors.white54)));
        }
        final groups = _buildGroups(data);
        final total = data.chunks.length;
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
            const SizedBox(height: 18),
            if (groups.every((g) => g.chunks.isEmpty))
              _emptyState()
            else
              for (final g in groups)
                if (g.chunks.isNotEmpty) ...[
                  _GroupHeader(group: g),
                  const SizedBox(height: 8),
                  for (final c in g.chunks) ...[
                    _libraryRow(c, data.rows[c.id], data.combos[c.id] ?? 0),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 8),
                ],
          ],
        );
      },
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
                  color: kPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('已掌握 $mastered 个词块',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w700)),
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
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: export.text));
                if (ctx.mounted) {
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('汇总文本已复制'),
                          duration: Duration(seconds: 1)));
                }
              },
              child: const Text('复制内容',
                  style: TextStyle(color: kPrimary)),
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('导出失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  List<_AssetGroup> _buildGroups(_LibraryData data) {
    List<Chunk> of(Set<ChunkAssetState> states) => data.chunks
        .where((c) {
          final r = data.rows[c.id];
          return r != null && states.contains(r.assetState);
        })
        .toList()
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
            const Text(
                '完成一块的六步学习后，它会进入 1/3/7/14 天的巩固周期，并出现在这里。',
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

  Widget _libraryRow(Chunk c, ChunkRow? row, int combos) {
    final state = row?.assetState ?? ChunkAssetState.learning;
    final first = row == null || row.firstLearnedAt == 0
        ? '—'
        : _md(row.firstLearnedAt);
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
              ChunkTile(c.text, c.type),
              const SizedBox(width: 8),
              Expanded(
                child: Text(c.meaningCN,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.volume_up, color: kPrimary, size: 20),
                onPressed: () => speakOrHint(
                    context,
                    Provider.of<TtsService>(context, listen: false),
                    c.text),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '首学 $first · 复习 ${row?.reviewCount ?? 0} 次 · '
            '连对 ${row?.correctStreak ?? 0} · 可组合 $combos 块 · $due',
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
  const _LibraryData({
    required this.chunks,
    required this.rows,
    required this.combos,
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
    final color = group.state == ChunkAssetState.relearning
        ? Colors.redAccent
        : kPrimary;
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
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
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

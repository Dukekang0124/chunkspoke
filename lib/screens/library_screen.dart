import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/learning.dart';
import '../data/vocab.dart';
import '../ui/theme.dart';
import '../widgets/app_only_notice.dart';
import 'review_screen.dart' show assetColor;

/// 词块库：487 块全量表格 + 右滑详情（资产轴口径，与 App 一致）。
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _search = TextEditingController();
  String _tier = '全部';
  bool _learnedOnly = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    widget.session.revision.addListener(_onData);
  }

  @override
  void dispose() {
    widget.session.revision.removeListener(_onData);
    _search.dispose();
    super.dispose();
  }

  void _onData() {
    if (mounted) setState(() {});
  }

  List<LibraryRow> _filtered(List<LibraryRow> rows) {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final r in rows)
        if ((_tier == '全部' || r.chunk.tier == _tier) &&
            (!_learnedOnly || r.state != AssetState.learning) &&
            (q.isEmpty ||
                r.chunk.text.toLowerCase().contains(q) ||
                r.chunk.meaningCN.contains(q) ||
                r.chunk.id.contains(q)))
          r,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return ValueListenableBuilder<bool>(
      valueListenable: session.contentReady,
      builder: (context, ready, _) {
        if (!ready) {
          return Center(
            child: Text(
              session.contentError.value == null ? '内容包加载中…' : '内容包加载失败',
              style: const TextStyle(color: Colors.white54),
            ),
          );
        }
        final rows = session.rows();
        final counts = libraryStateCounts(rows);
        final learned = rows.where((r) => r.state != AssetState.learning).length;
        final mastered = rows.where((r) => r.mastered).length;
        final visible = _filtered(rows);
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '词块库',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '共 ${rows.length} 块 · 已学完 $learned · 已掌握 $mastered',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const Spacer(),
                  const AppOnlyNotice(compact: true),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '状态为资产轴口径（与 App 同一套）：'
                '新学 ${counts[AssetState.learning.wire]} · '
                '巩固中 ${counts[AssetState.consolidating.wire]} · '
                '已巩固 ${counts[AssetState.consolidated.wire]} · '
                '长期 ${counts[AssetState.longTerm.wire]} · '
                '已掌握 ${counts[AssetState.mastered.wire]} · '
                '需重修 ${counts[AssetState.relearning.wire]}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  SizedBox(
                    width: 300,
                    height: 38,
                    child: TextField(
                      key: const Key('library_search'),
                      controller: _search,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '搜索英文 / 中文 / id',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                        prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white38),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                        filled: true,
                        fillColor: kCard,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: kLocked),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: kLocked),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  _tierChip('全部', rows.length),
                  for (final t in const ['T0', 'T1', 'T2'])
                    _tierChip(t, rows.where((r) => r.chunk.tier == t).length),
                  const SizedBox(width: 12),
                  FilterChip(
                    key: const Key('library_learned_only'),
                    label: const Text('只看已学'),
                    selected: _learnedOnly,
                    onSelected: (v) => setState(() => _learnedOnly = v),
                    selectedColor: kPrimary.withValues(alpha: 0.18),
                    checkmarkColor: kPrimary,
                    labelStyle: TextStyle(
                      color: _learnedOnly ? kPrimary : Colors.white60,
                      fontSize: 12,
                    ),
                    side: BorderSide(color: _learnedOnly ? kPrimary : kLocked),
                    backgroundColor: Colors.transparent,
                  ),
                  const Spacer(),
                  Text(
                    '显示 ${visible.length} 块',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kLocked),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      _headerRow(),
                      Expanded(
                        child: visible.isEmpty
                            ? const Center(
                                child: Text('没有匹配的词块', style: TextStyle(color: Colors.white38)),
                              )
                            : ListView.builder(
                                itemCount: visible.length,
                                itemExtent: 48,
                                itemBuilder: (context, i) => _row(visible[i]),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tierChip(String tier, int count) {
    final selected = _tier == tier;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        key: Key('library_filter_tier_$tier'),
        label: Text(tier == '全部' ? '全部 $count' : '$tier $count'),
        selected: selected,
        onSelected: (_) => setState(() => _tier = tier),
        selectedColor: kPrimary.withValues(alpha: 0.18),
        checkmarkColor: kPrimary,
        labelStyle: TextStyle(color: selected ? kPrimary : Colors.white60, fontSize: 12),
        side: BorderSide(color: selected ? kPrimary : kLocked),
        backgroundColor: Colors.transparent,
      ),
    );
  }

  Widget _headerRow() {
    const style = TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kLocked, width: 0.5)),
      ),
      child: const Row(
        children: [
          Expanded(flex: 4, child: Text('块', style: style)),
          Expanded(flex: 4, child: Text('中文', style: style)),
          Expanded(flex: 1, child: Text('层级', style: style)),
          Expanded(flex: 2, child: Text('频次排名', style: style)),
          Expanded(flex: 3, child: Text('掌握状态', style: style)),
        ],
      ),
    );
  }

  Widget _row(LibraryRow row) {
    final stateColor = assetColor(row.state);
    return InkWell(
      key: Key('library_row_${row.chunk.id}'),
      onTap: () => _showDetail(row),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: kLocked, width: 0.3)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      row.chunk.text,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    row.chunk.id,
                    style: const TextStyle(color: Colors.white24, fontSize: 10),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Text(
                row.chunk.meaningCN,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                row.chunk.tier,
                style: TextStyle(color: tierColor(row.chunk.tier), fontSize: 12),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                '${row.chunk.freqRank}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(row.state.label, style: TextStyle(color: stateColor, fontSize: 12)),
                  if (row.stage > 0) ...[
                    const SizedBox(width: 6),
                    Text('第 ${row.stage + 1} 档', style: const TextStyle(color: Colors.white24, fontSize: 11)),
                  ],
                  if (row.dueDate > 0) ...[
                    const SizedBox(width: 8),
                    Text(_dueText(row.dueDate), style: const TextStyle(color: Colors.white24, fontSize: 11)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _dueText(int dueMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (dueMs <= now) return '已到期';
    final d = DateTime.fromMillisecondsSinceEpoch(dueMs);
    return '${d.month}/${d.day} 到期';
  }

  void _showDetail(LibraryRow row) {
    final session = widget.session;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭详情',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, _) => Align(
        alignment: Alignment.centerRight,
        child: _ChunkDetail(row: row, session: session),
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    );
  }
}

class _ChunkDetail extends StatelessWidget {
  const _ChunkDetail({required this.row, required this.session});

  final LibraryRow row;
  final AppSession session;

  @override
  Widget build(BuildContext context) {
    final c = row.chunk;
    final record = row.record;
    return Material(
      color: kBg,
      child: SizedBox(
        width: 420,
        height: double.infinity,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    const Text(
                      '词块详情',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: [
                    Text(
                      c.text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(c.meaningCN, style: const TextStyle(color: kPrimary, fontSize: 16)),
                    const SizedBox(height: 16),
                    if (c.example.isNotEmpty) ...[
                      _section('例句'),
                      Text(c.example, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5)),
                      const SizedBox(height: 4),
                      Text(c.exampleCN, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                      const SizedBox(height: 16),
                    ],
                    _section('属性'),
                    _kv('id', c.id),
                    _kv('层级', '${c.tier} · 关卡 ${c.level}'),
                    _kv('功能类', c.funcCat),
                    _kv('类型', c.type),
                    _kv('语义', c.semantic),
                    _kv('频次排名', '${c.freqRank}'),
                    _kv('来源', c.sources.isEmpty ? '—' : c.sources.join('\n')),
                    const SizedBox(height: 16),
                    _section('本机进度'),
                    _kv('状态', row.state.label),
                    _kv('复习档位', '第 ${row.stage + 1} 档（1/3/7/14 天）'),
                    _kv('连续通过', '${row.streak}'),
                    _kv(
                      '下次到期',
                      record == null || row.dueDate == 0
                          ? (row.mastered ? '已走完全部间隔' : '未排期')
                          : DateTime.fromMillisecondsSinceEpoch(row.dueDate).toString().substring(0, 16),
                    ),
                    const SizedBox(height: 20),
                    if (record == null || row.state == AssetState.learning)
                      FilledButton(
                        key: Key('detail_learn_${c.id}'),
                        onPressed: () async {
                          await session.learnChunk(c);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: kPrimary,
                          foregroundColor: Colors.black,
                        ),
                        child: const Text('加入复习（明天到期）'),
                      )
                    else
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: kPrimary,
                          side: const BorderSide(color: kPrimary),
                        ),
                        child: const Text('去复习台练这一块'),
                      ),
                    const SizedBox(height: 10),
                    const Text(
                      '网页版不做发音与听写；语音相关练习请在 App 内完成。',
                      style: TextStyle(color: Colors.white30, fontSize: 11, height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          title,
          style: const TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(k, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
            Expanded(
              child: Text(v, style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.5)),
            ),
          ],
        ),
      );
}

Color tierColor(String tier) {
  switch (tier) {
    case 'T0':
      return kPrimary;
    case 'T1':
      return const Color(0xFF6FA8FF);
    default:
      return Colors.white54;
  }
}

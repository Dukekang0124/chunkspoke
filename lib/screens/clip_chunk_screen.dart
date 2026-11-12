import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/clip_linkage.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import 'clip_chunk_listening_screen.dart';

/// 我的词块：从「我的英语本」的英文句子里自动整理的词块归档。
///
/// 三条展示口径（与 [buildClipArchive] 同源，界面不另算一套数）：
///  · 词块 = 跨句去重后的规范形；句子 = 真正认出了词块的句子（阈值只数这个）；
///  · 没认出词块的句子如实计数，不冒充进度；
///  · 归档是派生的：这里看到的每一个词块都来自现存的英语本，删包即消失。
///
/// 联动：累计句子数到设置里的阈值后，磨耳朵首页出现入口；本页也直接给按钮。
class ClipChunkScreen extends StatefulWidget {
  const ClipChunkScreen({super.key});

  @override
  State<ClipChunkScreen> createState() => _ClipChunkScreenState();
}

class _ClipChunkScreenState extends State<ClipChunkScreen> {
  ClipLinkageState? _state;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    final st = await loadClipLinkage(p.database);
    if (!mounted) return;
    setState(() {
      _state = st;
      _loading = false;
    });
  }

  Future<void> _openListening() async {
    final st = _state;
    if (st == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ClipChunkListeningScreen(state: st)));
    if (mounted) await _load();
  }

  Future<void> _preview(String text) async {
    final tts = Provider.of<TtsService>(context, listen: false);
    final ok = await tts.speakAndWait(text);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这台设备的语音引擎没出声，去「设置 → 声音」检查一下再试。'),
          duration: Duration(milliseconds: 2200)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('我的词块')),
      body: _loading || st == null
          ? Center(child: CircularProgressIndicator(color: kPrimary))
          : ListView(
              key: const Key('clip_archive_screen'),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
              children: [
                _summaryCard(st),
                if (st.chunkCount == 0) ...[
                  const SizedBox(height: 14),
                  _emptyCard(st),
                ] else ...[
                  const SizedBox(height: 10),
                  Text('词块按出现句数排；点小喇叭只听这一个，点「去磨耳朵」按顺序听全部。',
                      style:
                          TextStyle(color: kTextMuted, fontSize: 11, height: 1.45)),
                  const SizedBox(height: 14),
                  for (final kind in const [
                    '动词短语',
                    '固定搭配',
                    '介词短语',
                    '常用句型',
                  ])
                    ..._kindSection(st, kind),
                  if (st.archive.unmatchedSentences > 0) ...[
                    const SizedBox(height: 12),
                    Text(
                        '另有 ${st.archive.unmatchedSentences} 句里没有我认得的可学词块，'
                        '不计入进度——提取失败不是错误，是这句里没有我认得的东西。',
                        style: TextStyle(
                            color: kTextFaint, fontSize: 11, height: 1.45)),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: kCardAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kBorderSoft),
                    ),
                    child: Text(
                        '这里不翻译、不猜词义。词块来自内置的常用短语表和一个受控句型模板，'
                        '宁可少收，也不硬造。删掉英语本里的句子，这里对应的词块会一起消失。',
                        style: TextStyle(
                            color: kTextMuted, fontSize: 11, height: 1.45)),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _summaryCard(ClipLinkageState st) {
    final enabled = st.enabled;
    final ready = st.ready;
    // 先报「扫了几句、几句认出来」，再说还差多少——否则用户刚粘贴完只看到
    // 「还差 10 句」，会以为自己的句子根本没被读到。
    final scanned = st.archive.totalScanned;
    final scanLine = scanned == 0
        ? '还没有扫到英文句子'
        : st.sentenceCount == scanned
            ? '已扫描 $scanned 句英文，全部认出了可学词块'
            : '已扫描 $scanned 句英文，其中 ${st.sentenceCount} 句认出了可学词块';
    final String status;
    if (!enabled) {
      status =
          '$scanLine；磨耳朵联动已关闭，归档照常积累，到「设置 → 磨耳朵联动阈值」打开就能听。';
    } else if (ready) {
      status = '$scanLine；已联动磨耳朵：可以按「词块念两遍 + 原句一遍」的顺序听。';
    } else if (st.chunkCount == 0 && scanned > 0) {
      // 扫了句子但一个词块都没认出来：这时说「还差 10 句」会让人以为再攒几句就行，
      // 其实卡在识别上，必须直说。
      status = '$scanLine；这些句子里还没有我认得的短语，联动进度还没开始。';
    } else {
      status =
          '$scanLine；还差 ${st.remaining} 句到 ${st.threshold} 句，到了会自动出现在磨耳朵首页。';
    }
    return Container(
      key: const Key('clip_archive_summary'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_motion, color: kPrimary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('自动整理出的可学词块',
                    style: TextStyle(
                        color: kText,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 22,
            runSpacing: 10,
            children: [
              _stat('${st.chunkCount}', '个词块'),
              _stat('${st.sentenceCount}', '句已收录'),
              if (scanned > st.sentenceCount)
                _stat('$scanned', '句已扫描'),
              if (enabled) _stat('${st.threshold}', '句触发联动'),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const Key('clip_archive_progress'),
              value: enabled ? st.progress : 0,
              minHeight: 6,
              backgroundColor: kBorderSoft,
              valueColor: AlwaysStoppedAnimation(kPrimary),
            ),
          ),
          const SizedBox(height: 8),
          Text(status,
              style: TextStyle(color: kTextMuted, fontSize: 11, height: 1.45)),
          if (ready && st.chunkCount > 0) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('clip_archive_go_listen'),
                onPressed: _openListening,
                icon: Icon(Icons.headphones, color: kOnPrimary, size: 18),
                label: Text('去磨耳朵 · 听这些词块',
                    style: TextStyle(color: kOnPrimary, fontSize: 14)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value,
            style: TextStyle(
                color: kText, fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: kTextFaint, fontSize: 11)),
      ],
    );
  }

  List<Widget> _kindSection(ClipLinkageState st, String kind) {
    final list = st.archive.chunks.where((c) => c.kind == kind).toList();
    if (list.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Row(
          children: [
            Text(kind,
                style: TextStyle(
                    color: kTextSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 6),
            Text('${list.length}',
                style: TextStyle(color: kTextFaint, fontSize: 11)),
          ],
        ),
      ),
      for (final c in list) ...[
        _chunkCard(c),
        const SizedBox(height: 8),
      ],
    ];
  }

  Widget _chunkCard(ClipChunkEntry c) {
    return Container(
      key: Key('clip_chunk_${c.key}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(c.text,
                    style: TextStyle(
                        color: kText,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
              ),
              IconButton(
                key: Key('clip_play_${c.key}'),
                visualDensity: VisualDensity.compact,
                tooltip: '听这个词块',
                icon: Icon(Icons.volume_up, color: kPrimary, size: 20),
                onPressed: () => _preview(c.text),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('${c.kind} · 出自 ${c.count} 句',
              style: TextStyle(color: kTextFaint, fontSize: 11)),
          const SizedBox(height: 6),
          Text('“${c.contextSentence}”',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: kTextSecondary, fontSize: 12, height: 1.45)),
          if (c.count > 1) ...[
            const SizedBox(height: 2),
            Text('还有 ${c.count - 1} 句也用到它',
                style: TextStyle(color: kTextFaint, fontSize: 10)),
          ],
        ],
      ),
    );
  }

  Widget _emptyCard(ClipLinkageState st) {
    final scanned = st.archive.totalScanned;
    final neverScanned = scanned == 0;
    return Container(
      key: Key(neverScanned
          ? 'clip_archive_empty_none'
          : 'clip_archive_empty_unmatched'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.content_paste_search, color: kTextFaint, size: 28),
          const SizedBox(height: 10),
          Text(neverScanned ? '还没有可学的词块' : '扫了 $scanned 句，暂时没认出词块',
              style: TextStyle(
                  color: kText, fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
              neverScanned
                  ? '在「我的英语本」里粘贴英文句子后，这里会自动挑出 '
                      'look forward to、take care of 这类可学的部分，并保留它所在的原句。\n\n'
                      '只认英文句子：单词条目、中文和网址不会产生词块。'
                  : '这些句子已经存好了，只是里面没有命中我认得的常用短语。'
                      '我认得的是固定搭配（good morning、split the bill、'
                      'in my opinion）、动词短语（look forward to、write down）'
                      '和常见句型（be able to、it is important to）。\n\n'
                      '这不是导入失败：句子照常能跟读、能听，只是词块归档暂时是空的。',
              key: Key(neverScanned
                  ? 'clip_archive_empty_none_text'
                  : 'clip_archive_empty_unmatched_text'),
              style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.55)),
          const SizedBox(height: 12),
          TextButton.icon(
            key: const Key('clip_archive_back'),
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.arrow_back, color: kPrimary, size: 16),
            label: Text('回词块库 · 我的英语本',
                style: TextStyle(color: kPrimary, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

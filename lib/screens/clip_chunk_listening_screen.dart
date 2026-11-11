import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/clip_linkage.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';

/// 词块联动 · 磨耳朵：把「我的词块」按 词块×2 → 原句×1 的顺序念一遍。
///
/// 结构性边界（与 1.9.1 的用户本听力桥接同源）：
///  · **不写库**：不改任何资产态、不排复习、不记会话；退出即停；
///  · **不碰官方篇目**：播单只由派生归档生成，官方 `chunks`/`sessions` 零写入；
///  · **有上限**：最多带 [kClipListenMaxChunks] 个词块，界面如实说明
///    （一本 200 句的本子全念完要二十多分钟，不该一点播放就停不下来）。
class ClipChunkListeningScreen extends StatefulWidget {
  const ClipChunkListeningScreen({super.key, required this.state});

  final ClipLinkageState state;

  @override
  State<ClipChunkListeningScreen> createState() =>
      _ClipChunkListeningScreenState();
}

class _ClipChunkListeningScreenState extends State<ClipChunkListeningScreen> {
  late final ClipListenProgram _program =
      buildClipListenProgram(widget.state.archive);
  List<ClipListenItem> get _queue => _program.queue;
  List<ClipListenRound> get _rounds => _program.rounds;

  TtsService? _tts;
  int _index = 0;
  bool _playing = false;
  bool _finished = false;

  /// 播放代次：暂停 / 跳句 / 退出时自增，旧循环看到代次变了就自行结束。
  int _runToken = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tts ??= Provider.of<TtsService>(context, listen: false);
  }

  @override
  void dispose() {
    _runToken++;
    _tts?.stop();
    super.dispose();
  }

  int get _roundIndex {
    var idx = 0;
    for (var i = 0; i < _rounds.length; i++) {
      if (_rounds[i].start <= _index) idx = i;
    }
    return idx;
  }

  ClipListenItem? get _current =>
      _queue.isEmpty ? null : _queue[_index.clamp(0, _queue.length - 1)];

  Future<void> _play() async {
    if (_playing || _queue.isEmpty) return;
    final tts = _tts;
    if (tts == null) return;
    final token = ++_runToken;
    setState(() {
      _playing = true;
      _finished = false;
      if (_index >= _queue.length) _index = 0;
    });
    while (mounted && token == _runToken && _playing) {
      final item = _queue[_index];
      final ok = await tts.speakAndWait(item.speak);
      if (!mounted || token != _runToken || !_playing) return;
      if (!ok) {
        setState(() => _playing = false);
        _toast('这台设备的语音引擎没出声，去「设置 → 声音」检查一下再试。');
        return;
      }
      // 词块之间留气口；原句念完留长一点，让上下文沉一下。
      await Future<void>.delayed(Duration(
          milliseconds: item.kind == 'sentence' ? 650 : 380));
      if (!mounted || token != _runToken || !_playing) return;
      if (_index + 1 >= _queue.length) {
        setState(() {
          _playing = false;
          _finished = true;
        });
        return;
      }
      setState(() => _index++);
    }
  }

  Future<void> _pause() async {
    _runToken++;
    if (mounted) setState(() => _playing = false);
    await _tts?.stop();
  }

  Future<void> _jumpTo(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _queue.length) return;
    final wasPlaying = _playing;
    await _pause();
    if (!mounted) return;
    setState(() {
      _index = queueIndex;
      _finished = false;
    });
    if (wasPlaying) await _play();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), duration: const Duration(milliseconds: 2200)));
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final archive = widget.state.archive;
    return Scaffold(
      appBar: AppBar(title: const Text('词块联动 · 磨耳朵')),
      body: ListView(
        key: const Key('clip_listen_screen'),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
        children: [
          Text('把你存的句子拆成词块听',
              style: TextStyle(
                  color: kText, fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('每个词块念两遍，再念一遍它所在的原句。只播放，不改学习进度、不排复习。',
              style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.45)),
          if (archive.sentences.any((s) => s.text.trim().isNotEmpty)) ...[
            const SizedBox(height: 6),
            Text(
                '来自 ${archive.sentenceCount} 句 · ${archive.chunkCount} 个词块'
                '${archive.chunkCount > kClipListenMaxChunks ? '（本次先念前 $kClipListenMaxChunks 个）' : ''}',
                style: TextStyle(color: kTextFaint, fontSize: 11)),
          ],
          const SizedBox(height: 14),
          if (current == null)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                  color: kCard, borderRadius: BorderRadius.circular(14)),
              child: Text('还没有可听的词块。',
                  style: TextStyle(color: kTextMuted, fontSize: 13)),
            )
          else ...[
            Container(
              key: const Key('clip_listen_current'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: (_playing ? kPrimary : kBorder)
                        .withValues(alpha: 0.6)),
              ),
              child: Column(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: kPrimary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                        current.kind == 'chunk' ? '词块 · 念两遍' : '原句 · 放回上下文',
                        style: TextStyle(
                            color: kPrimary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 8),
                  Text(current.display,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: kText,
                          fontSize: current.kind == 'chunk' ? 22 : 18,
                          height: 1.35,
                          fontWeight: FontWeight.w700)),
                  if (current.sub.trim().isNotEmpty &&
                      current.sub != current.display) ...[
                    const SizedBox(height: 6),
                    Text(current.sub,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: kTextSecondary,
                            fontSize: 13,
                            height: 1.4)),
                  ],
                  const SizedBox(height: 10),
                  Text(
                      '词块 ${_roundIndex + 1} / ${_rounds.length}'
                      '${_finished ? ' · 已听完' : ''}',
                      style: TextStyle(color: kTextFaint, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('clip_listen_prev'),
                  tooltip: '上一个词块',
                  onPressed: _roundIndex > 0
                      ? () => _jumpTo(_rounds[_roundIndex - 1].start)
                      : null,
                  icon: Icon(Icons.skip_previous,
                      color: _roundIndex > 0 ? kTextSecondary : kTextFaint,
                      size: 30),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  key: const Key('clip_listen_play'),
                  onPressed: _playing ? _pause : _play,
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                      color: kOnPrimary, size: 24),
                  label: Text(_playing ? '暂停' : (_finished ? '再听一遍' : '播放'),
                      style: TextStyle(color: kOnPrimary, fontSize: 14)),
                ),
                const SizedBox(width: 6),
                IconButton(
                  key: const Key('clip_listen_next'),
                  tooltip: '下一个词块',
                  onPressed: _roundIndex + 1 < _rounds.length
                      ? () => _jumpTo(_rounds[_roundIndex + 1].start)
                      : null,
                  icon: Icon(Icons.skip_next,
                      color: _roundIndex + 1 < _rounds.length
                          ? kTextSecondary
                          : kTextFaint,
                      size: 30),
                ),
                IconButton(
                  key: const Key('clip_listen_replay'),
                  tooltip: '本词块重听',
                  onPressed: () => _jumpTo(_rounds[_roundIndex].start),
                  icon: Icon(Icons.replay, color: kPrimary, size: 22),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final (i, r) in _rounds.indexed) ...[
              if (i > 0) const SizedBox(height: 6),
              InkWell(
                key: Key('clip_listen_round_$i'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => _jumpTo(r.start),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: i == _roundIndex
                        ? kPrimary.withValues(alpha: 0.10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: i == _roundIndex
                            ? kPrimary.withValues(alpha: 0.45)
                            : kBorder.withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.chunk.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: kText,
                                    fontSize: 14,
                                    fontWeight: i == _roundIndex
                                        ? FontWeight.w700
                                        : FontWeight.w500)),
                            if (r.chunk.kind.trim().isNotEmpty) ...[
                              const SizedBox(height: 1),
                              Text(r.chunk.kind,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: kTextFaint, fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                      if (i == _roundIndex && _playing)
                        Icon(Icons.graphic_eq, color: kPrimary, size: 16),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kCardAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kBorderSoft),
              ),
              child: Text(
                  '联动只是「换一种方式听」。词块还在词块库和你的英语本里，学习进度与复习排期都没有变化。',
                  style:
                      TextStyle(color: kTextMuted, fontSize: 11, height: 1.45)),
            ),
          ],
        ],
      ),
    );
  }
}

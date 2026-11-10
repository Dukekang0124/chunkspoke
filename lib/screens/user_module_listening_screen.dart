import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/loaders.dart';
import '../services/user_package_store.dart';
import '../ui/theme.dart';
import 'user_package_detail_screen.dart';

/// ASR-234：磨耳朵 ↔「我的英语本」的最小诚实桥接。
///
/// 只做一件事：用端侧 TTS 顺序朗读你自己存进来的句子。
/// 结构性边界（不靠自觉）：
///  · **不写库**：不改资产态、不排复习、不记会话，退出即停；
///  · **不动收听文章**：没有把 user 块塞进 `ListeningPack`（那要改官方 schema），
///    这里只是把同一批内容换一种「听」的方式再走一遍；
///  · **不产生官方计数**：全程没有 `user:` 行的读写。
///
/// 入口：磨耳朵首页「我的英语本 · 也能听」；出口：回六步学习 / 本子详情。
class UserModuleListeningScreen extends StatefulWidget {
  const UserModuleListeningScreen({super.key, required this.rec});

  final UserPackageRecord rec;

  @override
  State<UserModuleListeningScreen> createState() =>
      _UserModuleListeningScreenState();
}

class _UserModuleListeningScreenState extends State<UserModuleListeningScreen> {
  late final List<_ListenLine> _lines = [
    for (final e in widget.rec.entries)
      _ListenLine(text: e.sentenceSourceText ?? e.front, back: e.back),
  ];

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

  _ListenLine? get _current =>
      _lines.isEmpty ? null : _lines[_index.clamp(0, _lines.length - 1)];

  Future<void> _play() async {
    if (_playing || _lines.isEmpty) return;
    final tts = _tts;
    if (tts == null) return;
    final token = ++_runToken;
    setState(() {
      _playing = true;
      _finished = false;
      if (_index >= _lines.length) _index = 0;
    });
    while (mounted && token == _runToken && _playing) {
      final line = _lines[_index];
      if (line.text.trim().isNotEmpty) {
        final ok = await tts.speakAndWait(line.text);
        if (!mounted || token != _runToken || !_playing) return;
        if (!ok) {
          setState(() => _playing = false);
          _toast('这台设备的语音引擎没出声，去「设置 → 声音」检查一下再试。');
          return;
        }
      }
      // 句间留一点气口，听感更像「磨耳朵」而不是连珠炮。
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (!mounted || token != _runToken || !_playing) return;
      if (_index + 1 >= _lines.length) {
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

  Future<void> _jump(int i) async {
    if (i < 0 || i >= _lines.length) return;
    final wasPlaying = _playing;
    await _pause();
    if (!mounted) return;
    setState(() {
      _index = i;
      _finished = false;
    });
    if (wasPlaying) await _play();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), duration: const Duration(milliseconds: 2200)));
  }

  Future<void> _openPractice() async {
    await _pause();
    if (!mounted) return;
    await UserPackageDetailScreen.openPractice(context, widget.rec);
  }

  Future<void> _openDetail() async {
    await _pause();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            UserPackageDetailScreen(moduleKey: widget.rec.moduleKey)));
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      appBar: AppBar(title: Text('听 · ${widget.rec.moduleName}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
        children: [
          Text('听你自己存的句子',
              style: TextStyle(
                  color: kText, fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('只念给你听，不改学习进度、不排复习，也不算进官方的数。',
              style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.45)),
          const SizedBox(height: 14),
          if (current == null)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                  color: kCard, borderRadius: BorderRadius.circular(14)),
              child: Text('这本里还没有句子。',
                  style: TextStyle(color: kTextMuted, fontSize: 13)),
            )
          else ...[
            Container(
              key: const Key('userlisten_current'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: (_playing ? kPrimary : kBorder).withValues(alpha: 0.6)),
              ),
              child: Column(
                children: [
                  Text(current.text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: kText,
                          fontSize: 21,
                          height: 1.35,
                          fontWeight: FontWeight.w700)),
                  if (current.back.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(current.back,
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: kTextSecondary, fontSize: 13)),
                  ],
                  const SizedBox(height: 10),
                  Text(
                      '${_index + 1} / ${_lines.length}'
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
                  key: const Key('userlisten_prev'),
                  tooltip: '上一句',
                  onPressed: _index > 0 ? () => _jump(_index - 1) : null,
                  icon: Icon(Icons.skip_previous,
                      color: _index > 0 ? kTextSecondary : kTextFaint,
                      size: 30),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  key: const Key('userlisten_play'),
                  onPressed: _playing ? _pause : _play,
                  icon: Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      color: kOnPrimary,
                      size: 24),
                  label: Text(_playing ? '暂停' : (_finished ? '再听一遍' : '播放'),
                      style: TextStyle(color: kOnPrimary, fontSize: 14)),
                ),
                const SizedBox(width: 6),
                IconButton(
                  key: const Key('userlisten_next'),
                  tooltip: '下一句',
                  onPressed: _index + 1 < _lines.length
                      ? () => _jump(_index + 1)
                      : null,
                  icon: Icon(Icons.skip_next,
                      color: _index + 1 < _lines.length
                          ? kTextSecondary
                          : kTextFaint,
                      size: 30),
                ),
                IconButton(
                  key: const Key('userlisten_replay'),
                  tooltip: '本句重听',
                  onPressed: () => _jump(_index),
                  icon: Icon(Icons.replay, color: kPrimary, size: 22),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final (i, l) in _lines.indexed) ...[
              if (i > 0) const SizedBox(height: 6),
              InkWell(
                key: Key('userlisten_line_$i'),
                borderRadius: BorderRadius.circular(10),
                onTap: () => _jump(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: i == _index
                        ? kPrimary.withValues(alpha: 0.10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: i == _index
                            ? kPrimary.withValues(alpha: 0.45)
                            : kBorder.withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: kText,
                                    fontSize: 14,
                                    fontWeight: i == _index
                                        ? FontWeight.w700
                                        : FontWeight.w500)),
                            if (l.back.trim().isNotEmpty) ...[
                              const SizedBox(height: 1),
                              Text(l.back,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: kTextFaint, fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                      if (i == _index && _playing)
                        Icon(Icons.graphic_eq, color: kPrimary, size: 16),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const Key('userlisten_go_practice'),
                    onPressed: _openPractice,
                    child: Text('去练习',
                        style: TextStyle(color: kOnPrimary, fontSize: 14)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    key: const Key('userlisten_go_detail'),
                    onPressed: _openDetail,
                    child: Text('看这本',
                        style: TextStyle(color: kPrimary, fontSize: 14)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ListenLine {
  final String text;
  final String back;
  const _ListenLine({required this.text, required this.back});
}

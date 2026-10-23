import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/learning_flow.dart';
import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/feedback.dart';

class ListenPickResult {
  final int hits;
  final int rounds;
  final int attempts;

  const ListenPickResult({
    required this.hits,
    required this.rounds,
    required this.attempts,
  });

  bool get star => listenStar(hits, rounds) == 1;
}

/// ② 听辨：同一词块按 2~3 档语速播放（复习 2 轮、新学 3 轮），
/// 每轮从 3 个词块选项中选出听到的那一块。首猜命中计 1 轮；
/// 点错不判死，给一次重听机会，连续错两次才标出答案。
class ListenPickStep extends StatefulWidget {
  final Chunk chunk;
  final Level level;
  final int rounds;
  final void Function(ListenPickResult result) onDone;

  const ListenPickStep({
    required this.chunk,
    required this.level,
    required this.onDone,
    this.rounds = 3,
    super.key,
  });

  @override
  State<ListenPickStep> createState() => _ListenPickStepState();
}

class _ListenPickStepState extends State<ListenPickStep> {
  late final List<double> _rates;
  late List<String> _options;
  int _round = 0;
  int _hits = 0;
  int _attempts = 0;
  int _wrongThisRound = 0;
  bool _roundPassed = false;
  bool _revealed = false;
  bool _roundMissed = false;
  String? _wrongText;
  double _shake = 0;

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);
  double get _rate => _rates[_round.clamp(0, _rates.length - 1)];

  String get _speedLabel {
    if (_rate <= kListenSlowRate + 0.001) return '慢速';
    if (_rate >= kListenFastRate - 0.001) return '快速';
    return '常速';
  }

  @override
  void initState() {
    super.initState();
    _rates = listenRates(reviewMode: widget.rounds <= 2);
    _buildOptions();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play();
    });
  }

  void _buildOptions() {
    final target = widget.chunk.text;
    final content = Provider.of<ContentPack>(context, listen: false);
    final others = <String>{
      for (final lv in content.levels)
        for (final c in lv.chunks)
          if (c.text != target) c.text,
      ...widget.level.chunks
          .where((c) => c.text != target)
          .map((c) => c.text),
    }.toList()
      ..shuffle();
    _options = [target, ...others.take(2)]..shuffle();
  }

  /// 慢/常/快速走系统引擎；系统引擎不可用时退回默认语速（不阻断听辨）。
  Future<void> _play() async {
    final ok = await _tts.speakAtRate(widget.chunk.text, _rate);
    if (!ok && mounted) {
      speakOrHint(context, _tts, widget.chunk.text);
    }
  }

  void _pick(String s) {
    if (_roundPassed) return;
    if (s == widget.chunk.text) {
      chimeCorrect();
      if (_wrongThisRound == 0) _hits++;
      setState(() => _roundPassed = true);
      return;
    }
    if (_revealed) return;
    buzzWrong();
    _attempts++;
    _wrongThisRound++;
    setState(() {
      _wrongText = s;
      _shake = 10;
      if (_wrongThisRound >= 2) {
        _revealed = true;
        _roundMissed = true;
      }
    });
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _shake = 0);
    });
  }

  void _nextRound() {
    if (_round < _rates.length - 1) {
      setState(() {
        _round++;
        _roundPassed = false;
        _revealed = false;
        _roundMissed = false;
        _wrongThisRound = 0;
        _wrongText = null;
        _buildOptions();
      });
      _play();
      return;
    }
    widget.onDone(ListenPickResult(
      hits: _hits,
      rounds: _rates.length,
      attempts: _attempts + _rates.length,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final total = _rates.length;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Text('听辨 · 第 ${_round + 1}/$total 轮',
                  style: const TextStyle(
                      color: kPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: kPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: kPrimary.withValues(alpha: 0.4)),
                ),
                child: Text(_speedLabel,
                    style: const TextStyle(color: kPrimary, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('听音频，选出你听到的「词块」',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          IconButton(
            icon: const Icon(Icons.volume_up, color: kPrimary, size: 40),
            onPressed: _play,
          ),
          if (_roundPassed) const _RoundBanner(
            icon: Icons.check_circle,
            color: kUnlocked,
            text: '这轮听对了！',
          ) else if (_revealed) const _RoundBanner(
            icon: Icons.lightbulb,
            color: kPrimary,
            text: '没听出来也没关系，答案已标出，记住它',
          ) else if (_wrongThisRound > 0) const _RoundBanner(
            icon: Icons.hearing,
            color: kPrimary,
            text: '差一点，再听一遍试试',
          ),
          const SizedBox(height: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            transform: Matrix4.translationValues(_shake, 0, 0),
            child: Column(
              children: _options
                  .map((s) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: GestureDetector(
                          onTap: () => _pick(s),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _roundPassed && s == widget.chunk.text
                                    ? kUnlocked
                                    : (_revealed && s == widget.chunk.text
                                        ? kUnlocked
                                        : (_revealed && s == _wrongText
                                            ? Colors.redAccent
                                            : Colors.white24)),
                                width: (_roundPassed || _revealed) &&
                                        s == widget.chunk.text
                                    ? 2
                                    : 1,
                              ),
                              color: (_roundPassed || _revealed) &&
                                      s == widget.chunk.text
                                  ? kUnlocked.withValues(alpha: 0.12)
                                  : kBg.withValues(alpha: 0.5),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if ((_roundPassed || _revealed) &&
                                    s == widget.chunk.text)
                                  const Icon(Icons.check_circle,
                                      color: kUnlocked, size: 18),
                                if (_revealed && s == _wrongText)
                                  const Icon(Icons.close,
                                      color: Colors.redAccent, size: 18),
                                if ((_roundPassed || _revealed) &&
                                    s == widget.chunk.text)
                                  const SizedBox(width: 6),
                                Text(s,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 17)),
                              ],
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          if (_roundMissed && !_roundPassed)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('答案已标出，记住它，点下方按钮继续',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ),
          const Spacer(),
          if (_roundPassed || _revealed)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                // 未听出的一轮不计命中，直接进入下一轮。
                onPressed: _nextRound,
                child: Text(
                    _round < total - 1
                        ? '下一轮（${_nextSpeedLabel()}）'
                        : '完成听辨 · 下一步',
                    style: const TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String _nextSpeedLabel() {
    final next = _rates[(_round + 1).clamp(0, _rates.length - 1)];
    if (next <= kListenSlowRate + 0.001) return '慢速';
    if (next >= kListenFastRate - 0.001) return '快速';
    return '常速';
  }
}

class _RoundBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _RoundBanner(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      );
}

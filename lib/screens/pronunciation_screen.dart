import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/pronunciation_score.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../ui/pron_result_card.dart';
import '../ui/theme.dart';

/// 发音评测（1.5.9）：选句 → 跟读 → 本地引擎打分 → 逐词三档 + 整体分。
/// 能力型免费，纯本地（Vosk 离线识别），不联网、不落库、不计入掌握度。
/// 口径见 `验收-v1.5.9/发音评测-口径-1.5.9.md`。
class PronunciationScreen extends StatefulWidget {
  const PronunciationScreen({super.key});

  @override
  State<PronunciationScreen> createState() => _PronunciationScreenState();
}

class _PronunciationScreenState extends State<PronunciationScreen> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();

  TargetSentence? _selected;
  PronScoreResult? _result;
  bool _ready = false;
  bool _recording = false;
  bool _thinking = false;
  bool _engineFailed = false;
  bool _permBlocked = false;
  double _level = 0;
  DateTime? _startedAt;
  String? _recPath;
  StreamSubscription<double>? _levelSub;

  @override
  void dispose() {
    _levelSub?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _speakDemo() async {
    final s = _selected;
    if (s == null) return;
    await Provider.of<TtsService>(context, listen: false).speak(s.text);
  }

  Future<void> _toggle() async {
    if (_thinking) return;
    if (_recording) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    final perm = await _rec.ensurePermission();
    if (!mounted) return;
    if (perm != MicPerm.granted) {
      setState(() {
        _permBlocked = true;
        _ready = false;
      });
      return;
    }
    if (!_ready) {
      final ok = await _speech.initVosk();
      if (!mounted) return;
      if (!ok) {
        setState(() => _engineFailed = true);
        return;
      }
      _ready = true;
    }
    // 防回声自吞：先停掉朗读/回放。
    await Provider.of<TtsService>(context, listen: false).stop();
    await _rec.stopPlay();
    final path = await _rec.start();
    if (!mounted) return;
    if (path == null) {
      _toast('录音不可用，请检查麦克风');
      return;
    }
    _recPath = path;
    _startedAt = DateTime.now();
    _levelSub = _rec.levels.listen((v) {
      if (mounted) setState(() => _level = v.clamp(0.0, 1.0));
    });
    setState(() {
      _recording = true;
      _result = null;
      _permBlocked = false;
      _engineFailed = false;
    });
  }

  Future<void> _stop() async {
    final s = _selected;
    if (s == null) return;
    setState(() => _thinking = true);
    // 满 2 秒真实采集宽限：不把「秒判没听到」当作识别失败。
    final el = DateTime.now().difference(_startedAt ?? DateTime.now());
    if (el < const Duration(seconds: 2)) {
      await Future.delayed(const Duration(seconds: 2) - el);
    }
    final path = await _rec.stop();
    await _levelSub?.cancel();
    _levelSub = null;
    if (!mounted) return;
    final recPath = path ?? _recPath;
    if (recPath == null) {
      setState(() {
        _thinking = false;
        _recording = false;
      });
      _toast('没有拿到录音，请重试');
      return;
    }
    final r = await _speech.recognizeOpen(recPath);
    final dur = await _speech.durationSec(recPath);
    final res = scorePronunciation(
      target: s.text,
      recognized: r.text,
      confidence: r.confidence,
      durationSec: dur,
    );
    if (!mounted) return;
    setState(() {
      _thinking = false;
      _recording = false;
      _level = 0;
      _result = res;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: Text(_selected == null ? '发音评测' : '跟读这一句'),
        backgroundColor: kBg,
        foregroundColor: kOnPrimary,
      ),
      body: _selected == null ? _buildPicker() : _buildPractice(),
    );
  }

  Widget _buildPicker() {
    final content = Provider.of<ContentPack>(context);
    final levels = content.levels
        .where((lv) => lv.sentences.isNotEmpty)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '选一句话，正常拿着手机读一遍。\n打分全在本机完成，不联网、不上传，也不影响你的学习进度。',
          style: TextStyle(color: kTextMuted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 12),
        if (levels.isEmpty)
          Text('内容包里还没有可评测的句子', style: TextStyle(color: kTextFaint)),
        for (final lv in levels) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(lv.theme,
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          for (final s in lv.sentences)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                  color: kCard, borderRadius: BorderRadius.circular(12)),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  title: Text(s.text,
                      style:
                          TextStyle(color: kText, fontSize: 15)),
                  subtitle: s.meaningCN.isEmpty
                      ? null
                      : Text(s.meaningCN,
                          style: TextStyle(
                              color: kTextFaint, fontSize: 12)),
                  trailing: Icon(Icons.chevron_right,
                      color: kTextFaint, size: 20),
                  onTap: () => setState(() {
                    _selected = s;
                    _result = null;
                  }),
                ),
              ),
            ),
        ],
        const SizedBox(height: 8),
        Text('绿=说对了　黄=能听出（缩读/连读/虚词）　红=再试试',
            style: TextStyle(color: kBorderStrong, fontSize: 11)),
      ],
    );
  }

  Widget _buildPractice() {
    final s = _selected!;
    final r = _result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: kCard, borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.text,
                  style: TextStyle(
                      color: kText,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              if (s.meaningCN.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(s.meaningCN,
                    style:
                        TextStyle(color: kTextMuted, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _recording || _thinking ? null : _speakDemo,
                    icon: const Icon(Icons.volume_up, size: 18),
                    label: const Text('听示范'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: kPrimary,
                        side:
                            BorderSide(color: kPrimary.withValues(alpha: 0.5))),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _recording || _thinking
                        ? null
                        : () => setState(() {
                              _selected = null;
                              _result = null;
                            }),
                    child: Text('换一句',
                        style: TextStyle(color: kTextMuted)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: GestureDetector(
            onTap: _toggle,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _recording
                    ? kError.withValues(alpha: 0.22)
                    : kPrimary.withValues(alpha: 0.18),
                border:
                    Border.all(color: _recording ? kError : kPrimary, width: 2),
              ),
              child: Icon(
                _recording ? Icons.stop : Icons.mic,
                size: 40,
                color: _recording ? kError : kPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            _thinking
                ? '正在识别…'
                : _recording
                    ? '正在录音，点一下结束'
                    : '点一下开始跟读',
            style: TextStyle(color: kTextMuted, fontSize: 13),
          ),
        ),
        if (_recording) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _level,
              minHeight: 4,
              backgroundColor: kBorder,
              valueColor: AlwaysStoppedAnimation(kPrimary),
            ),
          ),
        ],
        if (_permBlocked) ...[
          const SizedBox(height: 12),
          _hintCard('没有麦克风权限', '在系统设置里允许「使用麦克风」后再回来。',
              action: '去设置', onAction: _rec.openSettings),
        ],
        if (_engineFailed) ...[
          const SizedBox(height: 12),
          _hintCard('识别引擎没加载起来', '请杀掉 App 重开后再试；若反复失败，把机型和现象发给我们。'),
        ],
        if (r != null) ...[
          const SizedBox(height: 20),
          PronResultCard(result: r),
        ],
      ],
    );
  }

  Widget _hintCard(String title, String sub,
          {String? action, Future<void> Function()? onAction}) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kError.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style:
                          TextStyle(color: kText, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(sub,
                      style: TextStyle(
                          color: kTextMuted, fontSize: 12, height: 1.4)),
                ],
              ),
            ),
            if (action != null && onAction != null)
              TextButton(
                onPressed: () => onAction(),
                child: Text(action,
                    style: TextStyle(color: kPrimary, fontSize: 13)),
              ),
          ],
        ),
      );
}

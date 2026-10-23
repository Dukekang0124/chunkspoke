import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/asr_guard.dart';
import '../services/crash_log.dart';
import '../services/learning_flow.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../ui/theme.dart';
import '../ui/feedback.dart';

/// ④ 定向替换：在目标句中把当前词块换成同类搭档，开口说出新句。
/// 双校验：骨架词有序覆盖率 ≥0.8 + 替代词命中；失败给重试/听标准/自评三条路，
/// 绝不因一次识别不佳裸判失败。
class SubstituteStep extends StatefulWidget {
  final Chunk chunk;
  final Level level;
  final SubstitutionPlan plan;
  final String meaningCN;
  final bool review;
  final void Function(int accuracy) onPass;
  final VoidCallback onSkip;

  const SubstituteStep({
    required this.chunk,
    required this.level,
    required this.plan,
    required this.onPass,
    required this.onSkip,
    this.meaningCN = '',
    this.review = false,
    super.key,
  });

  @override
  State<SubstituteStep> createState() => _SubstituteStepState();
}

class _SubstituteStepState extends State<SubstituteStep> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  late SubstitutionPlan _plan;
  bool _ready = false;
  bool _permBlocked = false;
  bool _listening = false;
  bool _thinking = false;
  bool _playing = false;
  String? _recPath;
  String _transcript = '';
  AsrGuardResult? _guard;
  SubstitutionVerdict? _verdict;
  SilenceAutoStop? _silence;
  int _attempts = 0;
  bool _showSelfEval = false;
  bool _passed = false;
  int _accuracy = 0;
  Timer? _playTimer;

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);
  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    _silence = SilenceAutoStop(onSilence: () {
      if (mounted && _listening) _stop();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _speakTarget();
    });
    _rec.ensurePermission().then((perm) async {
      if (!mounted) return;
      if (perm != MicPerm.granted) {
        setState(() => _permBlocked = true);
        return;
      }
      final ok = await _speech.initVosk();
      if (!mounted) return;
      setState(() {
        _ready = ok;
        _showSelfEval = !ok;
      });
    }).catchError((e, st) {
      CrashLog.write('Substitute.perm: $e', st);
      if (mounted) setState(() => _permBlocked = true);
    });
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _silence?.detach();
    if (_listening) _rec.stop();
    _rec.stopPlay();
    super.dispose();
  }

  Future<void> _speakTarget() async {
    if (_listening || _thinking) return;
    final ok = await _tts.speak(_plan.replacedSentence);
    if (!ok && mounted) speakOrHint(context, _tts, _plan.replacedSentence);
  }

  List<String> get _phrases => <String>{
        _plan.replacedSentence,
        _plan.baseSentence,
        widget.chunk.text,
        ..._plan.replacementOptions,
      }.toList(growable: false);

  String get _guardTarget =>
      _plan.isFallback ? _plan.chunkText : _plan.replacement;

  Future<void> _start() async {
    if (_permBlocked || !_ready || _passed) return;
    // 防回声自吞：录音开始前先停掉 TTS / 本地回放。
    await _tts.stop();
    await _rec.stopPlay();
    final path = await _rec.start();
    if (path == null) {
      setState(() => _showSelfEval = true);
      return;
    }
    if (!mounted) {
      await _rec.stop();
      return;
    }
    _silence?.attach(_rec.levels);
    setState(() {
      _recPath = path;
      _listening = true;
      _thinking = false;
      _transcript = '';
      _guard = null;
      _verdict = null;
    });
  }

  Future<void> _stop() async {
    if (!_listening) return;
    _silence?.detach();
    final start = DateTime.now();
    setState(() {
      _listening = false;
      _thinking = true;
    });
    final path = await _rec.stop();
    if (path != null) _recPath = path;
    final usePath = path ?? _recPath;
    if (usePath == null) {
      if (mounted) setState(() { _thinking = false; _showSelfEval = true; });
      return;
    }
    // 至少留 0.4s 录音，避免点按即停的无效样本。
    final elapsed = DateTime.now().difference(start);
    if (elapsed < const Duration(milliseconds: 400)) {
      await Future.delayed(const Duration(milliseconds: 400) - elapsed);
    }
    String text = '';
    List<double>? confs;
    if (await _speech.initVosk()) {
      final r = await _speech.recognizeOpen(usePath, e2ePhrases: _phrases);
      text = r.text;
      confs = r.wordConfidences;
    } else if (_p.azureKey != null && _p.azureRegion != null) {
      text = await _speech.transcribeAzure(
          usePath, _p.azureKey!, _p.azureRegion!);
    }
    if (!mounted) return;
    final g = guardAsr(
      raw: text,
      wordConfidences: confs,
      targetBlock: _guardTarget,
    );
    final v = judgeSubstitution(recognized: text, plan: _plan);
    final pass = g.ok && v.pass;
    if (pass) HapticFeedback.mediumImpact();
    setState(() {
      _thinking = false;
      _transcript = text;
      _guard = g;
      _verdict = v;
      if (pass) {
        // 识别通过也必须进入成功态，否则界面停在录音入口、没有“下一步”。
        _passed = true;
        _accuracy = 100;
      } else {
        _attempts++;
        if (_attempts >= 2) _showSelfEval = true;
      }
    });
  }

  void _selfConfirm() {
    setState(() {
      _passed = true;
      _accuracy = 100;
    });
    _speakTarget();
  }

  void _confirmPass() {
    widget.onPass(_accuracy > 0 ? _accuracy : 85);
  }

  Widget _highlighted(String text, String phrase, Color color,
      {bool strike = false}) {
    final idx = text.toLowerCase().indexOf(phrase.toLowerCase());
    if (idx < 0) {
      return Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 19));
    }
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: const TextStyle(color: Colors.white, fontSize: 19),
        children: [
          TextSpan(text: text.substring(0, idx)),
          TextSpan(
            text: text.substring(idx, idx + phrase.length),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              decoration: strike ? TextDecoration.lineThrough : null,
            ),
          ),
          TextSpan(text: text.substring(idx + phrase.length)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = _verdict;
    final g = _guard;
    final av = (g != null && v != null)
        ? asrVerdictFor(
            guard: g,
            targetHit: v.pass,
            targetLabel: _guardTarget,
            passText: '✓ 替换成功，句子说完整了',
          )
        : null;
    final hint = av == null
        ? (v == null ? null : substitutionHint(v, _plan))
        : (av.kind == AsrVerdictKind.notUsed
            ? substitutionHint(v!, _plan)
            : av.text);
    final hintColor =
        av?.kind == AsrVerdictKind.pass ? kUnlocked : kPrimary;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
                widget.review ? '复习 · 定向替换' : '第 5/6 步 · 定向替换',
                style: const TextStyle(
                    color: kPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kBg.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              children: [
                _highlighted(
                    _plan.baseSentence, _plan.chunkText, Colors.white38,
                    strike: true),
                if (!_plan.isFallback) ...[
                  const SizedBox(height: 8),
                  const Icon(Icons.arrow_downward,
                      color: kPrimary, size: 16),
                  const SizedBox(height: 8),
                  _highlighted(
                      _plan.replacedSentence, _plan.replacement, kPrimary),
                ],
              ],
            ),
          ),
          if (_plan.replacementOptions.length > 1) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: _plan.replacementOptions.map((o) {
                final on = o == _plan.replacement;
                return ChoiceChip(
                  label: Text(o),
                  selected: on,
                  selectedColor: kPrimary,
                  backgroundColor: kCard,
                  labelStyle: TextStyle(
                      color: on ? Colors.black87 : Colors.white70,
                      fontSize: 13),
                  onSelected: (_) => setState(() {
                    _plan = _plan.withReplacement(o);
                    _verdict = null;
                    _guard = null;
                    _transcript = '';
                  }),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _speakTarget,
                icon: const Icon(Icons.volume_up, color: kPrimary, size: 18),
                label: const Text('听参考',
                    style: TextStyle(color: kPrimary, fontSize: 13)),
              ),
              TextButton.icon(
                onPressed: () {
                  if (_playing) {
                    _playTimer?.cancel();
                    _rec.stopPlay();
                    setState(() => _playing = false);
                  } else if (_recPath != null) {
                    _rec.play(_recPath!);
                    setState(() => _playing = true);
                    _playTimer?.cancel();
                    _playTimer = Timer(const Duration(seconds: 8),
                        () { if (mounted) setState(() => _playing = false); });
                  }
                },
                icon: Icon(_playing ? Icons.stop : Icons.replay,
                    color: kPrimary, size: 18),
                label: Text(_playing ? '停止回放' : '回放我的',
                    style:
                        const TextStyle(color: kPrimary, fontSize: 13)),
              ),
            ],
          ),
          if (_plan.isFallback)
            const Text('这个词块暂时没有替换搭档，直接把它说进句子',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 4),
          Text(widget.meaningCN,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const Spacer(),
          if (_passed)
            Column(
              children: [
                const Text('替换成功，句子说完整了',
                    style: TextStyle(
                        color: kUnlocked,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                if (_transcript.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('你说：$_transcript',
                      key: const Key('substituteAsrRaw'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13)),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: kPrimary),
                    onPressed: _confirmPass,
                    child: const Text('完成替换 · 下一步',
                        style: TextStyle(color: Colors.black87)),
                  ),
                ),
              ],
            )
          else if (_thinking)
            const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: kPrimary),
                SizedBox(height: 8),
                Text('识别中…', style: TextStyle(color: Colors.white54)),
              ],
            )
          else if (_listening)
            Column(
              children: [
                const Text('正在录音 · 说完点停止',
                    style: TextStyle(color: kPrimary)),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _stop,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kPrimary.withValues(alpha: 0.2),
                      border: Border.all(color: kPrimary, width: 2),
                    ),
                    child: const Icon(Icons.stop, color: kPrimary, size: 36),
                  ),
                ),
              ],
            )
          else ...[
            if (_transcript.trim().isNotEmpty)
              Container(
                key: const Key('substituteAsrRaw'),
                width: double.infinity,
                padding: const EdgeInsets.all(9),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white24),
                ),
                child: Text('你说：$_transcript',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13)),
              ),
            if (hint != null)
              Text(hint,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: hintColor, fontSize: 13))
            else
              const Text('选好替换词，开口说出新句子',
                  style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            if (_permBlocked)
              const Text('麦克风未授权，可以先跟着读一遍（自评）',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12))
            else
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                ),
                onPressed: _ready ? _start : null,
                icon: const Icon(Icons.mic, color: Colors.black87, size: 20),
                label: const Text('开口说这句',
                    style: TextStyle(color: Colors.black87)),
              ),
            if (!_ready)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('识别引擎准备中…',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            if (_showSelfEval || _permBlocked || !_ready) ...[
              const SizedBox(height: 6),
              TextButton(
                onPressed: _selfConfirm,
                child: const Text('跟着读一遍，我说对了 →',
                    style: TextStyle(color: kPrimary, fontSize: 13)),
              ),
            ],
            TextButton(
              onPressed: widget.onSkip,
              child: Text(widget.review ? '先跳过这块，明天再来' : '跳过这一步',
                  style: const TextStyle(color: Colors.white38)),
            ),
          ],
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/asr_budget.dart';
import '../services/asr_guard.dart';
import '../services/crash_log.dart';
import '../services/learning_flow.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../ui/theme.dart';
import '../ui/labels.dart';
import '../ui/feedback.dart';
import '../ui/motion.dart';
import '../ui/permission_preprompt.dart';

/// ⑤ 自由造句 + 场景应用：用今天的词块说/写一句自己的话。
/// 宽松校验（用上词块 + 至少 3 词 + 有新增内容），通过后给母语者参考句对照。
class FreeUseStep extends StatefulWidget {
  final Chunk chunk;
  final Level level;
  final String referenceText;
  final String meaningCN;
  final void Function(int accuracy) onPass;
  final VoidCallback onSkip;

  const FreeUseStep({
    required this.chunk,
    required this.level,
    required this.onPass,
    required this.onSkip,
    this.referenceText = '',
    this.meaningCN = '',
    super.key,
  });

  @override
  State<FreeUseStep> createState() => _FreeUseStepState();
}

class _FreeUseStepState extends State<FreeUseStep> {
  final TextEditingController _controller = TextEditingController();
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  bool _micReady = false;
  bool _micBlocked = false;
  bool _listening = false;
  bool _thinking = false;
  FreeUseVerdict? _verdict;
  bool _showReference = false;
  bool _passed = false;
  String _asrRaw = '';
  AsrGuardResult? _guard;
  bool _fromVoice = false;
  bool _confirmedByUser = false; // S2：ASR 不确定时由用户点「就是这句」确认
  // M1：本条结果实际来自哪个后端（增强/云端降级时如实标注，不静默换引擎）。
  AsrSource? _asrSrc;
  String _thinkingText = '识别中…';
  SilenceAutoStop? _silence;

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);
  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _silence = SilenceAutoStop(onSilence: () {
      if (mounted && _listening) _toggleMic();
    });
    ensureMicWithPreprompt(context, _rec).then((perm) async {
      if (!mounted) return;
      if (perm != MicPerm.granted) {
        setState(() => _micBlocked = true);
        return;
      }
      final ok = await _speech.initVosk();
      if (!mounted) return;
      setState(() => _micReady = ok);
    }).catchError((e, st) {
      CrashLog.write('FreeUse.perm: $e', st);
      if (mounted) setState(() => _micBlocked = true);
    });
  }

  @override
  void dispose() {
    _silence?.detach();
    if (_listening) _rec.stop();
    _rec.stopPlay();
    _controller.dispose();
    super.dispose();
  }

  void _check() {
    final v = judgeFreeUse(
        input: _controller.text, chunkText: widget.chunk.text);
    final guardOk = !_fromVoice || (_guard?.ok ?? false);
    setState(() {
      _verdict = v;
      if (!v.pass || !guardOk) _showReference = true;
    });
    if (v.pass && guardOk) {
      Motion.of(context).success();
      setState(() => _passed = true);
    }
  }

  /// S2：用户确认「我听到的就是这句」→ 按用上词块通过（明确标注按确认，不伪装成识别命中）。
  void _confirmHeard() {
    final v = _verdict;
    if (v == null || _passed) return;
    setState(() {
      _verdict = FreeUseVerdict(
          pass: true, chunkUsed: true, wordCount: v.wordCount, reason: 'ok');
      _confirmedByUser = true;
      _showReference = true;
    });
    Motion.of(context).success();
    setState(() => _passed = true);
  }

  /// S2：不认可这次识别 → 清掉本次结果并立刻重录。
  void _retryHeard() {
    setState(() {
      _verdict = null;
      _guard = null;
      _asrRaw = '';
      _fromVoice = false;
      _confirmedByUser = false;
      _asrSrc = null;
      _showReference = false;
    });
    _toggleMic();
  }

  /// M1：本地增强（zipformer）优先、云端 Azure 兜底的第二次识别。
  /// 只有拿到非空结果才覆盖展示；来源写进 [_asrSrc]，UI 如实标注。
  Future<void> _retryWithFallback(String path,
      {required bool skipEnhanced}) async {
    if (!mounted) return;
    setState(() {
      _thinking = true;
      _thinkingText = '正在用更精准的方式再听一遍…';
    });
    final retry = await _speech.retryOpenWithFallback(
      wavPath: path,
      target: widget.chunk.text,
      keywords: asrKeywords(widget.chunk.text),
      skipEnhanced: skipEnhanced,
      azureKey: _p.azureKey,
      azureRegion: _p.azureRegion,
    );
    if (!mounted) return;
    if (retry == null) {
      setState(() {
        _thinking = false;
        _thinkingText = '识别中…';
      });
      return;
    }
    final g = guardAsr(
      raw: retry.text,
      wordConfidences: retry.wordConfidences,
      targetBlock: widget.chunk.text,
      checkChunkStack: true,
    );
    setState(() {
      _thinking = false;
      _thinkingText = '识别中…';
      _asrSrc = retry.source;
      _asrRaw = retry.text;
      _guard = g;
      _fromVoice = true;
      _confirmedByUser = false;
      if (g.ok) _controller.text = retry.text;
    });
    _check();
  }

  /// M1：来源标注——只有降级重识才加后缀，Vosk 默认路径不加噪音。
  String _srcLabel(AsrSource? s) {
    if (s == AsrSource.enhanced) return '（增强识别）';
    if (s == AsrSource.azure) return '（云端识别）';
    return '';
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      _silence?.detach();
      setState(() {
        _listening = false;
        _thinking = true;
      });
      final path = await _rec.stop();
      if (path == null) {
        if (mounted) setState(() { _thinking = false; _micBlocked = true; });
        return;
      }
      String text = '';
      List<double>? confs;
      AsrSource? src;
      if (await _speech.initVosk()) {
        // ASR-213 P0-1：解码预算，与跟读同一条口径（单源见 asr_budget.dart）。
        final r = await recognizeWithinBudget(() => _speech.recognizeOpen(path,
            e2ePhrases: [widget.referenceText, widget.chunk.text]));
        // S1：多候选里挑一条真用上词块的（小模型常把 what 听成 ud，
        // 但第 2/3 条候选往往是对的）。挑不回来则退回主候选，交给 S0/S2。
        text = pickChunkCandidate(
            [r.text, ...r.alternatives], widget.chunk.text);
        confs = r.wordConfidences;
        src = _speech.lastOpenSource;
      } else if (_p.azureKey != null && _p.azureRegion != null) {
        text = await _speech.transcribeAzure(
            path, _p.azureKey!, _p.azureRegion!);
        src = AsrSource.azure;
      }
      if (!mounted) return;
      final g = guardAsr(
        raw: text,
        wordConfidences: confs,
        targetBlock: widget.chunk.text,
        checkChunkStack: true,
      );
      setState(() {
        _thinking = false;
        _thinkingText = '识别中…';
        _asrSrc = src;
        _asrRaw = text;
        _guard = g;
        _fromVoice = true;
        if (g.ok) _controller.text = text;
      });
      _check();
      // M1：判定没过且不是「说得太短」→ 本地增强优先、云端兜底再听一遍。
      // 两条路都不可用时立即返回 null，不额外等待，也不改动原结果。
      final reason = _verdict?.reason;
      if (!_passed && reason != 'tooShort' && reason != 'empty') {
        await _retryWithFallback(path, skipEnhanced: src == AsrSource.enhanced);
      }
      return;
    }
    if (_micBlocked || !_micReady) return;
    // 防回声自吞：录音开始前先停掉 TTS / 本地回放。
    await _tts.stop();
    await _rec.stopPlay();
    final path = await _rec.start();
    if (!mounted) return;
    if (path == null) {
      setState(() => _micBlocked = true);
      return;
    }
    _silence?.attach(_rec.levels);
    setState(() {
      _listening = true;
      _verdict = null;
      _passed = false;
      _showReference = false;
      _asrRaw = '';
      _guard = null;
      _fromVoice = false;
      _confirmedByUser = false;
      _asrSrc = null;
      _thinkingText = '识别中…';
    });
  }

  Future<void> _speakReference() async {
    if (_listening || _thinking) return;
    final text = widget.referenceText.trim().isEmpty
        ? widget.chunk.text
        : widget.referenceText;
    final ok = await _tts.speak(text);
    if (!ok && mounted) speakOrHint(context, _tts, text);
  }

  @override
  Widget build(BuildContext context) {
    final v = _verdict;
    // uncertain 不套 asrVerdictFor 的「✗ 没用上」——那会与下方确认卡自相矛盾。
    final av = (_fromVoice &&
            _guard != null &&
            v != null &&
            v.reason != 'uncertain')
        ? asrVerdictFor(
            guard: _guard!,
            targetHit: v.pass,
            targetLabel: widget.chunk.text,
            passText: _confirmedByUser ? '✓ 目标块用上了（按你的确认）' : '✓ 目标块用上了',
          )
        : null;
    final needConfirm = v != null &&
        v.reason == 'uncertain' &&
        _fromVoice &&
        !_passed &&
        (_guard?.ok ?? false);
    final ok = av != null ? av.kind == AsrVerdictKind.pass : (v?.pass ?? false);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text('第 6/6 步 · 自由造句',
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kBg.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: kBorderStrong),
                    ),
                    child: Column(
                      children: [
                        Text('用「${widget.chunk.text}」说一句自己的话',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: kText,
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('场景：${sceneCn(widget.level.theme)} · '
                            '${widget.chunk.meaningCN}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: kTextMuted, fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _controller,
                    enabled: !_passed,
                    maxLines: 2,
                    minLines: 1,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _check(),
                    onChanged: (_) {
                      // 用户手动改字后按文本输入判定（原始识别行仍保留展示）。
                      if (_fromVoice) setState(() => _fromVoice = false);
                    },
                    style: TextStyle(color: kText, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '用英文写下或说出你的句子，把词块放进今天的场景…',
                      hintStyle: TextStyle(
                          color: kTextFaint, fontSize: 13),
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: kBorderStrong),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: kBorderStrong),
                      ),
                    ),
                  ),
                  if (_asrRaw.isNotEmpty)
                    Container(
                      key: const Key('freeUseAsrRaw'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: kCard,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kBorderStrong),
                      ),
                      child: Text(
                          '你说：$_asrRaw${_srcLabel(_asrSrc)}',
                          style: TextStyle(
                              color: kTextSecondary, fontSize: 13)),
                    ),
                  const SizedBox(height: 10),
                  if (v != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                            ok
                                ? Icons.check_circle
                                : (av?.kind == AsrVerdictKind.notUsed
                                    ? Icons.cancel_outlined
                                    : Icons.lightbulb_outline),
                            color: ok ? kUnlocked : kPrimary,
                            size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                              av?.text ?? freeUseHint(v, widget.chunk.text),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: ok ? kUnlocked : kPrimary,
                                  fontSize: 13)),
                        ),
                      ],
                    ),
                  if (needConfirm) ...[
                    const SizedBox(height: 10),
                    _confirmHeardCard(),
                  ],
                  if (_showReference && !_passed) ...[
                    const SizedBox(height: 10),
                    _referenceCard(),
                  ],
                  if (_passed) ...[
                    const SizedBox(height: 10),
                    _referenceCard(),
                  ],
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
          if (!_passed) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('语速适中、吐字清晰识别更准',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextFaint, fontSize: 11)),
            ),
            Row(
              children: [
                Expanded(
                  child: Listener(
                    // §30.3-2 预卷：手指按下即起采（原生 400ms 环形缓冲），
                    // onPressed 进入正式录音时回灌缓冲；取消/3s 未开始由原生自释放。
                    onPointerDown: (_) {
                      if (!_listening && !_thinking && _micReady && !_micBlocked) {
                        _rec.arm();
                      }
                    },
                    onPointerCancel: (_) => _rec.disarm(),
                    child: OutlinedButton.icon(
                      onPressed:
                          (_micBlocked || !_micReady || _thinking) ? null : _toggleMic,
                      icon: Icon(_listening ? Icons.stop : Icons.mic,
                          color: _listening ? kPrimary : kTextSecondary, size: 18),
                      label: Text(
                          _thinking
                              ? _thinkingText
                              : (_listening ? '说完点这里' : '说出来'),
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                    onPressed: _check,
                    child: Text('检查句子',
                        style: TextStyle(color: kOnPrimary)),
                  ),
                ),
              ],
            ),
            if (_micBlocked)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('麦克风或识别不可用，直接打字也可以',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kTextFaint, fontSize: 11)),
              ),
            TextButton(
              onPressed: widget.onSkip,
              child: Text('跳过这一步',
                  style: TextStyle(color: kTextFaint, fontSize: 12)),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () => widget.onPass(100),
                child: Text('完成这一块',
                    style: TextStyle(
                        color: kOnPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _confirmHeardCard() => Container(
        key: const Key('freeUseConfirmCard'),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPrimary.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('我听到的是「$_asrRaw」',
                style: TextStyle(color: kTextSecondary, fontSize: 13)),
            const SizedBox(height: 4),
            Text('你是不是想说「${widget.chunk.text}」？',
                style: TextStyle(
                    color: kText, fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _retryHeard,
                    child: const Text('再说一遍',
                        style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                    onPressed: _confirmHeard,
                    child: Text('就是这句',
                        style: TextStyle(color: kOnPrimary, fontSize: 13)),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _referenceCard() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPrimary.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('母语者参考',
                style: TextStyle(color: kPrimary, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
                widget.referenceText.trim().isEmpty
                    ? widget.chunk.text
                    : widget.referenceText,
                style: TextStyle(color: kText, fontSize: 15)),
            if (widget.meaningCN.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(widget.meaningCN,
                  style:
                      TextStyle(color: kTextMuted, fontSize: 12)),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _speakReference,
                icon: Icon(Icons.volume_up, color: kPrimary, size: 16),
                label: Text('听参考',
                    style: TextStyle(color: kPrimary, fontSize: 12)),
              ),
            ),
          ],
        ),
      );
}

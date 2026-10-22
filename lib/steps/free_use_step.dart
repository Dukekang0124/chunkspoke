import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/crash_log.dart';
import '../services/learning_flow.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../ui/theme.dart';
import '../ui/labels.dart';
import '../ui/feedback.dart';

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

  TtsService get _tts => Provider.of<TtsService>(context, listen: false);
  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _rec.ensurePermission().then((perm) async {
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
    if (_listening) _rec.stop();
    _rec.stopPlay();
    _controller.dispose();
    super.dispose();
  }

  void _check() {
    final v = judgeFreeUse(
        input: _controller.text, chunkText: widget.chunk.text);
    setState(() {
      _verdict = v;
      if (!v.pass) _showReference = true;
    });
    if (v.pass) {
      HapticFeedback.mediumImpact();
      setState(() => _passed = true);
    }
  }

  Future<void> _toggleMic() async {
    if (_listening) {
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
      if (await _speech.initVosk()) {
        final r = await _speech.recognize(
            path, [widget.referenceText, widget.chunk.text]);
        text = r.text;
      } else if (_p.azureKey != null && _p.azureRegion != null) {
        text = await _speech.transcribeAzure(
            path, _p.azureKey!, _p.azureRegion!);
      }
      if (!mounted) return;
      if (text.trim().isNotEmpty) _controller.text = text;
      setState(() => _thinking = false);
      if (text.trim().isNotEmpty) {
        _check();
      } else {
        setState(() => _micBlocked = true);
      }
      return;
    }
    if (_micBlocked || !_micReady) return;
    final path = await _rec.start();
    if (!mounted) return;
    if (path == null) {
      setState(() => _micBlocked = true);
      return;
    }
    setState(() {
      _listening = true;
      _verdict = null;
      _passed = false;
      _showReference = false;
    });
  }

  Future<void> _speakReference() async {
    final text = widget.referenceText.trim().isEmpty
        ? widget.chunk.text
        : widget.referenceText;
    final ok = await _tts.speak(text);
    if (!ok && mounted) speakOrHint(context, _tts, text);
  }

  @override
  Widget build(BuildContext context) {
    final v = _verdict;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
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
                      color: kBg.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      children: [
                        Text('用「${widget.chunk.text}」说一句自己的话',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('场景：${sceneCn(widget.level.theme)} · '
                            '${widget.chunk.meaningCN}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
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
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '用英文写下或说出你的句子，把词块放进今天的场景…',
                      hintStyle: const TextStyle(
                          color: Colors.white38, fontSize: 13),
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (v != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                            v.pass
                                ? Icons.check_circle
                                : Icons.lightbulb_outline,
                            color: v.pass ? kUnlocked : kPrimary,
                            size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(freeUseHint(v, widget.chunk.text),
                              style: TextStyle(
                                  color: v.pass ? kUnlocked : kPrimary,
                                  fontSize: 13)),
                        ),
                      ],
                    ),
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
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        (_micBlocked || !_micReady || _thinking) ? null : _toggleMic,
                    icon: Icon(_listening ? Icons.stop : Icons.mic,
                        color: _listening ? kPrimary : Colors.white70, size: 18),
                    label: Text(
                        _thinking
                            ? '识别中…'
                            : (_listening ? '说完点这里' : '说出来'),
                        style: const TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                    onPressed: _check,
                    child: const Text('检查句子',
                        style: TextStyle(color: Colors.black87)),
                  ),
                ),
              ],
            ),
            if (_micBlocked)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('麦克风或识别不可用，直接打字也可以',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
              ),
            TextButton(
              onPressed: widget.onSkip,
              child: const Text('跳过这一步',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
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
                child: const Text('完成这一块',
                    style: TextStyle(
                        color: Colors.black87,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _referenceCard() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPrimary.withOpacity(0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('母语者参考',
                style: TextStyle(color: kPrimary, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
                widget.referenceText.trim().isEmpty
                    ? widget.chunk.text
                    : widget.referenceText,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
            if (widget.meaningCN.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(widget.meaningCN,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _speakReference,
                icon: const Icon(Icons.volume_up, color: kPrimary, size: 16),
                label: const Text('听参考',
                    style: TextStyle(color: kPrimary, fontSize: 12)),
              ),
            ),
          ],
        ),
      );
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// SAY 步骤（三层降级，真实优先）：
///  - L1：有 Azure Key+Region → 录音 → Azure 发音评测（三项分数）。
///  - L2：无 Key → speech_to_text 本地识别 → You said 回显 + Text Match 计分。
///  - L3：仅当 speech_to_text 真实初始化失败才出现（自确认兜底）。
class SayWidget extends StatefulWidget {
  final String sentence;
  final String levelId;
  final VoidCallback onDone;
  const SayWidget(
      {required this.sentence, required this.levelId, required this.onDone, super.key});

  @override
  State<SayWidget> createState() => _SayWidgetState();
}

class _SayWidgetState extends State<SayWidget> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  bool _hasAzure = false;
  bool _ready = false; // 录音/L2 初始化是否就绪
  bool _active = false; // 录音中 / 倾听中
  bool _thinking = false;
  String? _recPath;
  String _heard = '';
  SayOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    final p = Provider.of<ProgressService>(context, listen: false);
    _hasAzure = p.azureKey != null &&
        p.azureKey!.isNotEmpty &&
        p.azureRegion != null &&
        p.azureRegion!.isNotEmpty;
    if (_hasAzure) {
      _rec.init().then((v) => setState(() => _ready = v));
    } else {
      _speech.initLocal().then((ok) => setState(() => _ready = ok));
    }
    Provider.of<TtsService>(context, listen: false).speak(widget.sentence);
  }

  void _start() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    if (_hasAzure) {
      final path = await _rec.start();
      if (path == null) {
        // 录音不可用 → 直接 L3 兜底
        setState(() => _outcome = SayOutcome(passed: false, level: 'L3'));
        return;
      }
      setState(() {
        _recPath = path;
        _active = true;
      });
    } else {
      if (!_ready) {
        // speech_to_text 真实初始化失败 → L3
        setState(() => _outcome = SayOutcome(passed: false, level: 'L3'));
        return;
      }
      setState(() {
        _active = true;
        _heard = '';
      });
      _speech.startLocal((words) => setState(() => _heard = words));
    }
    p.incSay();
  }

  void _stop() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    setState(() {
      _active = false;
      _thinking = true;
    });
    if (_hasAzure) {
      final az = await _speech.assessAzure(
          _recPath!, widget.sentence, p.azureKey!, p.azureRegion!);
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _outcome = SayOutcome(passed: az.passed, level: 'L1', azure: az);
      });
    } else {
      await _speech.stopLocal();
      // no-speech 缺陷修复：没听到不算分、不入均值，提示重试。
      if (_heard.trim().isEmpty) {
        if (!mounted) return;
        setState(() {
          _thinking = false;
          _outcome = SayOutcome(
            passed: false,
            level: 'L2',
            recognized: '(no speech)',
            noSpeech: true,
          );
        });
        return;
      }
      final tm = _speech.textMatch(widget.sentence, _heard);
      p.recordScore(tm.score);
      final passed = tm.passed;
      if (!mounted) return;
      setState(() {
        _thinking = false;
        _outcome = SayOutcome(
          passed: passed,
          level: 'L2',
          recognized: _heard,
          textMatchScore: tm.score,
          wrong: !passed,
        );
      });
    }
  }

  void _retry() => setState(() {
        _outcome = null;
        _active = false;
        _thinking = false;
        _heard = '';
      });

  void _appeal() {
    Provider.of<ProgressService>(context, listen: false)
        .logAppeal(widget.levelId, widget.sentence);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Appeal logged.'), duration: Duration(seconds: 1)));
    widget.onDone();
  }

  Widget _scoreRow(String label, double v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 15)),
            Text(v.toStringAsFixed(1),
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _resultCard(SayOutcome o) {
    if (o.level == 'L1' && o.azure != null) {
      final az = o.azure!;
      final border = o.passed ? kUnlocked : Colors.white24;
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Column(
          children: [
            Icon(o.passed ? Icons.check_circle : Icons.refresh,
                color: o.passed ? kUnlocked : kPrimary, size: 36),
            const SizedBox(height: 8),
            const Text('Pronunciation Assessment',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            _scoreRow('Accuracy', az.accuracy),
            _scoreRow('Fluency', az.fluency),
            _scoreRow('Completeness', az.completeness),
            if (az.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${az.error}',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: o.passed ? kUnlocked : kPrimary),
                onPressed: o.passed ? widget.onDone : _retry,
                child: Text(o.passed ? 'Next sentence' : 'Try again',
                    style: const TextStyle(color: Colors.white)),
              ),
            ),
            if (!o.passed)
              TextButton(
                onPressed: _appeal,
                child: const Text("Appeal (I said it right)",
                    style: TextStyle(color: Colors.white38)),
              ),
          ],
        ),
      );
    }
    if (o.passed) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kUnlocked),
        ),
        child: Column(
          children: [
            const Icon(Icons.check_circle, color: kUnlocked, size: 36),
            const SizedBox(height: 8),
            const Text('You said:',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 6),
            Text("'${o.recognized}'",
                style: const TextStyle(color: kUnlocked, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Score: ${o.textMatchScore} (Text Match Mode)',
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                onPressed: widget.onDone,
                child: const Text('Next sentence', style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      );
    }
    if (o.noSpeech) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          children: [
            const Icon(Icons.mic_off, color: kPrimary, size: 36),
            const SizedBox(height: 8),
            const Text('没听到，再试一次',
                style: TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 6),
            const Text('没捕捉到声音，请靠近麦克风重试',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _retry,
                child: const Text('再试一次', style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      );
    }
    if (o.level == 'L2') {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          children: [
            const Text("Heard:",
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 4),
            Text("'${o.recognized}'",
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 4),
            Text("Expected: '${widget.sentence}'",
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
            const SizedBox(height: 6),
            Text('Score: ${o.textMatchScore} (Text Match Mode)',
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _retry,
                child: const Text('Try again', style: TextStyle(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _appeal,
                child: const Text("Appeal (I said it right)",
                    style: TextStyle(color: Colors.white70)),
              ),
            ),
          ],
        ),
      );
    }
    // L3 自确认
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          const Text('Speech recognition unavailable.',
              style: TextStyle(color: Colors.white, fontSize: 18)),
          const SizedBox(height: 6),
          const Text('Tap if you said it.',
              style: TextStyle(color: Colors.white70, fontSize: 15)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
              onPressed: widget.onDone,
              child: const Text('I said it', style: TextStyle(color: Colors.white)),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Self-confirmed Mode',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _hasAzure ? !_ready : !_ready;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Text(widget.sentence,
              style: const TextStyle(color: Colors.white, fontSize: 20)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () =>
                Provider.of<TtsService>(context, listen: false).speak(widget.sentence),
            child: const Text('Play again', style: TextStyle(color: Colors.white70)),
          ),
          const Spacer(),
          if (_thinking)
            const CircularProgressIndicator(color: kPrimary)
          else if (_outcome == null)
            if (waiting)
              const Text('Preparing mic…', style: TextStyle(color: Colors.white54))
            else if (_active)
              Column(
                children: [
                  const Waveform(),
                  const SizedBox(height: 18),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                    onPressed: _stop,
                    child: const Text('Stop', style: TextStyle(color: Colors.white)),
                  ),
                  if (!_hasAzure && _heard.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text("'${_heard}'",
                          style: const TextStyle(color: kUnlocked, fontSize: 15)),
                    ),
                ],
              )
            else
              Column(
                children: [
                  GestureDetector(
                    onTap: _start,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kPrimary.withOpacity(0.2),
                        border: Border.all(color: kPrimary, width: 2),
                      ),
                      child: const Icon(Icons.mic, color: kPrimary, size: 44),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text('Tap, then say it', style: TextStyle(color: Colors.white70)),
                ],
              )
          else
            _resultCard(_outcome!),
          const SizedBox(height: 20),
          if (_outcome == null && !waiting)
            TextButton(
              onPressed: widget.onDone,
              child: const Text('Skip', style: TextStyle(color: Colors.white38)),
            ),
        ],
      ),
    );
  }
}

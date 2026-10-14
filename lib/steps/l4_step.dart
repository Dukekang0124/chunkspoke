import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../services/state_machine.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// 琥珀高亮色（M5 统一收口色彩令牌前先用此常量对齐“目标词琥珀高亮”意图）。
const Color kAmber = Color(0xFFFFB84D);

/// L4 开口题型（三层同代码路径，永不死路/红屏）：
///  - 有 Azure Key：中文场景提示 → 开口 → Azure STT(en-US) →
///    chunkHit(词序无关 + 编辑距离≤1 + 词干容错) 命中 → 目标词琥珀高亮。
///  - 失败×2 → 转 L3 照读，文案“今天先读一遍，明天它回来找你”。
///  - 无 Key / 离线：录音自揭（TTS 目标句）+ 自评，与在线降级同一路径。
class L4Step extends StatefulWidget {
  final Chunk chunk;
  final String levelId;
  final VoidCallback onDone;
  const L4Step({required this.chunk, required this.levelId, required this.onDone, super.key});

  @override
  State<L4Step> createState() => _L4StepState();
}

class _L4StepState extends State<L4Step> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  bool _hasAzure = false;
  bool _ready = false;
  bool _listening = false;
  bool _thinking = false;
  String? _recPath;
  String _transcript = '';
  ChunkHitResult? _hit;
  bool _demoted = false;
  bool _selfAssess = false;

  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _hasAzure = _p.azureKey != null &&
        _p.azureKey!.isNotEmpty &&
        _p.azureRegion != null &&
        _p.azureRegion!.isNotEmpty;
    if (_hasAzure) {
      _rec.init().then((v) => setState(() => _ready = v));
    } else {
      _ready = true; // 无 Key：录音自揭自评，同一代码路径
    }
    Provider.of<TtsService>(context, listen: false).speak(widget.chunk.sentence.text);
  }

  Future<void> _start() async {
    if (_demoted || _selfAssess) return;
    final path = await _rec.start();
    if (path == null) {
      _enterSelfAssess();
      return;
    }
    setState(() {
      _recPath = path;
      _listening = true;
      _transcript = '';
      _hit = null;
    });
  }

  Future<void> _stop() async {
    setState(() {
      _listening = false;
      _thinking = true;
    });
    if (_hasAzure && _recPath != null) {
      final text = await _speech.transcribeAzure(
          _recPath!, _p.azureKey!, _p.azureRegion!);
      if (!mounted) return;
      final hit = chunkHit(widget.chunk.sentence.text, text,
          variants: widget.chunk.sentence.swapOptions);
      setState(() {
        _thinking = false;
        _transcript = text;
        _hit = hit;
      });
      await _resolveAttempt(hit.allHit);
    } else {
      _enterSelfAssess();
    }
  }

  Future<void> _resolveAttempt(bool passed) async {
    final store = _p.chunkStore;
    if (passed) {
      await store.applyEvent(widget.chunk.id, ChunkEvent.speakSuccess);
      if (!mounted) return;
      widget.onDone();
      return;
    }
    // 失败计数；失败×2 → 转 L3 照读
    await store.applyEvent(widget.chunk.id, ChunkEvent.speakFail);
    final row = await store.get(widget.chunk.id);
    if (!mounted) return;
    if (row.level == ChunkLevel.l3) {
      setState(() => _demoted = true);
    } else {
      setState(() {}); // 提示再试一次
    }
  }

  void _enterSelfAssess() {
    setState(() {
      _thinking = false;
      _selfAssess = true;
    });
  }

  void _selfConfirm(bool ok) => _resolveAttempt(ok);

  Widget _targetSentence() {
    final words = widget.chunk.sentence.text.split(' ');
    final hitSet = _hit?.hit.toSet() ?? {};
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: words.map((w) {
        final clean =
            w.toLowerCase().replaceAll(RegExp(r"[^a-z0-9']"), '');
        final hit = hitSet.contains(clean);
        return Text(w,
            style: TextStyle(
              color: hit ? kAmber : Colors.white,
              fontSize: 22,
              fontWeight: hit ? FontWeight.bold : FontWeight.normal,
            ));
      }).toList(),
    );
  }

  Widget _micButton() => GestureDetector(
        onTap: _listening ? _stop : _start,
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: kPrimary.withOpacity(0.2),
            border: Border.all(color: kPrimary, width: 2),
          ),
          child: Icon(_listening ? Icons.stop : Icons.mic,
              color: kPrimary, size: 44),
        ),
      );

  Widget _readBack() => Column(
        children: [
          const Text('今天先读一遍，明天它回来找你',
              style: TextStyle(color: kAmber, fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center),
          const SizedBox(height: 10),
          _targetSentence(),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
              onPressed: () {
                // 照读完成：转交 M4 会话/复习循环统一排程（明天回来）。
                widget.onDone();
              },
              child: const Text('我读完了', style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      );

  Widget _selfAssessCard() => Column(
        children: [
          const Text('离线 / 无 Key：揭目标句后自评是否说对',
              style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Provider.of<TtsService>(context, listen: false)
                .speak(widget.chunk.sentence.text),
            child: const Text('🔊 揭目标句', style: TextStyle(color: kPrimary)),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                  onPressed: () => _selfConfirm(true),
                  child: const Text('我说对了')),
              OutlinedButton(
                  onPressed: () => _selfConfirm(false),
                  child: const Text('没说对')),
            ],
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final waiting = !_ready;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          SceneCard(widget.level.theme),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: kBg.withOpacity(0.5),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(widget.chunk.meaningCN,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 16),
          const Text('开口说出来', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 10),
          if (_hit != null && !_selfAssess) _targetSentence(),
          const Spacer(),
          if (_demoted)
            _readBack()
          else if (_selfAssess)
            _selfAssessCard()
          else if (_thinking)
            const CircularProgressIndicator(color: kPrimary)
          else if (_hit != null && !_hit!.allHit)
            Column(
              children: [
                const Text('没完全命中，再试一次', style: TextStyle(color: kPrimary)),
                const SizedBox(height: 10),
                _micButton(),
              ],
            )
          else if (_hit != null && _hit!.allHit)
            const Text('命中！', style: TextStyle(color: kUnlocked, fontSize: 20))
          else if (waiting)
            const Text('Preparing mic…', style: TextStyle(color: Colors.white54))
          else
            _micButton(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

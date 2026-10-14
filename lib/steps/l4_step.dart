import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
///  - 无 Key / 离线：录音自听（回放）+ 自评，与在线降级同一路径。
///
/// 采集链路自检同 SAY：权限预检 / 实时电平 / 2 秒宽限 / 诊断行。
class L4Step extends StatefulWidget {
  final Chunk chunk;
  final String levelId;
  final String theme;
  final VoidCallback onDone;
  const L4Step({required this.chunk, required this.levelId, required this.theme, required this.onDone, super.key});

  @override
  State<L4Step> createState() => _L4StepState();
}

class _L4StepState extends State<L4Step> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  bool _hasAzure = false;
  bool _ready = false;
  bool _permBlocked = false;
  MicPerm _perm = MicPerm.denied;
  bool _listening = false;
  bool _thinking = false;
  bool _playing = false;
  String? _recPath;
  String _transcript = '';
  ChunkHitResult? _hit;
  bool _demoted = false;
  bool _selfAssess = false;

  double _level = 0;
  bool _levelActive = false;
  StreamSubscription<double>? _levelSub;
  DateTime? _listenStart;
  Timer? _playTimer;

  static const double _levelThreshold = 0.08;

  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _hasAzure = _p.azureKey != null &&
        _p.azureKey!.isNotEmpty &&
        _p.azureRegion != null &&
        _p.azureRegion!.isNotEmpty;
    // 权限预检（无论有无 Key，都要真实录音/自听），禁止静默失败。
    _rec.ensurePermission().then((perm) {
      if (!mounted) return;
      setState(() {
        _perm = perm;
        if (perm != MicPerm.granted) {
          _permBlocked = true;
          _ready = false;
        } else {
          _permBlocked = false;
          _ready = true;
        }
      });
    });
    Provider.of<TtsService>(context, listen: false).speak(widget.chunk.sentence.text);
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _playTimer?.cancel();
    _rec.stopPlay();
    super.dispose();
  }

  void _applyLevel(double v) {
    if (!mounted) return;
    if (v > _levelThreshold) _levelActive = true;
    setState(() => _level = v);
  }

  void _cancelLevels() {
    _levelSub?.cancel();
    _levelSub = null;
  }

  Future<void> _start() async {
    if (_demoted || _selfAssess || _permBlocked || !_ready) return;
    _levelActive = false;
    setState(() => _level = 0);
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
    _listenStart = DateTime.now();
    _levelSub?.cancel();
    _levelSub = _rec.levels.listen(_applyLevel);
  }

  /// 2 秒真实采集宽限：不足则继续采集至满 2 秒。
  Future<void> _graceTo2s() async {
    final start = _listenStart;
    if (start == null) return;
    final el = DateTime.now().difference(start);
    if (el < const Duration(seconds: 2)) {
      await Future.delayed(const Duration(seconds: 2) - el);
    }
  }

  Future<void> _stop() async {
    await _graceTo2s();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _thinking = true;
    });
    _cancelLevels();
    final path = await _rec.stop();
    if (path != null) _recPath = path;
    if (_hasAzure && _recPath != null) {
      final text = await _speech.transcribeAzure(
          _recPath!, _p.azureKey!, _p.azureRegion!);
      if (!mounted) return;
      final hit = chunkHit(widget.chunk.sentence.text, text,
          variants: widget.chunk.sentence.swapOptions);
      if (hit.allHit) HapticFeedback.mediumImpact();
      final total = hit.hit.length + hit.missed.length;
      final accuracy = hit.allHit
          ? 100
          : (total > 0 ? (hit.hit.length / total * 100).round() : 0);
      setState(() {
        _thinking = false;
        _transcript = text;
        _hit = hit;
      });
      await _resolveAttempt(hit.allHit, accuracy: accuracy);
    } else {
      _enterSelfAssess();
    }
  }

  Future<void> _resolveAttempt(bool passed,
      {int accuracy = 0, bool selfEval = false}) async {
    final store = _p.chunkStore;
    if (passed) {
      await store.applyEvent(widget.chunk.id, ChunkEvent.speakSuccess,
          accuracy: accuracy, selfEval: selfEval);
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

  void _selfConfirm(bool ok) => _resolveAttempt(ok, selfEval: ok);

  Future<void> _toggleReplay() async {
    final path = _recPath;
    if (path == null) return;
    if (_playing) {
      _playTimer?.cancel();
      await _rec.stopPlay();
      if (mounted) setState(() => _playing = false);
      return;
    }
    await _rec.play(path);
    if (!mounted) return;
    setState(() => _playing = true);
    _playTimer?.cancel();
    _playTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _playing) setState(() => _playing = false);
    });
  }

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

  Widget _permCard() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kPrimary),
        ),
        child: Column(
          children: [
            const Icon(Icons.mic_off, color: kPrimary, size: 36),
            const SizedBox(height: 8),
            const Text('需要麦克风权限', style: TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 6),
            Text(
              _perm == MicPerm.permanentlyDenied
                  ? '麦克风权限已被关闭，请到系统设置里打开后返回'
                  : '未获得麦克风权限，无法进行开口练习',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _perm == MicPerm.permanentlyDenied
                    ? () => _rec.openSettings()
                    : () {
                        _rec.ensurePermission().then((p) {
                          if (!mounted) return;
                          setState(() {
                            _perm = p;
                            _permBlocked = p != MicPerm.granted;
                            _ready = p == MicPerm.granted;
                          });
                        });
                      },
                child: Text(_perm == MicPerm.permanentlyDenied ? '去设置' : '允许麦克风',
                    style: const TextStyle(color: Colors.white)),
              ),
            ),
          ],
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
          const Text('离线 / 无 Key：录下来听听自己说得怎样',
              style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => Provider.of<TtsService>(context, listen: false)
                .speak(widget.chunk.sentence.text),
            child: const Text('🔊 揭目标句', style: TextStyle(color: kPrimary)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _recPath == null ? null : _toggleReplay,
              child: Text(_playing ? '停止回放' : '回放我的录音',
                  style: const TextStyle(color: kPrimary)),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                  onPressed: () => _selfConfirm(true),
                  child: const Text('我说对了', style: TextStyle(color: Colors.white))),
              OutlinedButton(
                  onPressed: () => _selfConfirm(false),
                  child: const Text('没说对', style: TextStyle(color: Colors.white70))),
            ],
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final waiting = !_ready && !_permBlocked;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          SceneCard(widget.theme),
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
          if (_permBlocked)
            _permCard()
          else if (_demoted)
            _readBack()
          else if (_selfAssess)
            _selfAssessCard()
          else if (_thinking)
            const CircularProgressIndicator(color: kPrimary)
          else if (_listening)
            Column(
              children: [
                LevelMeter(level: _level),
                const SizedBox(height: 10),
                Text(
                  _levelActive ? '麦克风在采集 ● 正常' : '等待声音…（波形不动=麦克风异常）',
                  style: TextStyle(
                      color: _levelActive ? kUnlocked : Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 14),
                _micButton(),
              ],
            )
          else if (_hit != null && !_hit!.allHit)
            Column(
              children: [
                const Text('没完全命中，再试一次', style: TextStyle(color: kPrimary)),
                const SizedBox(height: 6),
                if (_transcript.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text("听到：'$_transcript'",
                        style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                Text(
                  _levelActive ? '离麦克风近一点，语速自然' : '麦克风可能被占用或未授权，去设置检查',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                if (!_levelActive)
                  TextButton(
                    onPressed: () => _rec.openSettings(),
                    child: const Text('去设置检查麦克风权限',
                        style: TextStyle(color: Colors.white38)),
                  ),
                const SizedBox(height: 10),
                _micButton(),
              ],
            )
          else if (_hit != null && _hit!.allHit)
            const Text('命中！', style: TextStyle(color: kUnlocked, fontSize: 20))
          else if (waiting)
            const Text('正在准备麦克风…', style: TextStyle(color: Colors.white54))
          else
            _micButton(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

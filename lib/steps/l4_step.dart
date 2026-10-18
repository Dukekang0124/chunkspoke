import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/crash_log.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../services/state_machine.dart';
import '../services/speech_judge.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';

/// 琥珀高亮色（统一收口“目标词琥珀高亮”意图）。
const Color kAmber = Color(0xFFFFB84D);

/// 开口题型（复用收紧后的判定管线 judgeSpeech：规范化 + 词级序列比对 + 置信度门槛 + 空/静音拒绝）。
/// 同一份代码服务于两个环节：
///  - ② 开口说块：targetText = 词块文本
///  - ④ 场景开口：targetText = 整句文本
/// 通过 → onPass（由调用方决定“进阶”还是“掌握”）；3 次未过 → 正确答案 + 跳过入口（onSkip）。
class L4Step extends StatefulWidget {
  final Chunk chunk;
  final String levelId;
  final String theme;
  final String targetText;
  final VoidCallback onPass;
  final VoidCallback onSkip;
  /// 是否落盘掌握事件：句子闯关模式下传 false（仅推进，不影响词块掌握）。
  final bool persist;
  const L4Step(
      {required this.chunk,
      required this.levelId,
      required this.theme,
      required this.targetText,
      required this.onPass,
      required this.onSkip,
      this.persist = true,
      super.key});

  @override
  State<L4Step> createState() => _L4StepState();
}

class _L4StepState extends State<L4Step> with SingleTickerProviderStateMixin {
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
  JudgeOutcome? _judge;
  int _attempts = 0; // 开口尝试次数（满 3 次展示正确答案 + 跳过入口）
  bool _showAnswer = false; // 3 次未过 → 展示正确答案并给跳过入口
  bool _selfAssess = false;
  bool _engineFailed = false; // Vosk 加载失败（无 Azure）→ 明确报错
  // 跟读软着陆：首次识别失败后出现，不评分、自己对比，不计掌握。
  bool _followAlong = false;
  bool _followListening = false;
  bool _followPlaying = false;
  String? _followPath;
  Timer? _followPlayTimer;
  // P1-2 反向产出（轻量版）：隐藏英文、只给中文，逼用户从中文产出英文。
  bool _reverse = false;

  double _level = 0;
  bool _levelActive = false;
  StreamSubscription<double>? _levelSub;
  // B3：麦克风呼吸脉动（监听时循环缩放 1.0↔1.06）。
  late final AnimationController _breathCtrl;
  DateTime? _listenStart;
  Timer? _playTimer;

  static const double _levelThreshold = 0.08;

  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  /// 限定 Vosk 识别范围（提升命中与评分精度）。
  List<String> get _phrases => [widget.targetText];

  @override
  void initState() {
    super.initState();
    _breathCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _hasAzure = _p.azureKey != null &&
        _p.azureKey!.isNotEmpty &&
        _p.azureRegion != null &&
        _p.azureRegion!.isNotEmpty;
    _rec.ensurePermission().then((perm) {
      if (!mounted) return;
      setState(() {
        _perm = perm;
        _permBlocked = perm != MicPerm.granted;
      });
      if (perm == MicPerm.granted) {
        _loadEngine();
      }
    }).catchError((e, st) {
      CrashLog.write('L4.perm: $e', st);
      if (mounted) {
        setState(() {
          _permBlocked = true;
          _ready = false;
        });
      }
    });
    Provider.of<TtsService>(context, listen: false).speak(widget.targetText);
  }

  Future<void> _loadEngine() async {
    setState(() => _engineFailed = false);
    final ok = await _speech.initVosk();
    if (!mounted) return;
    setState(() {
      _ready = ok;
      _engineFailed = !ok;
    });
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    _playTimer?.cancel();
    _followPlayTimer?.cancel();
    if (_listening) {
      _rec.stop();
    }
    if (_followListening) {
      _rec.stop();
    }
    _rec.stopPlay();
    _breathCtrl.dispose();
    super.dispose();
  }

  // —— 跟读软着陆：TTS 逐词慢读 + 录音跟读 + 回放自评（不评分，不计掌握）——
  Future<void> _startFollow() async {
    if (_followPlaying) {
      _followPlayTimer?.cancel();
      await _rec.stopPlay();
      if (mounted) setState(() => _followPlaying = false);
    }
    final path = await _rec.start();
    if (!mounted) return;
    setState(() {
      _followPath = path;
      _followListening = true;
    });
  }

  Future<void> _stopFollow() async {
    final path = await _rec.stop();
    if (path != null && mounted) setState(() => _followPath = path);
    if (mounted) setState(() => _followListening = false);
  }

  Future<void> _toggleFollowReplay() async {
    final path = _followPath;
    if (path == null) return;
    if (_followPlaying) {
      _followPlayTimer?.cancel();
      await _rec.stopPlay();
      if (mounted) setState(() => _followPlaying = false);
      return;
    }
    await _rec.play(path);
    if (!mounted) return;
    setState(() => _followPlaying = true);
    _followPlayTimer?.cancel();
    _followPlayTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _followPlaying) setState(() => _followPlaying = false);
    });
  }

  /// 跟读自评“我说对了”：仅推进，不写掌握事件（软着陆，不污染掌握统计）。
  void _followConfirm() => widget.onPass();

  void _exitFollow() {
    _followListening = false;
    _followPlaying = false;
    _followPath = null;
    setState(() => _followAlong = false);
  }

  Widget _followAlongCard() => Column(
        children: [
          const Text('跟读模式：不评分，自己对比',
              style: TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: widget.targetText.split(' ').map((w) {
              return OutlinedButton(
                onPressed: () => speakOrHint(
                    context,
                    Provider.of<TtsService>(context, listen: false),
                    w),
                child: Text(w, style: const TextStyle(color: kPrimary)),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _followListening ? _stopFollow : _startFollow,
            child: Text(
              _followListening ? '🎤 停止录音' : '🎤 录一句跟读',
              style: const TextStyle(color: kPrimary),
            ),
          ),
          if (_followPath != null)
            TextButton(
              onPressed: _toggleFollowReplay,
              child: Text(_followPlaying ? '停止回放' : '回放我的录音',
                  style: const TextStyle(color: kPrimary)),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                onPressed: _followPath == null ? null : _followConfirm,
                child: const Text('我说对了', style: TextStyle(color: Colors.white)),
              ),
              OutlinedButton(
                onPressed: _exitFollow,
                child: const Text('还是想被识别',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ],
      );

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
    if (_selfAssess || _permBlocked || !_ready) return;
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
    });
    if (!MediaQuery.of(context).disableAnimations) {
      _breathCtrl.repeat(reverse: true); // B3 呼吸脉动（尊重系统减弱动画）
    }
    _listenStart = DateTime.now();
    _levelSub?.cancel();
    _levelSub = _rec.levels.listen(_applyLevel);
  }

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
    _breathCtrl.stop();
    _breathCtrl.value = 0;
    final path = await _rec.stop();
    if (path != null) _recPath = path;
    final usePath = path ?? _recPath;
    if (usePath != null && await _speech.initVosk()) {
      final r = await _speech.recognize(usePath, _phrases);
      final dur = await _speech.durationSec(usePath);
      if (!mounted) return;
      await _finishWith(r.text, r.confidence, dur);
      return;
    }
    if (usePath != null && _hasAzure) {
      final text = await _speech.transcribeAzure(
          usePath, _p.azureKey!, _p.azureRegion!);
      final dur = await _speech.durationSec(usePath);
      if (!mounted) return;
      // Azure 无 Vosk 置信度 → confidence=null，判定走文本相似度（不当作 0 拒判）。
      await _finishWith(text, null, dur);
      return;
    }
    _enterSelfAssess();
  }

  /// 用 judgeSpeech 三层漏斗判定（规范化 → 完全匹配快速通道 → 模糊层）。
  Future<void> _finishWith(
      String text, double? confidence, double durationSec) async {
    final outcome = judgeSpeech(
        target: widget.targetText,
        recognized: text,
        confidence: confidence,
        durationSec: durationSec);
    if (outcome.pass) HapticFeedback.mediumImpact();
    final accuracy = (outcome.similarity * 100).round();
    // A2① 平均准确度=文本匹配相似度：每次开口判定（通过与否）都记相似度，
    // 使「平均准确度」真实反映开口文本匹配，而不是恒为 0。
    try {
      await _p.recordScore(accuracy);
    } catch (e, st) {
      CrashLog.write('L4.recordScore: $e', st);
    }
    setState(() {
      _thinking = false;
      _transcript = text;
      _judge = outcome;
    });
    await _resolveAttempt(outcome.pass, accuracy: accuracy);
  }

  Future<void> _resolveAttempt(bool passed,
      {int accuracy = 0, bool selfEval = false}) async {
    final store = _p.chunkStore;
    if (passed) {
      // 每日目标：任意一次开口成功都计入今日进度（含句子闯关 persist=false），并完成当日打卡。
      _p.noteSpoken().catchError((_) {});
      if (widget.persist) {
        try {
          await store.applyEvent(widget.chunk.id, ChunkEvent.speakSuccess,
              accuracy: accuracy, selfEval: selfEval);
        } catch (e, st) {
          CrashLog.write('L4.speakSuccess: $e', st);
        }
      }
      if (!mounted) return;
      widget.onPass();
      return;
    }
    // persist=false（句子闯关模式）只推进流程，失败不得写词块 speakFail——
    // 否则「照着句子闯关失败」会污染该词块的失败计数（报告 §4 第 7 条）。
    if (widget.persist) {
      try {
        await store.applyEvent(widget.chunk.id, ChunkEvent.speakFail);
      } catch (e, st) {
        CrashLog.write('L4.speakFail: $e', st);
      }
    }
    if (!mounted) return;
    _attempts++;
    if (_attempts >= 3) {
      setState(() => _showAnswer = true);
    } else {
      setState(() {});
    }
  }

  void _enterSelfAssess() {
    buzzWrong();
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

  /// 目标句：未通过时按逐词对齐把错词标红（matched=false）。
  Widget _targetSentence() {
    final judge = _judge;
    final words =
        judge != null ? judge.targetWords : widget.targetText.split(' ');
    final matched = judge?.targetMatched;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: List.generate(words.length, (i) {
        final ok = matched == null || i >= matched.length || matched[i];
        return Text(words[i],
            style: TextStyle(
              color: ok ? Colors.white : Colors.redAccent,
              fontSize: 22,
              fontWeight: ok ? FontWeight.normal : FontWeight.bold,
            ));
      }),
    );
  }

  Widget _micButton() => GestureDetector(
        onTap: _listening ? _stop : _start,
        child: AnimatedBuilder(
          animation: _breathCtrl,
          builder: (ctx, _) {
            final breath = 1.0 + _breathCtrl.value * 0.06; // 呼吸脉动
            final ring = 8.0 + _level * 28.0; // 音量环随实时振幅扩张
            return SizedBox(
              width: 150,
              height: 150,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 音量环：实时跟随输入振幅
                  Container(
                    width: 96 + ring * 2,
                    height: 96 + ring * 2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: kPrimary.withOpacity(_listening ? 0.45 : 0.0),
                        width: 3,
                      ),
                    ),
                  ),
                  // 麦克风主体：聆听时呼吸脉动
                  Transform.scale(
                    scale: _listening ? breath : 1.0,
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
                  ),
                ],
              ),
            );
          },
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

  Widget _engineFailedCard() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kPrimary),
        ),
        child: Column(
          children: [
            const Icon(Icons.error_outline, color: kPrimary, size: 36),
            const SizedBox(height: 8),
            const Text('识别引擎初始化失败',
                style: TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 6),
            const Text('重启应用或反馈给我们',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _loadEngine,
                child: const Text('重试加载引擎',
                    style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      );

  /// 3 次未通过：展示正确答案 + 跳过入口（不计入掌握，置复习队列）。
  Widget _answerCard() => Column(
        children: [
          const Text('正确答案：', style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          _targetSentence(),
          const SizedBox(height: 12),
          const Text('已试 3 次未通过，可跳过本句（不计入掌握）',
              style: TextStyle(color: Colors.white54, fontSize: 13), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
              onPressed: () => widget.onSkip(),
              child: const Text('跳过本句（不计入掌握）', style: TextStyle(color: Colors.white)),
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
            onPressed: () => speakOrHint(
                context,
                Provider.of<TtsService>(context, listen: false),
                widget.targetText),
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
                  onPressed: _recPath == null ? null : () => _selfConfirm(true),
                  child: const Text('我说对了', style: TextStyle(color: Colors.white))),
              OutlinedButton(
                  onPressed: () => _selfConfirm(false),
                  child: const Text('没说对', style: TextStyle(color: Colors.white70))),
            ],
          ),
          if (_recPath == null)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('请先录音，再确认“我说对了”',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final waiting = !_ready && !_permBlocked && !_engineFailed;
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
            child: _reverse
                ? Text(widget.chunk.meaningCN,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: kPrimary, fontSize: 18, fontWeight: FontWeight.w600))
                : CnText(
                    widget.targetText,
                    widget.chunk.meaningCN,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _reverse = !_reverse),
                child: Text(_reverse ? '显示英文' : '看中文练 →',
                    style: const TextStyle(color: kPrimary, fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_reverse ? '看中文，说出英文' : '开口说出来',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 10),
          if (_judge != null && !_selfAssess) _targetSentence(),
          const Spacer(),
          if (_permBlocked)
            _permCard()
          else if (_engineFailed)
            _engineFailedCard()
          else if (_showAnswer)
            _answerCard()
          else if (_selfAssess)
            _selfAssessCard()
          else if (_followAlong)
            _followAlongCard()
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
          else if (_judge != null && !_judge!.pass)
            Column(
              children: [
                Text(
                  _judge!.reason == 'empty' ||
                          _judge!.reason == 'lowConf' ||
                          _judge!.reason == 'tooShort'
                      ? '没有听清，请再说一遍'
                      : '再试一次（错词已标红）',
                  style: const TextStyle(color: kPrimary)),
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
                if (!_followAlong)
                  TextButton(
                    onPressed: () => setState(() => _followAlong = true),
                    child: const Text('先跟着读，不评分也可以 →',
                        style: TextStyle(color: kPrimary)),
                  ),
                const SizedBox(height: 6),
                _micButton(),
              ],
            )
          else if (_judge != null && _judge!.pass)
            const Text('命中！', style: TextStyle(color: kUnlocked, fontSize: 20))
          else if (waiting)
            const Column(
              children: [
                CircularProgressIndicator(color: kPrimary),
                SizedBox(height: 10),
                Text('引擎准备中…', style: TextStyle(color: Colors.white54)),
              ],
            )
          else
            _micButton(),
          if (!_showAnswer)
            TextButton(
              onPressed: () => widget.onSkip(),
              child: const Text('先跳过，明天复习见',
                  style: TextStyle(color: Colors.white38)),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

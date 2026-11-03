import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/asr_guard.dart';
import '../services/crash_log.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../services/state_machine.dart';
import '../services/speech_judge.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';
import '../ui/motion.dart';
import '../ui/permission_preprompt.dart';

/// 琥珀高亮色（统一收口“目标词琥珀高亮”意图）。
Color get kAmber => kPrimary;

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

  /// 复习会话：通过/失败走词块资产状态机（升档/降档），而非学习完成判定。
  final bool review;

  /// 识别词表（默认只含当前目标）。闯关时传全关句子+词块，
  /// 避免“只认识目标句”把其他句子强制拼成目标词。
  final List<String>? recognitionPhrases;

  /// 命中后延迟推进；null = 立即推进（旧行为）。
  /// 闯关传 1.5s：先展示“命中”结果，用户可点“下一句”提前推进。
  final Duration? passAdvanceDelay;

  /// 命中态按钮文案（闯关最后一句为“查看闯关结果”）。
  final String passActionLabel;

  /// 初始态跳过按钮文案（闯关不排复习，不能沿用“明天复习见”）。
  final String skipHint;

  const L4Step(
      {required this.chunk,
      required this.levelId,
      required this.theme,
      required this.targetText,
      required this.onPass,
      required this.onSkip,
      this.persist = true,
      this.review = false,
      this.recognitionPhrases,
      this.passAdvanceDelay,
      this.passActionLabel = '下一句',
      this.skipHint = '先跳过，明天复习见',
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
  // M1：本条结果实际来自哪个后端；降级重识时如实标注，不静默换引擎。
  AsrSource? _asrSrc;
  String _thinkingText = '识别中…';
  JudgeOutcome? _judge;
  AsrGuardResult? _guard;
  bool _passed = false;
  bool _stopping = false;
  SilenceAutoStop? _silence;
  int _attempts = 0; // 开口尝试次数（满 3 次展示正确答案 + 跳过入口）
  bool _showAnswer = false; // 3 次未过/主动看答案 → 展示正确答案并给跳过入口
  bool _passPending = false; // 已命中，等待“下一句”或自动推进
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

  /// §30.3-5：本条判定来自「手改转写 / 打字作答」而非语音命中。
  /// 为 true 时结果必须标注「未验证发音」，且不当成一次开口尝试记账。
  bool _edited = false;

  double _level = 0;
  bool _levelActive = false;
  StreamSubscription<double>? _levelSub;
  // B3：麦克风呼吸脉动（监听时循环缩放 1.0↔1.06）。
  late final AnimationController _breathCtrl;
  DateTime? _listenStart;
  Timer? _playTimer;
  Timer? _passTimer;

  static const double _levelThreshold = 0.08;

  /// §30.3-9：只喂「靠近一点说」提示的舒适线，不参与端点判定与识别打分。
  static const double _comfortLevel = 0.15;

  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);
  TtsService get _tts => Provider.of<TtsService>(context, listen: false);

  /// B5：生产路径不传词表（全模型）；这里的短语只服务 E2E 脚本化识别。
  List<String> get _phrases => <String>{
        widget.targetText,
        ...?widget.recognitionPhrases,
      }.toList(growable: false);

  /// M1：来源标注——Vosk 默认路径不加噪音，只在降级重识时如实标注。
  String _srcLabel(AsrSource? s) {
    if (s == AsrSource.enhanced) return '（增强识别）';
    if (s == AsrSource.azure) return '（云端识别）';
    return '';
  }

  @override
  void initState() {
    super.initState();
    _silence = SilenceAutoStop(onSilence: () {
      if (mounted && _listening) _stop();
    });
    _breathCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _hasAzure = _p.azureKey != null &&
        _p.azureKey!.isNotEmpty &&
        _p.azureRegion != null &&
        _p.azureRegion!.isNotEmpty;
    ensureMicWithPreprompt(context, _rec).then((perm) {
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

  /// 目标句切换时清空上一句的识别结果/尝试次数/答案态。
  /// 调用方必须用 sentence id 作 key（双保险）；这里兜住未换 key 的调用场景。
  @override
  void didUpdateWidget(covariant L4Step oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetText == widget.targetText &&
        oldWidget.chunk.id == widget.chunk.id) {
      return;
    }
    _passTimer?.cancel();
    _passTimer = null;
    _playTimer?.cancel();
    _followPlayTimer?.cancel();
    _levelSub?.cancel();
    _levelSub = null;
    _breathCtrl.stop();
    _breathCtrl.value = 0;
    if (_listening) _rec.stop();
    if (_followListening) _rec.stop();
    _rec.stopPlay();
    _listening = false;
    _thinking = false;
    _playing = false;
    _recPath = null;
    _transcript = '';
    _asrSrc = null;
    _thinkingText = '识别中…';
    _judge = null;
    _guard = null;
    _passed = false;
    _attempts = 0;
    _showAnswer = false;
    _passPending = false;
    _selfAssess = false;
    _followAlong = false;
    _followListening = false;
    _followPlaying = false;
    _followPath = null;
    _reverse = false;
    _edited = false;
    _level = 0;
    _levelActive = false;
    _listenStart = null;
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
    _silence?.detach();
    _levelSub?.cancel();
    _playTimer?.cancel();
    _followPlayTimer?.cancel();
    _passTimer?.cancel();
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
    if (_listening || _thinking) return;
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
    if (_followListening) return;
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

  // 录音/识别中禁 TTS 与回放，防止扬声器回授被麦克风自吞。
  bool get _speakBlocked => _listening || _followListening || _thinking;

  Widget _followAlongCard() => Column(
        children: [
          Text('跟读模式：不评分，自己对比',
              style: TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: widget.targetText.split(' ').map((w) {
              return OutlinedButton(
                onPressed: _speakBlocked
                    ? null
                    : () => speakOrHint(
                        context,
                        Provider.of<TtsService>(context, listen: false),
                        w),
                child: Text(w, style: TextStyle(color: kPrimary)),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _followListening ? _stopFollow : _startFollow,
            child: Text(
              _followListening ? '🎤 停止录音' : '🎤 录一句跟读',
              style: TextStyle(color: kPrimary),
            ),
          ),
          if (_followPath != null)
            TextButton(
              onPressed: _toggleFollowReplay,
              child: Text(_followPlaying ? '停止回放' : '回放我的录音',
                  style: TextStyle(color: kPrimary)),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                onPressed: _followPath == null ? null : _followConfirm,
                child: Text('我说对了', style: TextStyle(color: kText)),
              ),
              OutlinedButton(
                onPressed: _exitFollow,
                child: Text('还是想被识别',
                    style: TextStyle(color: kTextSecondary)),
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
    // 防回声自吞：录音开始前先停掉 TTS / 本地回放。
    await _tts.stop();
    await _rec.stopPlay();
    final path = await _rec.start();
    if (path == null) {
      _enterSelfAssess();
      return;
    }
    if (!mounted) {
      await _rec.stop();
      return;
    }
    _passTimer?.cancel();
    setState(() {
      _recPath = path;
      _listening = true;
      _thinking = false;
      _thinkingText = '识别中…';
      _transcript = '';
      _asrSrc = null;
      _judge = null;
      _guard = null;
      _passed = false;
      _showAnswer = false;
      _passPending = false;
      _edited = false;
    });
    if (Motion.of(context).animates) {
      _breathCtrl.repeat(reverse: true); // B3 呼吸脉动（M1 起统一过闸）
    }
    _listenStart = DateTime.now();
    _stopping = false;
    _levelSub?.cancel();
    _levelSub = _rec.levels.listen(_applyLevel);
    _silence?.attach(_rec.levels);
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
    if (_stopping) return;
    _stopping = true;
    _silence?.detach();
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
      final r = await _speech.recognizeOpen(usePath, e2ePhrases: _phrases);
      final dur = await _speech.durationSec(usePath);
      if (!mounted) return;
      await _finishWith(r.text, r.confidence, dur,
          wordConfs: r.wordConfidences);
      return;
    }
    if (usePath != null && _hasAzure) {
      final text = await _speech.transcribeAzure(
          usePath, _p.azureKey!, _p.azureRegion!);
      final dur = await _speech.durationSec(usePath);
      if (!mounted) return;
      // Azure 无 Vosk 置信度 → confidence=null，判定走文本相似度（不当作 0 拒判）。
      await _finishWith(text, null, dur, fromCloud: true);
      return;
    }
    _enterSelfAssess();
  }

  /// 用 judgeSpeech 三层漏斗判定（规范化 → 完全匹配快速通道 → 模糊层），
  /// 并叠加 B5 守门：只有「文本命中 + 置信度达标 + 非垃圾」才允许绿灯。
  Future<void> _finishWith(
      String text, double? confidence, double durationSec,
      {List<double>? wordConfs, bool fromCloud = false}) async {
    var source = fromCloud ? AsrSource.azure : _speech.lastOpenSource;
    final targetTokens = tokenizeSpeech(widget.targetText);
    var g = guardAsr(
      raw: text,
      wordConfidences: wordConfs,
      targetBlock: widget.targetText,
      minWords: targetTokens.length <= 1 ? 1 : 2,
    );
    var outcome = judgeSpeech(
        target: widget.targetText,
        recognized: text,
        confidence: confidence,
        durationSec: durationSec);
    var passed = g.ok && outcome.pass;
    var finalText = text;
    // —— ASR-188 缓解版：一过判不过时，锁目标句词表再跑一次受限解码（Vosk grammar）。
    // 展示口径不变（一过原文优先），只有二过同时过守门+判定才改判「过」；
    // 二过强制开 checkChunkStack——强制解码会把噪声拼成目标句且置信度虚高。
    if (!passed && _recPath != null) {
      final retry = await _speech.recognizeWithTargetGrammarRetry(
        wavPath: _recPath!,
        targetSentence: widget.targetText,
        firstText: text,
      );
      if (retry != null) {
        final g2 = guardAsr(
          raw: retry.text,
          wordConfidences: retry.wordConfidences,
          targetBlock: widget.targetText,
          minWords: targetTokens.length <= 1 ? 1 : 2,
          checkChunkStack: true,
        );
        final o2 = judgeSpeech(
            target: widget.targetText,
            recognized: retry.text,
            confidence: retry.confidence,
            durationSec: durationSec);
        if (g2.ok && o2.pass) {
          debugPrint('ASR188|grammar-rescued|free=$text|grammar=${retry.text}');
          g = g2;
          outcome = o2;
          passed = true;
          finalText = retry.text;
        }
      }
    }
    // —— M1（2026-11-03）：本地增强优先、云端兜底的降级重识。
    // 只在仍未通过时执行；两条路都不可用会立刻返回 null，不等待、不改原结果。
    if (!passed && _recPath != null) {
      if (mounted) {
        setState(() => _thinkingText = '正在用更精准的方式再听一遍…');
      }
      final fb = await _speech.retryOpenWithFallback(
        wavPath: _recPath!,
        target: widget.targetText,
        keywords: asrKeywords(widget.targetText),
        skipEnhanced: source == AsrSource.enhanced,
        azureKey: _p.azureKey,
        azureRegion: _p.azureRegion,
      );
      if (mounted) setState(() => _thinkingText = '识别中…');
      if (fb != null) {
        final g3 = guardAsr(
          raw: fb.text,
          wordConfidences: fb.wordConfidences,
          targetBlock: widget.targetText,
          minWords: targetTokens.length <= 1 ? 1 : 2,
        );
        final o3 = judgeSpeech(
            target: widget.targetText,
            recognized: fb.text,
            confidence: fb.confidence,
            durationSec: durationSec);
        if (g3.ok && o3.pass) {
          debugPrint(
              'M1|fallback-rescued|src=${fb.source.name}|one=$text|retry=${fb.text}');
          g = g3;
          outcome = o3;
          passed = true;
          finalText = fb.text;
          source = fb.source;
        }
      }
    }
    if (!mounted) return; // 二过/降级重识是异步的，回到 UI 前重新确认挂载
    if (passed) Motion.of(context).success();
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
      _transcript = finalText;
      _asrSrc = source;
      _judge = outcome;
      _guard = g;
      _passed = passed;
    });
    await _resolveAttempt(passed, accuracy: accuracy);
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
              accuracy: accuracy, selfEval: selfEval, review: widget.review);
        } catch (e, st) {
          CrashLog.write('L4.speakSuccess: $e', st);
        }
      }
      if (!mounted) return;
      final delay = widget.passAdvanceDelay;
      if (delay == null) {
        widget.onPass();
        return;
      }
      setState(() => _passPending = true);
      _passTimer?.cancel();
      _passTimer = Timer(delay, _emitPass);
      return;
    }
    // persist=false（句子闯关模式）只推进流程，失败不得写词块 speakFail——
    // 否则「照着句子闯关失败」会污染该词块的失败计数（报告 §4 第 7 条）。
    if (widget.persist) {
      try {
        await store.applyEvent(widget.chunk.id, ChunkEvent.speakFail,
            review: widget.review);
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

  /// 命中后唯一推进出口：按钮与 1.5s 定时器共用，防重复推进。
  void _emitPass() {
    if (!mounted || !_passPending) return;
    _passPending = false;
    _passTimer?.cancel();
    _passTimer = null;
    widget.onPass();
  }

  /// 跳过/看答案后跳过也走同一出口，先取消待触发的自动推进。
  void _emitSkip() {
    _passTimer?.cancel();
    _passTimer = null;
    if (_passPending) {
      setState(() => _passPending = false);
    }
    widget.onSkip();
  }

  void _openAnswer() {
    setState(() {
      _showAnswer = true;
      _passPending = false;
    });
    _passTimer?.cancel();
    _passTimer = null;
  }

  void _enterSelfAssess() {
    buzzWrong(context);
    setState(() {
      _thinking = false;
      _selfAssess = true;
    });
  }

  void _selfConfirm(bool ok) => _resolveAttempt(ok, selfEval: ok);

  /// 有波动但明显偏弱 → 「靠近一点说」。纯提示，不改判定、不打断采集。
  bool get _tooQuiet => _levelActive && _level < _comfortLevel;

  /// §30.3-5：可编辑转写 + 打字作答。识别不准时不逼用户重录——允许把文本改对
  /// 后按「文本判定」再看一次；文本结果标注「未验证发音」，不计发音分，也不
  /// 计入 3 次开口尝试（不污染掌握统计）。
  Future<void> _judgeEdited() async {
    if (_listening || _thinking) return;
    final ctrl = TextEditingController(text: _transcript);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('改转写 / 打字作答',
            style: TextStyle(color: kText, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              style: TextStyle(color: kText, fontSize: 16),
              decoration: InputDecoration(
                hintText: '把这句英文写出来',
                hintStyle: TextStyle(color: kTextFaint, fontSize: 13),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text('按文本判定：不验证发音，也不计发音分',
                style: TextStyle(color: kTextFaint, fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: kTextMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: Text('按文本判定', style: TextStyle(color: kPrimary)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final t = text?.trim() ?? '';
    if (t.isEmpty || !mounted) return;
    final outcome = judgeSpeech(target: widget.targetText, recognized: t);
    final passed = outcome.pass;
    if (passed) Motion.of(context).success();
    setState(() {
      _transcript = t;
      _asrSrc = null; // 手改/打字的文本不是任何识别后端的产物
      _judge = outcome;
      _guard = null;
      _passed = passed;
      _edited = true;
    });
    if (passed) await _resolveAttempt(true, accuracy: 0, selfEval: true);
  }

  Future<void> _toggleReplay() async {
    if (_listening || _followListening) return;
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
              color: ok ? kText : kError,
              fontSize: 22,
              fontWeight: ok ? FontWeight.normal : FontWeight.bold,
            ));
      }),
    );
  }

  Widget _micButton() => GestureDetector(
        onTap: _listening ? _stop : _start,
        // §30.3-2 预卷：按下即起采（原生 400ms 环形缓冲），抬起进入正式录音时
        // 回灌缓冲，避免句首弱读被切；取消/3s 超时由原生自动释放。
        onTapDown: (_) {
          if (!_listening && !_thinking && !_selfAssess && _ready) {
            _rec.arm();
          }
        },
        onTapCancel: () => _rec.disarm(),
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
                        color: kPrimary.withValues(alpha: _listening ? 0.45 : 0.0),
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
                        color: kPrimary.withValues(alpha: 0.2),
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
            Icon(Icons.mic_off, color: kPrimary, size: 36),
            const SizedBox(height: 8),
            Text('需要麦克风权限', style: TextStyle(color: kText, fontSize: 18)),
            const SizedBox(height: 6),
            Text(
              _perm == MicPerm.permanentlyDenied
                  ? '麦克风权限已被关闭，请到系统设置里打开后返回'
                  : '未获得麦克风权限，无法进行开口练习',
              textAlign: TextAlign.center,
              style: TextStyle(color: kTextSecondary, fontSize: 14),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _perm == MicPerm.permanentlyDenied
                    ? () => _rec.openSettings()
                    : () {
                        ensureMicWithPreprompt(context, _rec).then((p) {
                          if (!mounted) return;
                          setState(() {
                            _perm = p;
                            _permBlocked = p != MicPerm.granted;
                            _ready = p == MicPerm.granted;
                          });
                        });
                      },
                child: Text(_perm == MicPerm.permanentlyDenied ? '去设置' : '允许麦克风',
                    style: TextStyle(color: kText)),
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
            Icon(Icons.error_outline, color: kPrimary, size: 36),
            const SizedBox(height: 8),
            Text('识别引擎初始化失败',
                style: TextStyle(color: kText, fontSize: 18)),
            const SizedBox(height: 6),
            Text('重启应用或反馈给我们',
                textAlign: TextAlign.center,
                style: TextStyle(color: kTextSecondary, fontSize: 14)),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _loadEngine,
                child: Text('重试加载引擎',
                    style: TextStyle(color: kOnPrimary)),
              ),
            ),
          ],
        ),
      );

  /// 看答案/3 次未过：展示正确答案，保留“再试一次”与“跳过”两条路。
  Widget _answerCard() => Column(
        children: [
          Text('正确答案 · 可听一遍',
              style: TextStyle(color: kTextSecondary), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          _targetSentence(),
          TextButton(
            onPressed: _speakBlocked
                ? null
                : () => speakOrHint(
                    context,
                    Provider.of<TtsService>(context, listen: false),
                    widget.targetText),
            child: Text('🔊 听标准发音',
                style: TextStyle(color: kPrimary, fontSize: 13)),
          ),
          Text('看答案不计入命中；可再试一次，或跳过本句',
              style: TextStyle(color: kTextMuted, fontSize: 13),
              textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                  onPressed: _ready ? _start : null,
                  child: Text('再试一次',
                      style: TextStyle(color: kText)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _emitSkip,
                  child: Text('跳过本句',
                      style: TextStyle(color: kTextSecondary)),
                ),
              ),
            ],
          ),
        ],
      );

  Widget _selfAssessCard() => Column(
        children: [
          Text('离线 / 无 Key：录下来听听自己说得怎样',
              style: TextStyle(color: kTextSecondary), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          TextButton(
            onPressed: _speakBlocked
                ? null
                : () => speakOrHint(
                    context,
                    Provider.of<TtsService>(context, listen: false),
                    widget.targetText),
            child: Text('🔊 揭目标句', style: TextStyle(color: kPrimary)),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _recPath == null ? null : _toggleReplay,
              child: Text(_playing ? '停止回放' : '回放我的录音',
                  style: TextStyle(color: kPrimary)),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                  onPressed: _recPath == null ? null : () => _selfConfirm(true),
                  child: Text('我说对了', style: TextStyle(color: kText))),
              OutlinedButton(
                  onPressed: () => _selfConfirm(false),
                  child: Text('没说对', style: TextStyle(color: kTextSecondary))),
            ],
          ),
          if (_recPath == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('请先录音，再确认“我说对了”',
                  style: TextStyle(color: kTextFaint, fontSize: 12)),
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
              color: kBg.withValues(alpha: 0.5),
              border: Border.all(color: kBorderStrong),
            ),
            child: _reverse
                ? Text(widget.chunk.meaningCN,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: kPrimary, fontSize: 18, fontWeight: FontWeight.w600))
                : CnText(
                    widget.targetText,
                    widget.chunk.meaningCN,
                    style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _reverse = !_reverse),
                child: Text(_reverse ? '显示英文' : '看中文练 →',
                    style: TextStyle(color: kPrimary, fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(_reverse ? '看中文，说出英文' : '开口说出来',
              style: TextStyle(color: kTextSecondary)),
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
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: kPrimary),
                const SizedBox(height: 10),
                Text(_thinkingText, style: TextStyle(color: kTextMuted)),
              ],
            )
          else if (_listening)
            Column(
              children: [
                LevelMeter(level: _level),
                const SizedBox(height: 10),
                Text(
                  _tooQuiet
                      ? '声音有点小，靠近一点说'
                      : (_levelActive
                          ? '正在录音 ● 点圆形按钮结束'
                          : '正在录音 · 等待声音…（波形不动=麦克风异常）'),
                  style: TextStyle(
                      color: _tooQuiet
                          ? kPrimary
                          : (_levelActive ? kUnlocked : kTextMuted),
                      fontSize: 13),
                ),
                const SizedBox(height: 14),
                _micButton(),
              ],
            )
          else if (_judge != null && !_passed)
            Column(
              children: [
                Text(
                  (_guard != null && !_guard!.ok)
                      ? '⚠ 没听清，再说一遍'
                      : (_judge!.reason == 'empty' ||
                              _judge!.reason == 'lowConf' ||
                              _judge!.reason == 'tooShort'
                          ? '没有听清，请再说一遍'
                          : '再试一次（错词已标红）'),
                  style: TextStyle(color: kPrimary)),
                const SizedBox(height: 6),
                if (_transcript.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                        "${_edited ? '你写' : '你说'}：'$_transcript'${_srcLabel(_asrSrc)}",
                        key: const Key('l4AsrRaw'),
                        style: TextStyle(
                            color: kTextSecondary, fontSize: 13)),
                  ),
                if (_transcript.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                        _edited
                            ? '按文本判定 · 未验证发音（不计分）'
                            : '相似度：${(_judge!.similarity * 100).round()}%（词级匹配）',
                        style: TextStyle(
                            color: kTextMuted, fontSize: 12)),
                  ),
                Text(
                  _edited
                      ? '手打的文本按文本比对，不算一次开口尝试'
                      : (_levelActive
                          ? '离麦克风近一点，语速自然'
                          : '麦克风可能被占用或未授权，去设置检查'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kTextMuted, fontSize: 13),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                        onPressed: _ready ? _start : null,
                        child: Text('再试一次',
                            style: TextStyle(color: kOnPrimary)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _openAnswer,
                        child: Text('看答案',
                            style: TextStyle(color: kText)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _emitSkip,
                        child: Text('跳过',
                            style: TextStyle(color: kTextSecondary)),
                      ),
                    ),
                  ],
                ),
                if (!_levelActive)
                  TextButton(
                    onPressed: () => _rec.openSettings(),
                    child: Text('去设置检查麦克风权限',
                        style: TextStyle(color: kTextFaint)),
                  ),
                if (!_followAlong)
                  TextButton(
                    onPressed: () => setState(() => _followAlong = true),
                    child: Text('先跟着读，不评分也可以 →',
                        style: TextStyle(color: kPrimary)),
                  ),
                TextButton(
                  onPressed: _judgeEdited,
                  child: Text('改转写 / 打字作答（不计发音分）',
                      style: TextStyle(color: kTextMuted)),
                ),
              ],
            )
          else if (_judge != null && _passed)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('✓ 命中！',
                    style: TextStyle(color: kUnlocked, fontSize: 20)),
                if (_transcript.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        "${_edited ? '你写' : '你说'}：'$_transcript'${_srcLabel(_asrSrc)}",
                        key: const Key('l4AsrRaw'),
                        style: TextStyle(
                            color: kTextSecondary, fontSize: 13)),
                  ),
                if (_transcript.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                        _edited
                            ? '按文本通过 · 未验证发音（不计分）'
                            : '相似度：${(_judge!.similarity * 100).round()}%（词级匹配）',
                        style: TextStyle(
                            color: kTextMuted, fontSize: 12)),
                  ),
                if (_passPending) ...[
                  const SizedBox(height: 6),
                  Text(
                    '${(widget.passAdvanceDelay!.inMilliseconds / 1000).toStringAsFixed(1)} 秒后自动进入下一句',
                    style: TextStyle(color: kTextMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
                    onPressed: _emitPass,
                    child: Text(widget.passActionLabel,
                        style: TextStyle(color: kText)),
                  ),
                ],
              ],
            )
          else if (waiting)
            Column(
              children: [
                CircularProgressIndicator(color: kPrimary),
                const SizedBox(height: 10),
                Text('引擎准备中…', style: TextStyle(color: kTextMuted)),
              ],
            )
          else
            Column(
              children: [
                _micButton(),
                const SizedBox(height: 8),
                Text('语速适中、吐字清晰识别更准',
                    style: TextStyle(color: kTextFaint, fontSize: 12)),
                TextButton(
                  onPressed: _judgeEdited,
                  child: Text('说不了？打字作答',
                      style: TextStyle(color: kPrimary, fontSize: 13)),
                ),
              ],
            ),
          if (!_showAnswer &&
              !_passPending &&
              !_passed &&
              !_listening &&
              !_thinking &&
              // D1：录过音才给「跳过」——首屏常驻跳过按钮等于教用户不开口。
              _recPath != null)
            TextButton(
              onPressed: _emitSkip,
              child: Text(widget.skipHint,
                  style: TextStyle(color: kTextFaint)),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

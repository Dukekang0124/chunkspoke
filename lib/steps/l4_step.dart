import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/asr_budget.dart';
import '../services/asr_guard.dart';
import '../services/crash_log.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../services/vosk_engine.dart' show VoskResult;
import '../services/state_machine.dart';
import '../services/speech_judge.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';
import '../ui/machine_unsure_card.dart';
import '../ui/motion.dart';
import '../ui/permission_preprompt.dart';

/// 琥珀高亮色（统一收口“目标词琥珀高亮”意图）。
Color get kAmber => kPrimary;

/// ASR-229 · D4 件 4：「机器侧不确定」的判据（顶层纯函数，便于钉测）。
///
/// 一句话口径：**判定结果一个字不改，只是把“机器自己没底”这件事说出口**，
/// 并因此把自证出口提到一级。四种形态都来自仪器，不是来自用户：
///  - [softBand]：灰带 / 句首被吞（ASR-209、ASR-214 F3 的「差一点」）；
///  - [guardOk] 为 false：守门器认为这条转写不可信（噪声、同词堆叠）；
///  - [reason] 落在 `band` / `lowConf` / `empty` / `tooShort`：判定层自己不敢下结论。
/// 已通过与「手改文本 / 打字作答」（文本比对，不是识别不确定）都不算。
/// 本函数**不含任何数字阈值**——阈值单源在 `speech_judge.dart` 与 `asr_guard.dart`，
/// 这里只读它们的结论（钉测见 `test/userpack_d4_test.dart`）。
bool machineUncertain({
  required bool passed,
  required bool edited,
  required bool softBand,
  bool? guardOk,
  String? reason,
}) {
  if (passed || edited) return false;
  if (softBand) return true;
  if (guardOk != null && !guardOk) return true;
  return const ['band', 'lowConf', 'empty', 'tooShort'].contains(reason);
}

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
  // ASR-209：模糊带（差一点）→ 允许重说不扣分；连续 3 次灰带后按普通失败处理。
  bool _softBand = false;
  int _softBands = 0;
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
  // ASR-213 P0-1：录音硬上限（到点自动收口去判定，防「忘了点停止」）。
  Timer? _capTimer;
  // ASR-213 P1-3：失败屏的次要出口折进「更多选择」，一屏只留 1 主 2 次。
  bool _moreExits = false;

  /// ASR-216：本块累计的语音失败次数（含上次会话）。≥2 就把打字出口提到一级。
  int _voiceFails = 0;
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

  /// ASR-214 F3：判定「句首被吞」时拿哪句当参照。
  /// 目标本身就是整句（跟读步）→ 直接用它；目标是词块（自由造句）→
  /// 从本级句子里找第一句含该块的句子，找不到就退回目标本身。
  String get _referenceSentence {
    final t = widget.targetText.trim();
    if (tokenizeSpeech(t).length >= 3) return t;
    final lower = t.toLowerCase();
    for (final p in _phrases) {
      if (p.toLowerCase().contains(lower)) return p;
    }
    return t;
  }

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
    _capTimer?.cancel();
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
    _moreExits = false;
    // ASR-216：进屏先读账——上次已经撞过两次的话，这次一进来就给出口，不再藏。
    _voiceFails = _p.voiceFailCount(widget.chunk.id);
    if (shouldOfferTypingFirst(_voiceFails)) _moreExits = true;
    _levelSub?.cancel();
    _levelSub = _rec.levels.listen(_applyLevel);
    _silence?.attach(_rec.levels);
    // ASR-213 P0-1：硬上限。用户说完忘了点停止，也不能一直停在录音态。
    _capTimer?.cancel();
    _capTimer = Timer(kRecordCap, () {
      if (mounted && _listening) _stop();
    });
  }

  /// ASR-213 P0-1：「识别中…」不再是死等——给一条明确的退路。
  /// 取消只收口 UI 等待，本次不计一次开口尝试（`_attempts` 不加），
  /// 回到待录状态让用户重说。
  void _cancelThinking() {
    _capTimer?.cancel();
    _cancelLevels();
    _stopping = false;
    if (!mounted) return;
    setState(() {
      _thinking = false;
      _thinkingText = '识别中…';
      _judge = null;
      _guard = null;
      _passed = false;
    });
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
    _capTimer?.cancel();
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
      // ASR-213 P0-1：解码预算 3 秒。静音/长录音实测能拖到 10–16 秒，
      // 超预算按空转写收口，交给守门器与判定层走「没听清」分支。
      final r = await recognizeWithinBudget(
          () => _speech.recognizeOpen(usePath, e2ePhrases: _phrases));
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
      // ASR-214 F4：词表并进本级其他句/块。旧实现只喂了词块两个词，实测受限解码
      // 产出 `main course course main` 这种重复串；clip 300/400 ms 时喂整句更好。
      // ASR-214 F5：二过也在 3 s 预算内（ASR-213 只包了一过，二过仍可能干等）。
      final retry = await withinBudget<VoskResult>(() =>
          _speech.recognizeWithTargetGrammarRetry(
            wavPath: _recPath!,
            targetSentence: widget.targetText,
            firstText: text,
            extraPhrases: _phrases,
          ));
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
      final fb = await withinBudget<AsrRetryResult>(() =>
          _speech.retryOpenWithFallback(
            wavPath: _recPath!,
            target: widget.targetText,
            keywords: asrKeywords(widget.targetText),
            skipEnhanced: source == AsrSource.enhanced,
            azureKey: _p.azureKey,
            azureRegion: _p.azureRegion,
          ));
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
    // ASR-216 D：语音判不过就记一笔；任何通道通过都清账。
    if (!passed) {
      _voiceFails++;
      unawaited(_p.noteVoiceFail(widget.chunk.id));
    } else if (_voiceFails > 0) {
      _voiceFails = 0;
      unawaited(_p.clearVoiceFails(widget.chunk.id));
    }
    // ASR-209 灰带：文本已接近但没到判对线，且守门通过 → 不改判、不扣分，给「再录一遍」。
    // ASR-214 F3：句首被吞（尾部逐字对上、缺目标首词）同样按「接近」处理，
    // 不把采集侧丢词算成用户说错（实测丢 300–500 ms 就会落在这里）。
    final onsetLoss = !passed &&
        g.ok &&
        onsetLossSuspected(
            target: widget.targetText,
            recognized: finalText,
            reference: _referenceSentence);
    final softBand = !passed &&
        g.ok &&
        (outcome.band == 'band' || onsetLoss) &&
        _softBands < 3;
    if (softBand) _softBands++;
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
      _softBand = softBand;
    });
    await _resolveAttempt(passed, accuracy: accuracy, softBand: softBand);
  }

  Future<void> _resolveAttempt(bool passed,
      {int accuracy = 0, bool selfEval = false, bool softBand = false}) async {
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
    // ASR-209：灰带不写失败、不累加尝试次数——用户只是差一点，重说不扣分。
    if (softBand) {
      if (!mounted) return;
      setState(() {});
      return;
    }
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

  /// ASR-229 · D4 件 4：低置信自证出口。
  ///
  /// 与 `_selfConfirm(true)` 的差别只有一处：**把「这台机器没听清你」的跨屏账清掉**。
  /// 用户已经明确说「这就是我那句」，继续留着失败账会让下一屏仍按撞墙处理
  /// （ASR-216 的一级打字出口会一直摊开）。判定阈值、记账规则都没改。
  void _selfAttest() {
    if (_voiceFails > 0) {
      _voiceFails = 0;
      unawaited(_p.clearVoiceFails(widget.chunk.id));
    }
    _selfConfirm(true);
  }

  /// 「机器自己没把握」的四种形态：灰带、守门器拒判、空/超短转写、低置信。
  /// 它们是**仪器侧**的不确定，不是用户说错；手改文本/打字作答不算（那是文本比对）。
  /// 「机器侧不确定」的四种形态见 [machineUncertain]；本 getter 只回答一件事：
  /// 现在屏幕上是不是**失败屏**（内容最多的一屏）。
  /// 条件顺序与 build 里的分支链一致，所以它和真正渲染出来的那一支永远同步。
  bool get _failureScreen =>
      !_permBlocked &&
      !_engineFailed &&
      !_showAnswer &&
      !_selfAssess &&
      !_followAlong &&
      !_thinking &&
      !_listening &&
      _judge != null &&
      !_passed;

  /// ASR-229 D4 件 4：低置信判据（灰带 / 守门拒判 / 空 / 低置信 / 过短）。
  bool get _machineUnsure {
    final o = _judge;
    if (o == null) return false;
    return machineUncertain(
      passed: _passed,
      edited: _edited,
      softBand: _softBand,
      guardOk: _guard?.ok,
      reason: o.reason,
    );
  }

  String get _machineUnsureWhy {
    final o = _judge!;
    final pct = (o.similarity * 100).round();
    if (_softBand) {
      return '差一点：核心词没全命中但已经很接近（相似度 $pct%），'
          '机器自己也说不准该不该判你对。';
    }
    if (_guard != null && !_guard!.ok) {
      return '守门器认为这条识别结果不可信（噪声/同词堆叠），'
          '所以没拿它当你的答案。';
    }
    switch (o.reason) {
      case 'empty':
        return '整条录音没检出可信文本——通常是声音太小或离麦太远，不是你读错。';
      case 'lowConf':
        return '识别置信度没到线（相似度 $pct%），机器不敢下判定。';
      case 'tooShort':
        return '检出的内容太短，不够判这一句。';
      default:
        return '相似度 $pct%，机器没把握。';
    }
  }

  /// ASR-229 · D4 件 4：低置信卡片——先承认机器不确定，再给一条自证出口。
  /// ASR-233：卡片本体抽到 `ui/machine_unsure_card.dart`，第 5/6 步共用同一张；
  /// 这里只保留本步真实的记账口径（本步确实写 `l4_self_eval`）。
  Widget _lowConfidenceCard() => MachineUnsureCard(
        why: _machineUnsureWhy,
        onAttest: _recPath == null ? null : _selfAttest,
        note: '这条按「你自己确认」记账，不记发音分；是否算掌握仍走原有门槛'
            '（前面步骤一次通过 + 星级），本页没改任何判定阈值。',
      );

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
  ///
  /// ASR-213 P1-4：**空转写不标红**。静音时 `targetMatched` 全 false，整句目标
  /// 被染红加粗，用户读成「我说错了」，而实际是根本没收到声音——那是设备/权限
  /// 问题，不该用「你说错了」的颜色去说。此时维持正常色，由上方文案负责说明。
  Widget _targetSentence() {
    final judge = _judge;
    final noSpeech = _transcript.trim().isEmpty && !_edited;
    final words =
        judge != null ? judge.targetWords : widget.targetText.split(' ');
    final matched =
        noSpeech ? null : judge?.targetMatched;
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
    // 没填中文意思时，反向练习（看中文说英文）与长按中文卡都没有内容，
    // 直接退化为「看英文开口说」，不摆空白框。
    final hasCn = widget.chunk.meaningCN.trim().isNotEmpty;
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
            child: _reverse && hasCn
                ? Text(widget.chunk.meaningCN,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: kPrimary, fontSize: 18, fontWeight: FontWeight.w600))
                : (hasCn
                    ? CnText(
                        widget.targetText,
                        widget.chunk.meaningCN,
                        style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.w600),
                      )
                    : Text(widget.targetText,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kText, fontSize: 18, fontWeight: FontWeight.w600))),
          ),
          if (hasCn)
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
          Text(_reverse && hasCn ? '看中文，说出英文' : '开口说出来',
              style: TextStyle(color: kTextSecondary)),
          const SizedBox(height: 10),
          if (_judge != null && !_selfAssess) _targetSentence(),
          // ASR-229 D4 装机腿抓到的坑：失败屏内容最多（判定说明 + 低置信卡片 +
          // 三个出口 + 打字出口 + 更多选择），Spacer 居中会把最下面的
          // 「打字作答」顶出屏幕——那一出口是 ASR-216 明令「第一次失败就要给」的。
          // ⇒ 失败态不再居中：装得下就贴顶，装不下就能滚，绝不裁。
          if (_failureScreen) const SizedBox(height: 10) else const Spacer(),
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
                // ASR-213 P0-1：等待期间必须能退出，否则用户只能杀进程。
                TextButton(
                  onPressed: _cancelThinking,
                  child: Text('等太久了？取消重说',
                      style: TextStyle(color: kTextFaint)),
                ),
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
            // 小屏保护（见上面 _failureScreen）：这一支可滚，绝不裁掉出口。
            Expanded(
              child: SingleChildScrollView(
                child: Column(
              children: [
                Text(
                  _transcript.trim().isEmpty && !_edited
                      ? '没听到声音 · 不是你说错了'
                      : (_softBand
                          ? '差一点，再录一遍不扣分'
                          : ((_guard != null && !_guard!.ok)
                              ? '⚠ 没听清，再说一遍'
                              : (_judge!.reason == 'empty' ||
                                      _judge!.reason == 'lowConf' ||
                                      _judge!.reason == 'tooShort'
                                  ? '没有听清，请再说一遍'
                                  : '再试一次（错词已标红）'))),
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
                // ASR-229 D4 件 4：机器侧不确定 → 承认它，并把自证出口放到一级。
                if (_machineUnsure) _lowConfidenceCard(),
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
                // ASR-216：连续两次没被听清 → 明说不是用户的问题，并把打字出口
                // 提成一级按钮（1.8.4 的折叠把它藏在了最需要它的那一屏）。
                ...[
                  Text(shouldOfferTypingFirst(_voiceFails)
                      ? '这台机器两次没听清你——这不是你的问题。'
                      : '说不清也没关系：直接把句子打出来，照样算过。',
                      style: TextStyle(color: kTextSecondary, fontSize: 12),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      onPressed: _judgeEdited,
                      child: Text('打字作答（不计发音分）',
                          style: TextStyle(color: kOnPrimary)),
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                // ASR-213 P1-3：失败屏原本同屏堆 6 个出口（跳过按钮 + 先跳过这一步
                // 文字链重复；看答案 / 跟读不评分 / 打字作答语义重叠）。收成
                // 「1 主 2 次 + 更多选择」，次要出口折叠，减少新人选择瘫痪。
                // ASR-216 起：撞过两次的人默认展开，不再要求他先发现「更多选择」。
                TextButton(
                  onPressed: () => setState(() => _moreExits = !_moreExits),
                  child: Text(_moreExits ? '收起更多选择 ⌃' : '更多选择 ⌄',
                      style: TextStyle(color: kTextFaint)),
                ),
                if (_moreExits) ...[
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
              ],
            ),
              ),
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
                if (_judge?.deviationHint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(_judge!.deviationHint!,
                        key: const Key('l4DeviationHint'),
                        style: TextStyle(color: kTextMuted, fontSize: 12)),
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

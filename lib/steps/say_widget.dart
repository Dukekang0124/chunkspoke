import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/loaders.dart';
import '../services/crash_log.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../services/speech_judge.dart';
import '../services/vosk_engine.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../ui/feedback.dart';

/// SAY 步骤（识别优先级：Vosk 离线默认必通 ＞ Azure 发音评测/增强）：
///  - L1：配了 Azure Key+Region → 录音 → Azure 发音评测（三项分数，高精度增强）。
///  - L2：未配 Key → 原生录音 → Vosk 离线识别 → Text Match 计分（默认，零配置可用）。
///  - L3：原生录音不可用 → 纯自确认兜底（极少触发）。
///  - 引擎加载失败（Vosk 初始化失败且无 Azure）：明确报错，禁止静默落到空壳。
///
/// 采集链路自检（保留）：
///  - 进入即做麦克风权限预检，永久拒绝 → 引导到系统设置，禁止静默失败；
///  - 录音期间显示真实采集电平：说话时跳动=采集正常，全程不动=采集故障；
///  - no-speech 判定前至少完成 2 秒真实采集，排除“秒判没听到”；
///  - “没听到”诊断三分支：无波动→权限/占用；有波动未识别→靠近麦克风；引擎失败→重启/反馈。
class SayWidget extends StatefulWidget {
  final String sentence;
  final String levelId;
  final ValueChanged<double> onDone;
  const SayWidget(
      {required this.sentence, required this.levelId, required this.onDone, super.key});

  @override
  State<SayWidget> createState() => _SayWidgetState();
}

class _SayWidgetState extends State<SayWidget> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();

  bool _hasAzure = false;
  bool _ready = false; // 采集/识别链路是否就绪
  bool _permBlocked = false; // 权限未授予 → 显示引导卡
  bool _engineFailed = false; // Vosk 加载失败（且无 Azure）→ 明确报错
  MicPerm _perm = MicPerm.denied;
  bool _active = false; // 录音中
  bool _thinking = false;
  String? _recPath;
  SayOutcome? _outcome;

  double _level = 0; // 实时电平 0..1
  bool _levelActive = false; // 本次采集是否出现过有效波动
  StreamSubscription<double>? _levelSub;
  DateTime? _listenStart;

  static const double _levelThreshold = 0.04;

  @override
  void initState() {
    super.initState();
    final p = Provider.of<ProgressService>(context, listen: false);
    _hasAzure = p.azureKey != null &&
        p.azureKey!.isNotEmpty &&
        p.azureRegion != null &&
        p.azureRegion!.isNotEmpty;
    _initMic();
    Provider.of<TtsService>(context, listen: false).speak(widget.sentence);
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    // P0 加固：录音中退出必须停掉原生录音线程，避免麦克风/渲染树残留。
    if (_active) {
      _rec.stop();
    }
    _rec.stopPlay();
    super.dispose();
  }

  /// 权限预检 + 采集链路初始化。禁止静默失败；任何异常兜底为引擎失败卡（P0 加固）。
  Future<void> _initMic() async {
    try {
      final perm = await _rec.ensurePermission();
      if (!mounted) return;
      setState(() => _perm = perm);
      if (perm != MicPerm.granted) {
        setState(() {
          _permBlocked = true;
          _ready = false;
        });
        return;
      }
      setState(() => _permBlocked = false);
      if (_hasAzure) {
        setState(() {
          _ready = true;
          _engineFailed = false;
        });
        return;
      }
      // 默认路径：加载 Vosk 离线引擎（必通）。失败则明确报错，不落空壳、不静默。
      final ok = await _speech.initVosk();
      if (!mounted) return;
      setState(() {
        _ready = ok;
        _engineFailed = !ok;
      });
    } catch (e, st) {
      CrashLog.write('Say._initMic: $e', st);
      if (!mounted) return;
      setState(() {
        _permBlocked = false;
        _ready = false;
        _engineFailed = true;
      });
    }
  }

  void _applyLevel(double v) {
    if (!mounted) return;
    if (v > _levelThreshold) _levelActive = true;
    setState(() => _level = v);
  }

  void _subscribeLevels() {
    _levelSub?.cancel();
    _levelSub = _rec.levels.listen(_applyLevel);
  }

  void _cancelLevels() {
    _levelSub?.cancel();
    _levelSub = null;
  }

  Future<void> _start() async {
    if (!_ready || _permBlocked) return;
    final p = Provider.of<ProgressService>(context, listen: false);
    _levelActive = false;
    setState(() => _level = 0);
    // 统一走原生 16k 单声道录音：L1（Azure 评测）与 L2（Vosk 识别）共用采集链路。
    final path = await _rec.start();
    if (path == null) {
      // 原生录音不可用 → L3 纯自确认兜底
      setState(() => _outcome = SayOutcome(passed: false, level: 'L3'));
      return;
    }
    setState(() {
      _recPath = path;
      _active = true;
    });
    _subscribeLevels();
    _listenStart = DateTime.now();
    p.incSay();
  }

  /// 2 秒真实采集宽限：不足则继续采集至满 2 秒，排除“秒判没听到”。
  Future<void> _graceTo2s() async {
    final start = _listenStart;
    if (start == null) return;
    final el = DateTime.now().difference(start);
    if (el < const Duration(seconds: 2)) {
      await Future.delayed(const Duration(seconds: 2) - el);
    }
  }

  Future<void> _stop() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    await _graceTo2s();
    if (!mounted) return;
    setState(() {
      _active = false;
      _thinking = true;
    });

    // L1：Azure 发音评测（用户配了 Key，作为高精度增强）。
    if (_hasAzure && _recPath != null) {
      _cancelLevels();
      // 先停止录音以落盘最终 WAV，再送 Azure 评测（否则读到未结束的片段）。
      final path = await _rec.stop();
      final azPath = path ?? _recPath!;
      final az = await _speech.assessAzure(
          azPath, widget.sentence, p.azureKey!, p.azureRegion!);
      if (!mounted) return;
      // 评测异常且全程无采集波动 → 判定“没听到”（带诊断行），而非静默失败。
      final silent = az.error != null && !_levelActive;
      setState(() {
        _thinking = false;
        _outcome = silent
            ? SayOutcome(
                passed: false,
                level: 'L2',
                recognized: '(no speech)',
                noSpeech: true)
            : SayOutcome(passed: az.passed, level: 'L1', azure: az);
      });
      return;
    }

    // L2（默认）：Vosk 离线识别。
    _cancelLevels();
    final path = await _rec.stop();
    if (!mounted) return;
    final recPath = path ?? _recPath;
    final r = recPath == null
        ? const VoskResult('', null)
        : await _speech.recognize(recPath, [widget.sentence]);
    final text = r.text;
    final conf = r.confidence;
    setState(() {
      _thinking = false;
      _recPath = recPath ?? _recPath;
    });
    if (text.trim().isEmpty) {
      buzzWrong();
      setState(() {
        _outcome = SayOutcome(
          passed: false,
          level: 'L2',
          recognized: '(no speech)',
          noSpeech: true,
        );
      });
      return;
    }
    final j = judgeSpeech(target: widget.sentence, recognized: text, confidence: conf);
    p.recordScore((j.similarity * 100).round());
    final passed = j.pass;
    setState(() {
      _outcome = SayOutcome(
        passed: passed,
        level: 'L2',
        recognized: text,
        textMatchScore: (j.similarity * 100).round(),
        targetMatched: j.targetMatched,
        wrong: !passed,
      );
    });
  }

  void _retry() {
    _cancelLevels();
    setState(() {
      _outcome = null;
      _active = false;
      _thinking = false;
      _level = 0;
      _levelActive = false;
      _listenStart = null;
    });
  }

  void _appeal() {
    // 申诉只记录事件，不推进状态机（避免“乱申诉即放行”的评分漏洞，D1）。
    Provider.of<ProgressService>(context, listen: false)
        .logAppeal(widget.levelId, widget.sentence);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('申诉已记录，我们会复核'), duration: Duration(seconds: 1)));
  }

  double _scoreOf(SayOutcome o) =>
      (o.azure != null ? o.azure!.accuracy : (o.textMatchScore ?? 0)).toDouble();

  Future<void> _confirmSkip(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('跳过本题？', style: TextStyle(color: Colors.white)),
        content: const Text('跳过照读，直接进入开口（本题不计入掌握度）。',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定跳过', style: TextStyle(color: kPrimary)),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDone(0.0);
  }

  /// 诊断行三分支：引擎失败 → 重启/反馈；无波动 → 查权限/占用；有波动未识别 → 靠近麦克风。
  String get _diagText {
    if (_engineFailed) return '识别引擎初始化失败，重启应用或反馈';
    if (_levelActive) return '离麦克风近一点，语速自然';
    return '麦克风可能被占用或未授权，去设置检查';
  }

  bool get _diagIsPerm => !_engineFailed && !_levelActive;

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

  Widget _card({required Color border, required List<Widget> children}) =>
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Column(children: children),
      );

  /// 照读未通过时，把目标句错词标红（按 judgeSpeech 的逐词对齐）。
  Widget _targetDiff(SayOutcome o) {
    final words = normalizeSpeech(widget.sentence)
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toList();
    final m = o.targetMatched;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: List.generate(words.length, (i) {
        final ok = m == null || i >= m.length || m[i];
        return Text(words[i],
            style: TextStyle(
              color: ok ? Colors.white : Colors.redAccent,
              fontSize: 18,
              fontWeight: ok ? FontWeight.normal : FontWeight.bold,
            ));
      }),
    );
  }

  Widget _resultCard(SayOutcome o) {
    if (o.level == 'L1' && o.azure != null) {
      final az = o.azure!;
      return _card(border: o.passed ? kUnlocked : Colors.white24, children: [
        Icon(o.passed ? Icons.check_circle : Icons.refresh,
            color: o.passed ? kUnlocked : kPrimary, size: 36),
        const SizedBox(height: 8),
        const Text('发音测评',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        _scoreRow('准确度', az.accuracy),
        _scoreRow('流利度', az.fluency),
        _scoreRow('完整度', az.completeness),
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
            onPressed: o.passed ? () => widget.onDone(_scoreOf(o)) : _retry,
            child: Text(o.passed ? '下一句' : '再试一次',
                style: const TextStyle(color: Colors.white)),
          ),
        ),
        if (!o.passed)
          TextButton(
            onPressed: _appeal,
            child: const Text('我说的对（申诉）', style: TextStyle(color: Colors.white38)),
          ),
      ]);
    }
    if (o.passed) {
      return _card(border: kUnlocked, children: [
        const Icon(Icons.check_circle, color: kUnlocked, size: 36),
        const SizedBox(height: 8),
        const Text('你说：', style: TextStyle(color: Colors.white, fontSize: 16)),
        const SizedBox(height: 6),
        Text("'${o.recognized}'",
            style: const TextStyle(color: kUnlocked, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('得分：${o.textMatchScore}（文本匹配）',
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
            onPressed: () => widget.onDone(_scoreOf(o)),
            child: const Text('下一句', style: const TextStyle(color: Colors.white)),
          ),
        ),
      ]);
    }
    if (o.noSpeech) {
      return _card(border: Colors.white24, children: [
        const Icon(Icons.mic_off, color: kPrimary, size: 36),
        const SizedBox(height: 8),
        const Text('没听到，再试一次',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        const SizedBox(height: 6),
        Text(_diagText,
            textAlign: TextAlign.center,
            style: const TextStyle(color: kPrimary, fontSize: 14)),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: _retry,
            child: const Text('再试一次', style: const TextStyle(color: Colors.white)),
          ),
        ),
        if (_diagIsPerm)
          TextButton(
            onPressed: () => _rec.openSettings(),
            child: const Text('去设置检查麦克风权限', style: TextStyle(color: Colors.white54)),
          ),
      ]);
    }
    if (o.level == 'L2') {
      final failed = !o.passed;
      return _card(border: Colors.white24, children: [
        const Text('听到：', style: TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 4),
        Text("'${o.recognized}'", style: const TextStyle(color: Colors.white, fontSize: 16)),
        const SizedBox(height: 6),
        if (failed) _targetDiff(o),
        const SizedBox(height: 6),
        Text('相似度：${o.textMatchScore}（词级匹配）',
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: _retry,
            child: const Text('再试一次', style: const TextStyle(color: Colors.white)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _appeal,
            child: const Text('我说的对（申诉）', style: TextStyle(color: Colors.white70)),
          ),
        ),
      ]);
    }
    // L3 自确认（仅原生录音不可用时兜底）
    return _card(border: Colors.white24, children: [
      const Text('录音暂不可用', style: TextStyle(color: Colors.white, fontSize: 18)),
      const SizedBox(height: 6),
      const Text('说出来了就点这里', style: TextStyle(color: Colors.white70, fontSize: 15)),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kUnlocked),
          onPressed: () => widget.onDone(0.0),
          child: const Text('我说了', style: const TextStyle(color: Colors.white)),
        ),
      ),
    ]);
  }

  Widget _permCard() => _card(border: kPrimary, children: [
        const Icon(Icons.mic_off, color: kPrimary, size: 36),
        const SizedBox(height: 8),
        const Text('需要麦克风权限', style: TextStyle(color: Colors.white, fontSize: 18)),
        const SizedBox(height: 6),
        Text(
          _perm == MicPerm.permanentlyDenied
              ? '麦克风权限已被关闭，请到系统设置里打开后返回'
              : '未获得麦克风权限，无法进行朗读评分',
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
                : _initMic,
            child: Text(_perm == MicPerm.permanentlyDenied ? '去设置' : '允许麦克风',
                style: const TextStyle(color: Colors.white)),
          ),
        ),
      ]);

  /// 引擎初始化失败：明确报错，禁止静默落空壳。
  Widget _engineFailedCard() => _card(border: kPrimary, children: [
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
            onPressed: _initMic,
            child: const Text('重试加载引擎', style: TextStyle(color: Colors.white)),
          ),
        ),
      ]);

  Widget _activeView() => Column(
        children: [
          LevelMeter(level: _level),
          const SizedBox(height: 10),
          Text(
            _levelActive ? '麦克风在采集 ● 正常' : '等待声音…（波形不动=麦克风异常）',
            style: TextStyle(
                color: _levelActive ? kUnlocked : Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 18),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: _stop,
            child: const Text('停止', style: TextStyle(color: Colors.white)),
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
          const SizedBox(height: 10),
          Text(widget.sentence,
              style: const TextStyle(color: Colors.white, fontSize: 20)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => speakOrHint(
                context,
                Provider.of<TtsService>(context, listen: false),
                widget.sentence),
            child: const Text('重听', style: TextStyle(color: Colors.white70)),
          ),
          const Spacer(),
          if (_permBlocked)
            _permCard()
          else if (_engineFailed)
            _engineFailedCard()
          else if (_thinking)
            const CircularProgressIndicator(color: kPrimary)
          else if (_outcome != null)
            _resultCard(_outcome!)
          else if (_active)
            _activeView()
          else if (waiting)
            const Column(
              children: [
                CircularProgressIndicator(color: kPrimary),
                SizedBox(height: 10),
                Text('引擎准备中…', style: TextStyle(color: Colors.white54)),
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
                const Text('点按，然后说出来',
                    style: TextStyle(color: Colors.white70)),
              ],
            ),
          const SizedBox(height: 20),
          if (_outcome == null && !waiting && !_permBlocked && !_engineFailed)
            TextButton(
              onPressed: () => _confirmSkip(context),
              child: const Text('跳过', style: TextStyle(color: Colors.white38)),
            ),
        ],
      ),
    );
  }
}

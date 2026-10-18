import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../services/vosk_engine.dart';
import '../services/ai/ai_service.dart';
import '../services/ai/ai_models.dart';
import '../ui/theme.dart';

/// 自由拼句沙盒（v1.4.0 / A1）：
///   - 从「全局已掌握块池」选块拼句（不再限定单场景）；
///   - 预置 3 句推荐组合，一键套用；
///   - 拼好必须「开口判定通过」才计入自由造句次数（并计入今日开口，A2② 同源）；
///   - 支持重拼 + 一键听示范；本期不做保存。
class FreeBuildScreen extends StatefulWidget {
  /// 全局已掌握词块池（由首页入口传入）。
  final List<Chunk> masteredChunks;
  const FreeBuildScreen({required this.masteredChunks, super.key});

  @override
  State<FreeBuildScreen> createState() => _FreeBuildScreenState();
}

class _FreeBuildScreenState extends State<FreeBuildScreen> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  final AIService _ai = AIServiceImpl(); // 云端 AI 评判（失败回退规则引擎）
  bool _engineReady = false;
  bool _engineFailed = false;

  final List<Chunk> _selected = []; // 已选块（按选择顺序）
  List<String> _recommended = const []; // 3 句推荐组合（整句文本）

  bool _recording = false;
  bool _judging = false;
  String? _recognized;
  int _attempts = 0;
  String? _tier; // 'perfect' | 'improve' | 'retry'
  String? _aiFeedback;
  String? _aiCorrected;
  bool _celebrate = false;

  ProgressService get _p => Provider.of<ProgressService>(context, listen: false);

  /// 当前待开口的句子：优先已选块拼接，否则第一条推荐。
  String get _targetText {
    if (_selected.isNotEmpty) {
      return _selected.map((c) => c.text).join(' ');
    }
    return _recommended.isNotEmpty ? _recommended.first : '';
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await SpeechEngine.instance.init();
    } catch (_) {}
    final ready = SpeechEngine.instance.isReady;
    final failed = SpeechEngine.instance.failed;
    final content = Provider.of<ContentPack>(context, listen: false);
    final rec = _genRecommended(content, widget.masteredChunks);
    if (!mounted) return;
    setState(() {
      _engineReady = ready;
      _engineFailed = failed;
      _recommended = rec;
    });
    await _p.logEvent('freebuild_sandbox_open',
        {'pool': widget.masteredChunks.length});
  }

  /// 生成 3 句推荐组合：优先取「其组成块全部已掌握」的整句，不足用已掌握块拼接补足。
  List<String> _genRecommended(ContentPack content, List<Chunk> chunks) {
    final byId = {for (final c in chunks) c.id: c};
    final sentences = <String>[];
    outer:
    for (final lv in content.levels) {
      for (final s in lv.sentences) {
        if (s.chunkIds.isNotEmpty && s.chunkIds.every((id) => byId.containsKey(id))) {
          sentences.add(s.text);
          if (sentences.length >= 3) break outer;
        }
      }
    }
    var i = 0;
    while (sentences.length < 3 && chunks.length >= 2) {
      final a = chunks[i % chunks.length].text;
      final b = chunks[(i + 1) % chunks.length].text;
      final combo = a == b ? a : '$a $b';
      if (!sentences.contains(combo)) sentences.add(combo);
      i++;
    }
    return sentences.take(3).toList();
  }

  @override
  void dispose() {
    _ai.dispose();
    super.dispose();
  }

  void _toggleChunk(Chunk c) {
    if (_judging || _recording) return;
    setState(() {
      if (_selected.contains(c)) {
        _selected.remove(c);
      } else {
        _selected.add(c);
      }
      // 重新拼句后清除上次判定，避免旧反馈残留。
      _tier = null;
      _recognized = null;
      _aiFeedback = null;
      _aiCorrected = null;
      _attempts = 0;
    });
  }

  void _useCombo(String sentence) {
    if (_judging || _recording) return;
    setState(() {
      _selected.clear();
      // 按整句文本反查已掌握块，逐词块回填（找不到则整句作为不可拆目标）。
      _tier = null;
      _recognized = null;
      _aiFeedback = null;
      _aiCorrected = null;
      _attempts = 0;
    });
  }

  void _repick() {
    if (_judging || _recording) return;
    setState(() {
      _selected.clear();
      _tier = null;
      _recognized = null;
      _aiFeedback = null;
      _aiCorrected = null;
      _attempts = 0;
    });
  }

  /// 一键听示范：TTS 朗读当前待开口句（或第一条推荐）。
  void _listenDemo() {
    final t = _targetText;
    if (t.isEmpty) return;
    Provider.of<TtsService>(context, listen: false).speak(t);
  }

  Future<void> _toggleRecord() async {
    if (_judging) return;
    if (_recording) {
      final path = await _rec.stop();
      if (path == null) {
        setState(() => _recording = false);
        return;
      }
      await _judge(path);
      return;
    }
    if (_targetText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('先挑几个词块，或选一句推荐组合'),
          duration: Duration(seconds: 2)));
      return;
    }
    final perm = await _rec.ensurePermission();
    if (perm != MicPerm.granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(perm == MicPerm.permanentlyDenied
            ? '麦克风权限被永久拒绝，请在系统设置中开启'
            : '需要麦克风权限才能开口造句'),
        duration: const Duration(seconds: 2),
      ));
      if (perm == MicPerm.permanentlyDenied) await _rec.openSettings();
      return;
    }
    if (!_engineReady) {
      try {
        await SpeechEngine.instance.init();
        _engineReady = SpeechEngine.instance.isReady;
        _engineFailed = SpeechEngine.instance.failed;
      } catch (_) {}
    }
    final path = await _rec.start();
    if (path == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('录音启动失败，请重试'), duration: Duration(seconds: 2)));
      return;
    }
    setState(() => _recording = true);
  }

  Future<void> _judge(String path) async {
    setState(() {
      _recording = false;
      _judging = true;
      _aiFeedback = null;
      _aiCorrected = null;
    });
    final target = _targetText;
    String text = '';
    try {
      if (_engineReady) {
        final res = await SpeechEngine.instance.transcribeFree(path);
        text = res.text.trim();
      }
    } catch (_) {}
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() {
        _judging = false;
        _recognized = '';
        _tier = 'retry';
        _attempts++;
      });
      return;
    }
    JudgeResult? ai;
    try {
      ai = await _ai.judgeFreeBuild(BuildData(
        scenario: '自由造句',
        chinesePrompt: '用已掌握的词块自由拼一句',
        availableChunks: _selected.map((c) => c.text).toList(),
        userSpeech: text,
      ));
    } catch (_) {}
    String tier;
    if (ai != null) {
      tier = ai.score >= 5
          ? 'perfect'
          : (ai.score >= 4 ? 'improve' : 'retry');
      _aiFeedback = ai.feedback.isNotEmpty ? ai.feedback : null;
      _aiCorrected = ai.corrected.isNotEmpty ? ai.corrected : null;
    } else {
      // 离线规则：与「已选块/目标句」的文本匹配 + 词数下限。
      final tm = _speech.textMatch(target, text);
      final wordCount =
          text.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;
      final structureOk = wordCount >= 3;
      if (tm.hitRate >= 0.8 && structureOk) {
        tier = 'perfect';
      } else if (tm.hitRate >= 0.4) {
        tier = 'improve';
      } else {
        tier = 'retry';
      }
    }
    if (!mounted) return;
    setState(() {
      _judging = false;
      _recognized = text;
      _tier = tier;
      _attempts++;
    });
  }

  /// 完成一次自由造句：仅「开口判定通过」时到达（计入次数 + 今日开口同源）。
  Future<void> _complete() async {
    final p = _p;
    await p.incFreeBuild();
    await p.noteSpoken(); // A2②：沙盒开口通过计入「今日开口」。
    await p.logEvent('freebuild_complete', {'level': 'sandbox'});
    final first = !p.freeBuildBadge;
    if (first) {
      await p.awardFreeBuildBadge();
      await p.logEvent('freebuild_badge');
      if (!mounted) return;
      setState(() => _celebrate = true);
    } else {
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('自由造句沙盒',
            style: TextStyle(color: Colors.white, fontSize: 18)),
      ),
      body: Stack(
        children: [
          _body(),
          if (_celebrate) _celebration(),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_engineReady && !_engineFailed) {
      return const Center(child: CircularProgressIndicator(color: kPrimary));
    }
    final selectedText = _selected.map((c) => c.text).join(' ');
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // 当前拼好的句子
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kPrimary.withOpacity(0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('你的句子',
                  style: TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                selectedText.isEmpty ? '从下面挑词块拼一句，或选一句推荐' : selectedText,
                style: TextStyle(
                  color: selectedText.isEmpty ? Colors.white54 : Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _listenDemo,
                    icon: const Icon(Icons.volume_up, color: kPrimary),
                    label: const Text('一键听示范', style: TextStyle(color: kPrimary)),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _repick,
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                    label: const Text('重拼', style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 3 句推荐组合
        if (_recommended.isNotEmpty) ...[
          const Text('推荐组合（点一下套用）',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 8),
          for (final s in _recommended)
            GestureDetector(
              onTap: () => _useCombo(s),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: kPrimary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kPrimary.withOpacity(0.4)),
                ),
                child: Text(s, style: const TextStyle(color: kPrimary)),
              ),
            ),
          const SizedBox(height: 12),
        ],
        // 已掌握块池
        const Text('已掌握块池（点选拼句）',
            style: TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: widget.masteredChunks.map((c) {
            final on = _selected.contains(c);
            return GestureDetector(
              onTap: () => _toggleChunk(c),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: on
                      ? kPrimary.withOpacity(0.30)
                      : kPrimary.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: on ? kPrimary : kPrimary.withOpacity(0.4),
                      width: on ? 2 : 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.text,
                        style: const TextStyle(
                            color: kPrimary, fontWeight: FontWeight.w600)),
                    if (c.meaningCN.isNotEmpty)
                      Text(c.meaningCN,
                          style:
                              const TextStyle(color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 24),
        if (_engineFailed)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('离线识别引擎未就绪，请重启 App 后重试',
                style: TextStyle(color: Colors.redAccent)),
          )
        else ...[
          Center(
            child: GestureDetector(
              onTap: _toggleRecord,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _recording ? kPrimary : kCard,
                  border: Border.all(color: kPrimary, width: 2),
                ),
                child: Center(
                  child: _judging
                      ? const CircularProgressIndicator(color: kPrimary)
                      : Icon(
                          _recording ? Icons.stop : Icons.mic,
                          size: 40,
                          color: _recording ? Colors.black87 : kPrimary,
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              _recording
                  ? '正在聆听… 再点一下停止'
                  : (_judging ? '识别 / 评句中…' : '拼好句子，点一下开口说'),
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          const SizedBox(height: 20),
          if (_tier != null) _feedback(),
        ],
      ],
    );
  }

  /// 评判反馈三档；仅 perfect（判定通过）出现「完成造句」按钮 → 才计数。
  Widget _feedback() {
    final perfect = _tier == 'perfect';
    final improve = _tier == 'improve';
    final color = perfect
        ? kUnlocked
        : (improve ? kPrimary : Colors.white70);
    final title = perfect
        ? '✅ 通过！'
        : (improve ? '⚠️ 可改进' : '💪 再试试');
    final body = _aiFeedback ??
        (perfect
            ? '判定通过！这句已计入自由造句次数。'
            : (improve ? '意思接近了，照着示范再顺一遍。' : '没听清或没拼对，重拼或再试一次。'));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: color, fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_recognized != null && _recognized!.isNotEmpty)
            Text('你说：$_recognized',
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(color: Colors.white, fontSize: 15)),
          if (_aiCorrected != null && _aiCorrected!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('建议说法：$_aiCorrected',
                style: const TextStyle(color: kPrimary, fontSize: 14)),
          ],
          const SizedBox(height: 14),
          if (perfect)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  foregroundColor: Colors.black87,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _complete,
                child: const Text('完成造句',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            )
          else if (_attempts < 3)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kCard,
                  foregroundColor: kPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: kPrimary)),
                ),
                onPressed: _repick,
                child: const Text('重拼再试'),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  foregroundColor: Colors.black87,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => setState(() {
                  _tier = null;
                  _recognized = null;
                  _attempts = 0;
                }),
                child: const Text('再试一次',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _celebration() => Container(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.emoji_events, color: kPrimary, size: 64),
                const SizedBox(height: 14),
                const Text('成就解锁',
                    style: TextStyle(color: Colors.white54, fontSize: 14)),
                const SizedBox(height: 6),
                const Text('造句新手 🏅',
                    style: TextStyle(
                        color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                const Text('你完成了第一次自由造句！',
                    style: TextStyle(color: Colors.white70, fontSize: 15)),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimary,
                      foregroundColor: Colors.black87,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      setState(() => _celebrate = false);
                      Navigator.of(context).pop();
                    },
                    child: const Text('继续',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

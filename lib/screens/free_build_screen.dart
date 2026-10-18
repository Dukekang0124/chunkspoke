import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../services/vosk_engine.dart';
import '../services/ai/ai_service.dart';
import '../services/ai/ai_models.dart';
import '../ui/labels.dart';
import '../ui/theme.dart';

/// 自由造句场景提示（中文情境），覆盖常见场景，其余走通用兜底。
const Map<String, String> _situations = {
  '餐厅点餐': '你想向服务员预订一张桌子',
  '酒店入住': '你到前台办理入住，想要一间安静的房间',
  '咖啡店': '你想点一杯拿铁，并说要在店里喝',
  '购物': '你在商店看中一件商品，想问价格和尺码',
  '问路': '你在街上迷路了，想问怎么去地铁站',
  '机场': '你在机场办理登机，想托运行李',
  '看病': '你身体不舒服，想告诉医生你的症状',
  '自我介绍': '你在聚会中向新朋友介绍自己',
  '打车': '你想叫一辆出租车去火车站',
  '打电话': '你打电话给朋友，约周末见面',
};

String _situationFor(Level lv) =>
    _situations[lv.theme] ?? '试着用已掌握的词块，围绕「${sceneCn(lv.theme)}」造一个英文句子';

/// 自由造句（P0-四）：离线 Vosk 识别 + 规则引擎评判，不依赖大模型 API。
class FreeBuildScreen extends StatefulWidget {
  final Level level;
  const FreeBuildScreen({required this.level, super.key});

  @override
  State<FreeBuildScreen> createState() => _FreeBuildScreenState();
}

class _FreeBuildScreenState extends State<FreeBuildScreen> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  final AIService _ai = AIServiceImpl(); // 云端 AI 评判（失败回退规则引擎）
  bool _engineReady = false;
  bool _engineFailed = false;
  List<Chunk> _available = [];
  String _situation = '';
  bool _recording = false;
  bool _judging = false;
  String? _recognized;
  int _attempts = 0;
  String? _tier; // 'perfect' | 'improve' | 'retry'
  String? _aiFeedback; // 云端 AI 反馈（优先展示）
  String? _aiCorrected; // 云端 AI 建议说法
  bool _celebrate = false;

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
    final p = Provider.of<ProgressService>(context, listen: false);
    final mastered =
        (await p.chunkStore.allMasteredKeys()).toSet();
    final masteredChunks =
        widget.level.chunks.where((c) => mastered.contains(c.id)).toList();
    masteredChunks.shuffle(Random());
    final n = max(3, min(5, masteredChunks.length));
    final pick = masteredChunks.take(n).toList();
    if (!mounted) return;
    setState(() {
      _engineReady = ready;
      _engineFailed = failed;
      _available = pick;
      _situation = _situationFor(widget.level);
    });
    await p.logEvent('freebuild_open', {'level': widget.level.id});
  }

  @override
  void dispose() {
    _ai.dispose();
    super.dispose();
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
    // 优先用云端 AI 评判；失败/离线则回退离线规则引擎（保持离线优先）。
    JudgeResult? ai;
    try {
      ai = await _ai.judgeFreeBuild(BuildData(
        scenario: sceneCn(widget.level.theme),
        chinesePrompt: _situation,
        availableChunks: _available.map((c) => c.text).toList(),
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
      final tm = _speech.textMatch(
          _available.map((c) => c.text).join(' '), text);
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

  /// 完成一次自由造句（计入次数；首次触发徽章 + 庆祝）。
  Future<void> _complete() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    await p.incFreeBuild();
    await p.logEvent('freebuild_complete', {'level': widget.level.id});
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

  String get _hintSentence {
    final a = _available.isNotEmpty ? _available.first.text : '';
    final b = _available.length > 1 ? _available[1].text : '';
    return b.isEmpty ? "'$a'" : "'$a $b'";
  }

  String get _missingChunk {
    if (_recognized == null || _recognized!.isEmpty) {
      return _available.isNotEmpty ? _available.first.text : '';
    }
    final rec = _recognized!.toLowerCase();
    for (final c in _available) {
      if (!rec.contains(c.text.toLowerCase())) return c.text;
    }
    return _available.isNotEmpty ? _available.first.text : '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(sceneCn(widget.level.theme),
            style: const TextStyle(color: Colors.white, fontSize: 18)),
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
      return const Center(
          child: CircularProgressIndicator(color: kPrimary));
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Step 1：场景提示
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
              const Text('情境',
                  style: TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(_situation,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 可用词块
        const Text('可用词块（挑几个串起来）',
            style: TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _available
              .map((c) => Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: kPrimary.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kPrimary.withOpacity(0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.text,
                            style: const TextStyle(
                                color: kPrimary, fontWeight: FontWeight.w600)),
                        if (c.meaningCN.isNotEmpty)
                          Text(c.meaningCN,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ))
              .toList(),
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
          // 录音按钮
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
                  : (_judging ? '识别 / 评句中…' : '点一下开始说话'),
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          const SizedBox(height: 20),
          if (_tier != null) _feedback(),
        ],
        const SizedBox(height: 20),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('先跳过', style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }

  /// 评判反馈三档 + 重试 / 完成。
  Widget _feedback() {
    final perfect = _tier == 'perfect';
    final improve = _tier == 'improve';
    final color = perfect
        ? kUnlocked
        : (improve ? kPrimary : Colors.white70);
    final title = perfect
        ? '✅ 完美'
        : (improve ? '⚠️ 可改进' : '💪 再试试');
    final body = _aiFeedback ??
        (perfect
            ? '太棒了！你用了 ${_available.take(2).map((c) => '「${c.text}」').join(' 和 ')}，组合得很自然！'
            : (improve
                ? '意思对了！试试加上「${_missingChunk}」，说 $_hintSentence 更地道。'
                : '没关系，提示：用「${_missingChunk}」可以说 $_hintSentence。'));
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
              style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w700)),
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
          if (perfect || improve)
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
                onPressed: () => setState(() {
                  _tier = null;
                  _recognized = null;
                }),
                child: const Text('再试一次'),
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
                onPressed: _complete,
                child: const Text('完成造句'),
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

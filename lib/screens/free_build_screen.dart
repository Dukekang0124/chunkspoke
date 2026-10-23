import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../services/asr_guard.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/sandbox_store.dart';
import '../services/speech.dart';
import '../services/vosk_engine.dart';
import '../services/ai/ai_service.dart';
import '../services/ai/ai_models.dart';
import '../ui/feedback.dart';
import '../ui/theme.dart';

/// 自由造句沙盒（指令 O 重构，1.5.3）：词块资产生命周期「用」的终点站。
///
/// 布局铁律：页面高度恒定，**块池是唯一的滚动区**，mic 永远固定在底栏拇指区；
/// 200 块与 20 块的骨架完全一致（顶部句子卡 / 中部筛选条 / 中间块池 / 底栏推荐+mic）。
/// 视觉沿用暗金主题，本轮只动布局与信息架构。
class FreeBuildScreen extends StatefulWidget {
  /// 全局已学词块池（由首页入口传入）。
  final List<Chunk> learnedChunks;
  const FreeBuildScreen({required this.learnedChunks, super.key});

  @override
  State<FreeBuildScreen> createState() => _FreeBuildScreenState();
}

class _FreeBuildScreenState extends State<FreeBuildScreen> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();
  final AIService _ai = AIServiceImpl();

  bool _engineReady = false;
  bool _engineFailed = false;

  /// 已选块（按选择顺序）。
  final List<Chunk> _selected = [];

  /// 重录旧句时，块可能已不在池里——此时以整句为判定目标。
  String? _targetOverride;

  String _query = '';
  String? _scene; // null = 全部场景
  List<MergedChunk> _pool = const [];
  Map<String, String> _sceneOf = const {};
  List<SceneTag> _tags = const [];
  List<String> _recentIds = const [];
  Set<String> _masteredIds = {};
  Set<String> _relearningIds = {};

  bool _searchTouched = false;
  bool _filterTouched = false;

  bool _recording = false;
  bool _judging = false;
  String? _recognized; // B5：ASR 原始输出，一字不改
  AsrGuardResult? _guard;
  SilenceAutoStop? _silence;
  String? _tier; // perfect | improve | retry
  String? _aiCorrected;
  bool _storedChain = false;
  int _sentenceCount = 0;

  ProgressService get _p =>
      Provider.of<ProgressService>(context, listen: false);

  String get _targetText {
    if (_targetOverride != null) return _targetOverride!;
    return _selected.map((c) => c.text).join(' ');
  }

  bool get _hasSentence => _targetText.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // 说完 1.2s 静音自动截断，避免环境音/尾音继续喂给解码器。
    _silence = SilenceAutoStop(onSilence: () {
      if (mounted && _recording && !_judging) _toggleRecord();
    });
    _prepare();
  }

  Future<void> _prepare() async {
    // context 只能在 await 之前用；先取依赖，再等引擎与建库查询。
    final content = Provider.of<ContentPack>(context, listen: false);
    final progress = _p;
    final useOverride = SpeechService.debugTranscriberOverride != null;
    if (!useOverride) {
      try {
        await SpeechEngine.instance.init();
      } catch (_) {}
    }
    final rows = await progress.chunkStore.allRows();
    _masteredIds = masteredIdsOf(rows);
    _relearningIds = relearningIdsOf(rows);
    _sceneOf = {
      for (final lv in content.levels)
        for (final c in lv.chunks) c.id: lv.id,
    };
    final pool = dedupePool(widget.learnedChunks);
    _tags = sceneTags(content, _sceneOf);
    final ordered = orderPool(
        pool: pool, lastUsed: progress.sandbox.lastUsedAt, sceneOf: _sceneOf);
    if (!mounted) return;
    setState(() {
      _engineReady = useOverride || SpeechEngine.instance.isReady;
      _engineFailed = !useOverride && SpeechEngine.instance.failed;
      _pool = ordered;
      _recentIds = ordered
          .where((c) => (progress.sandbox.lastUsedAt[c.id] ?? 0) > 0)
          .map((c) => c.id)
          .take(12)
          .toList();
      _sentenceCount = progress.sandbox.sentences.length;
    });
    await progress.sandbox.recordVisit();
    await progress.logEvent(
        'freebuild_sandbox_open', {'pool': widget.learnedChunks.length});
  }

  @override
  void dispose() {
    _silence?.detach();
    // P0 加固：录音中退出必须停掉原生录音线程，避免麦克风/渲染树残留。
    if (_recording) _rec.stop();
    _rec.stopPlay();
    _ai.dispose();
    super.dispose();
  }

  // —— 块池选择 ——

  void _toggle(MergedChunk m) {
    if (_judging || _recording) return;
    setState(() {
      _targetOverride = null;
      final hit = _selected.where((c) => m.ids.contains(c.id)).toList();
      if (hit.isNotEmpty) {
        _selected.removeWhere((c) => m.ids.contains(c.id));
      } else {
        final chunk = widget.learnedChunks.firstWhere((c) => c.id == m.id);
        _selected.add(chunk);
      }
      _clearFeedback();
    });
  }

  void _clearFeedback() {
    _tier = null;
    _recognized = null;
    _guard = null;
    _aiCorrected = null;
    _storedChain = false;
  }

  void _repick() {
    if (_judging || _recording) return;
    setState(() {
      _selected.clear();
      _targetOverride = null;
      _clearFeedback();
    });
  }

  /// 推荐组合：按整句反查池内块并逐块填入（反查不到则整句作目标）。
  void _useCombo(String sentence) {
    if (_judging || _recording) return;
    final byNorm = <String, Chunk>{
      for (final c in widget.learnedChunks) c.text.toLowerCase().trim(): c,
    };
    final picked = <Chunk>[];
    final words = sentence.split(' ');
    for (var i = 0; i < words.length; i++) {
      for (var len = 4; len >= 1; len--) {
        if (i + len > words.length) continue;
        final cand = words.sublist(i, i + len).join(' ').toLowerCase().trim();
        final hit = byNorm[cand];
        if (hit != null) {
          if (!picked.any((c) => c.id == hit.id)) picked.add(hit);
          i += len - 1;
          break;
        }
      }
    }
    setState(() {
      _selected
        ..clear()
        ..addAll(picked);
      _targetOverride = picked.isEmpty ? sentence : null;
      _clearFeedback();
    });
  }

  // —— 搜索 / 筛选 ——

  void _onQuery(String v) {
    setState(() {
      _query = v;
      if (v.trim().isNotEmpty) _searchTouched = true;
    });
  }

  void _onScene(String? id) {
    setState(() {
      _scene = id;
      if (id != null) _filterTouched = true;
    });
  }

  List<MergedChunk> get _visible {
    final q = _query;
    final s = _scene;
    return _pool
        .where((c) => (s == null || _sceneOf[c.id] == s) && matchesQuery(c, q))
        .toList();
  }

  List<MergedChunk> get _recent => _recentIds
      .map((id) => _pool.where((c) => c.id == id).toList())
      .where((l) => l.isNotEmpty)
      .map((l) => l.first)
      .toList();

  // —— 试听 / 长按浮层 ——

  void _speak(String text) {
    if (text.trim().isEmpty) return;
    // 录音中禁用 TTS，防止扬声器回授被麦克风自吞。
    if (_recording || _judging) return;
    speakOrHint(context, Provider.of<TtsService>(context, listen: false), text);
  }

  void _showChipSheet(MergedChunk m) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(m.text,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700)),
                  ),
                  if (_relearningIds.contains(m.id)) _amberTag(),
                ],
              ),
              const SizedBox(height: 10),
              if (m.meanings.isEmpty)
                const Text('这份内容没写中文释义',
                    style: TextStyle(color: Colors.white54))
              else
                for (final meaning in m.meanings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('· $meaning',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 15)),
                  ),
              if (m.mergedCount > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('同名 ${m.mergedCount} 块已合并显示',
                      style: const TextStyle(color: kPrimary, fontSize: 13)),
                ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _speak(m.text),
                    icon: const Icon(Icons.volume_up, color: kPrimary),
                    label: const Text('试听', style: TextStyle(color: kPrimary)),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _toggle(m);
                    },
                    child:
                        const Text('加入句子', style: TextStyle(color: kUnlocked)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _amberTag() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: kPrimary.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimary.withValues(alpha: 0.6)),
        ),
        child:
            const Text('需重修', style: TextStyle(color: kPrimary, fontSize: 11)),
      );

  // —— 开口与判定 ——

  Future<void> _toggleRecord() async {
    if (_judging) return;
    if (_recording) {
      _silence?.detach();
      final path = await _rec.stop();
      if (path == null) {
        setState(() => _recording = false);
        return;
      }
      await _judge(path);
      return;
    }
    if (!_hasSentence) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('先挑块拼一句'), duration: Duration(seconds: 2)));
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
    // TTS 播放期间禁采集：先停朗读与试听，防止回授自吞。
    if (!mounted) return;
    try {
      Provider.of<TtsService>(context, listen: false).stop();
    } catch (_) {}
    await _rec.stopPlay();
    final path = await _rec.start();
    if (path == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('录音启动失败，请重试'), duration: Duration(seconds: 2)));
      return;
    }
    _guard = null;
    _silence?.attach(_rec.levels);
    setState(() => _recording = true);
  }

  Future<void> _judge(String path) async {
    setState(() {
      _recording = false;
      _judging = true;
      _clearFeedback();
    });
    final target = _targetText;
    String text = '';
    List<double> wordConfs = const [];
    try {
      // B5：开放输出走全模型（不传场景词表），原文不做任何改写。
      final res = await _speech.recognizeOpen(path, e2ePhrases: [target]);
      text = res.text.trim();
      wordConfs = res.wordConfidences;
    } catch (_) {}
    if (!mounted) return;
    final guard = guardAsr(
        raw: text,
        wordConfidences: wordConfs,
        targetBlock: target,
        checkChunkStack: true);
    if (text.isEmpty || !guard.ok) {
      setState(() {
        _judging = false;
        _recognized = text;
        _guard = guard;
        _tier = 'retry';
      });
      return;
    }
    JudgeResult? ai;
    // 隐私门：关掉「AI 联网点评」后不发任何请求，直接走本机规则判定。
    if (_p.aiNetOn) {
      try {
        ai = await _ai.judgeFreeBuild(BuildData(
          scenario: '自由造句',
          chinesePrompt: '用已学的词块自由拼一句',
          availableChunks: _selected.map((c) => c.text).toList(),
          userSpeech: text,
        ));
      } catch (_) {}
    }
    String tier;
    final tm = _speech.textMatch(target, text);
    final wordCount =
        text.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;
    final structureOk = wordCount >= 3;
    // B5 通过条件：目标块命中 + confidence/垃圾启发式达标（guard 已在上面拦截）。
    if (ai != null) {
      tier = ai.score >= 5 ? 'perfect' : (ai.score >= 4 ? 'improve' : 'retry');
      _aiCorrected = ai.corrected.isNotEmpty ? ai.corrected : null;
      if (tier == 'perfect' && (tm.hitRate < 0.8 || !structureOk)) {
        tier = 'improve';
      }
    } else {
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
      _guard = guard;
      _tier = tier;
    });
    if (tier == 'perfect') await _store();
  }

  /// 通过即自动入库：计数、串联判定、今日开口、成就。
  Future<void> _store() async {
    final p = _p;
    final chain = await p.sandbox.addSentence(_selected, _masteredIds);
    await p.incFreeBuild();
    await p.noteSpoken();
    await p.logEvent(
        'freebuild_complete', {'level': 'sandbox', 'chain': chain ? 1 : 0});
    if (_searchTouched) await p.sandbox.recordSearch();
    if (_filterTouched) await p.sandbox.recordFilter();
    final first = !p.freeBuildBadge;
    if (!mounted) return;
    setState(() {
      _sentenceCount = p.sandbox.sentences.length;
      _storedChain = chain;
      _recentIds = [
        ..._selected.map((c) => c.id),
        ..._recentIds.where((id) => !_selected.any((s) => s.id == id)),
      ].take(12).toList();
    });
    if (first) {
      await p.awardFreeBuildBadge();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('造句新手 🏅 成就已解锁'), duration: Duration(seconds: 2)));
    }
  }

  // —— 我的句子 ——

  void _showSentences() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCard,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          // 每次重建都重新取一遍：删除后 setSheet 才拿得到新列表（旧写法把 list 提在外面，删了也不刷新）。
          final list = _p.sandbox.sentences;
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * 0.6,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: [
                        const Text('我的句子',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text('${list.length} 句',
                            style: const TextStyle(color: kPrimary)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: list.isEmpty
                        ? const Center(
                            child: Text('还没有通过的句子。\n拼一句、点下面的麦克风说出来即可。',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white54)))
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (_, i) {
                              final s = list[i];
                              return ListTile(
                                title: Text(s.text,
                                    style:
                                        const TextStyle(color: Colors.white)),
                                subtitle: Text(
                                    '${s.chunkIds.length} 块'
                                    '${s.chain ? ' · 串联（≥2 个已掌握块）' : ''}',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 12)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.volume_up,
                                          color: kPrimary),
                                      onPressed: () => _speak(s.text),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.mic,
                                          color: kUnlocked),
                                      onPressed: () {
                                        Navigator.of(sheetContext).pop();
                                        setState(() {
                                          _selected.clear();
                                          _targetOverride = s.text;
                                          _clearFeedback();
                                        });
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(const SnackBar(
                                                content: Text('这句已放回，点麦克风再说一遍'),
                                                duration:
                                                    Duration(seconds: 2)));
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          color: Colors.white38),
                                      onPressed: () async {
                                        await _p.sandbox
                                            .deleteSentence(s.createdAt);
                                        setSheet(() {});
                                        if (!mounted) return;
                                        setState(() => _sentenceCount =
                                            _p.sandbox.sentences.length);
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // —— 布局：三区固定 + 唯一滚动区 ——

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('自由造句沙盒 · $_sentenceCount 句',
            style: const TextStyle(color: Colors.white, fontSize: 18)),
        actions: [
          IconButton(
            key: const Key('sandboxMySentences'),
            icon: const Icon(Icons.auto_stories, color: kPrimary),
            tooltip: '我的句子',
            onPressed: _showSentences,
          ),
        ],
      ),
      body: !_engineReady && !_engineFailed
          ? const Center(child: CircularProgressIndicator(color: kPrimary))
          : Column(
              children: [
                _sentenceCard(),
                _feedbackStrip(),
                _filterBar(),
                Expanded(child: _poolView()),
                _dock(),
              ],
            ),
    );
  }

  Widget _sentenceCard() {
    final empty = !_hasSentence;
    return Container(
      key: const Key('sandboxSentenceCard'),
      height: 132,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kPrimary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('你的句子',
              style: TextStyle(color: kPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              empty ? '从下面挑块拼一句' : _targetText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: empty ? Colors.white54 : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Row(
            children: [
              TextButton.icon(
                key: const Key('sandboxListenDemo'),
                onPressed: empty ? null : () => _speak(_targetText),
                icon: const Icon(Icons.volume_up, color: kPrimary),
                label: const Text('听示范', style: TextStyle(color: kPrimary)),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('sandboxRepick'),
                onPressed: (empty || _selected.isEmpty) ? _repick : _repick,
                icon: const Icon(Icons.refresh, color: Colors.white70),
                label:
                    const Text('重拼', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 反馈条高度固定：没有反馈时留同一块空白，页面骨架不随判定结果跳动。
  /// B5：原文行与校验结论分立——原文恒上屏，结论只描述校验，不改写话语。
  Widget _feedbackStrip() {
    const height = 96.0;
    final t = _tier;
    if (t == null) {
      return Container(
        key: const Key('sandboxFeedbackSlot'),
        height: height,
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: kCard.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text('拼好句子，点下面的麦克风开口说',
            style: TextStyle(color: Colors.white38, fontSize: 13)),
      );
    }
    final perfect = t == 'perfect';
    final improve = t == 'improve';
    final guardFailed = _guard != null && !_guard!.ok;
    final color = perfect ? kUnlocked : (improve ? kPrimary : Colors.white70);
    final title = perfect
        ? (_storedChain ? '已存入我的句子 · 串联 +1' : '通过！已存入我的句子')
        : (improve
            ? '意思接近了，再顺一遍'
            : (guardFailed ? '⚠ 没听清，再说一遍' : '✗ 和目标句还不一致'));
    final rawLine = _recognized == null
        ? null
        : '你说：${_recognized!.isEmpty ? '（没听到）' : _recognized}';
    final refLine = (_aiCorrected == null || _aiCorrected!.isEmpty)
        ? null
        : '参考说法：$_aiCorrected';
    return Container(
      key: const Key('sandboxFeedbackSlot'),
      height: height,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                if (rawLine != null)
                  Text(rawLine,
                      key: const Key('sandboxAsrRaw'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13)),
                if (refLine != null)
                  Text(refLine,
                      key: const Key('sandboxReference'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          if (!perfect)
            TextButton(
              key: const Key('sandboxRetry'),
              onPressed: () => setState(_clearFeedback),
              child: const Text('再说一次', style: TextStyle(color: kPrimary)),
            ),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      key: const Key('sandboxFilterBar'),
      height: 96,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: TextField(
              key: const Key('sandboxSearch'),
              controller: _searchCtl,
              onChanged: _onQuery,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: '搜词块（英文或中文释义）',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                prefixIcon:
                    const Icon(Icons.search, color: Colors.white38, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                filled: true,
                fillColor: kCard,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView(
              key: const Key('sandboxSceneChips'),
              scrollDirection: Axis.horizontal,
              children: [
                _sceneChip(null, '全部', _pool.length),
                for (final t in _tags) _sceneChip(t.id, t.label, t.count),
              ],
            ),
          ),
        ],
      ),
    );
  }

  final TextEditingController _searchCtl = TextEditingController();

  Widget _sceneChip(String? id, String label, int count) {
    final on = _scene == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => _onScene(id),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: on ? kPrimary.withValues(alpha: 0.24) : kCard,
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: on ? kPrimary : kPrimary.withValues(alpha: 0.3)),
          ),
          child: Text('$label · $count',
              style: TextStyle(
                  color: on ? kPrimary : Colors.white54, fontSize: 13)),
        ),
      ),
    );
  }

  /// 分组标题用人能读的场景名（标签数据源＝内容 schema 的 theme），不是场景 id。
  String _sceneLabel(String id) {
    for (final t in _tags) {
      if (t.id == id) return t.label;
    }
    return id;
  }

  /// 唯一滚动区：最近使用（横滑一行）→ 按场景分组（SliverList 懒建，200 块也不卡）。
  Widget _poolView() {
    final visible = _visible;
    if (visible.isEmpty) {
      return const Center(
        child: Text('这个筛选下没有词块\n换个关键词或点「全部」',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38)),
      );
    }
    final groups = <String, List<MergedChunk>>{};
    for (final c in visible) {
      groups.putIfAbsent(_sceneOf[c.id] ?? '其他', () => []).add(c);
    }
    final recent =
        _recent.where((c) => visible.any((v) => v.id == c.id)).toList();
    return CustomScrollView(
      key: const Key('sandboxPool'),
      slivers: [
        if (recent.isNotEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 66,
              child: ListView(
                key: const Key('sandboxRecentRow'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final m in recent)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _chip(m, compact: true),
                    ),
                ],
              ),
            ),
          ),
        for (final g in groups.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(_sceneLabel(g.key),
                  style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, row) {
                final take = g.value.skip(row * 2).take(2).toList();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final m in take) Expanded(child: _chip(m)),
                      if (take.length == 1) const Expanded(child: SizedBox()),
                    ],
                  ),
                );
              },
              childCount: (g.value.length / 2).ceil(),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Widget _chip(MergedChunk m, {bool compact = false}) {
    final on = _selected.any((c) => m.ids.contains(c.id));
    final relearn = _relearningIds.contains(m.id);
    return GestureDetector(
      onTap: () => _toggle(m),
      onLongPress: () => _showChipSheet(m),
      child: Container(
        constraints: BoxConstraints(maxWidth: compact ? 200 : double.infinity),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: on ? kPrimary.withValues(alpha: 0.30) : kPrimary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: on ? kPrimary : kPrimary.withValues(alpha: 0.4),
              width: on ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(m.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: kPrimary, fontWeight: FontWeight.w600)),
                ),
                if (relearn) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.autorenew, color: kPrimary, size: 14),
                ],
              ],
            ),
            if (!compact && m.meanings.isNotEmpty)
              Text(m.meanings.first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  /// 底栏固定：推荐横滑一行 + mic（拇指区）。块再多也不被顶走。
  Widget _dock() {
    final combos = _recommended();
    return Container(
      key: const Key('sandboxDock'),
      decoration: BoxDecoration(
        color: kBg,
        border: Border(top: BorderSide(color: kPrimary.withValues(alpha: 0.2))),
      ),
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: ListView(
              key: const Key('sandboxRecommend'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final s in combos)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _useCombo(s),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: kPrimary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: kPrimary.withValues(alpha: 0.4)),
                        ),
                        child: Text(s,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(color: kPrimary, fontSize: 13)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                key: const Key('sandboxMic'),
                onTap: _toggleRecord,
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !_hasSentence
                        ? kLocked
                        : (_recording ? kPrimary : kCard),
                    border: Border.all(
                        color: _hasSentence ? kPrimary : Colors.white24,
                        width: 2),
                  ),
                  child: Center(
                    child: _judging
                        ? const CircularProgressIndicator(
                            color: kPrimary, strokeWidth: 2)
                        : Icon(
                            _recording ? Icons.stop : Icons.mic,
                            size: 30,
                            color: !_hasSentence
                                ? Colors.white38
                                : (_recording ? Colors.black87 : kPrimary),
                          ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _engineFailed
                ? '离线识别引擎未就绪，请重启 App 后重试'
                : _recording
                    ? '正在聆听… 再点一下停止'
                    : (_judging
                        ? '识别 / 评句中…'
                        : (_hasSentence ? '点一下开口说这句' : '先挑块拼一句')),
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// 推荐组合：池里现成能拼的整句（含合并块），最多 6 句。
  List<String> _recommended() {
    final texts = <String>[];
    for (final lv in Provider.of<ContentPack>(context, listen: false).levels) {
      for (final s in lv.sentences) {
        if (s.chunkIds.length >= 2 &&
            s.chunkIds.every((id) => _pool.any((c) => c.ids.contains(id)))) {
          texts.add(s.text);
          if (texts.length >= 6) return texts;
        }
      }
    }
    return texts;
  }
}

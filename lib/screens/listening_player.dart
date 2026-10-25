import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../models/listening_article.dart';
import '../services/asr_guard.dart';
import '../services/chunk_asset.dart';
import '../services/listening_audio.dart';
import '../services/listening_learn.dart';
import '../services/listening_palette.dart';
import '../services/listening_player.dart';
import '../services/listening_shadow.dart';
import '../services/loaders.dart';
import '../services/recording.dart';
import '../services/speech.dart';
import '../steps/practice_loop.dart';
import '../ui/feedback.dart';
import '../ui/sheet.dart';
import '../ui/theme.dart';
import '../ui/confetti.dart';
import '../ui/motion.dart';
import '../ui/permission_preprompt.dart';
import '../ui/play_pause_morph.dart';
import '../ui/pressable.dart';

/// 浸泡层播放页（应用内）。
///
/// 三色阶梯：蓝=候选、琥珀=在学（learning/consolidating/consolidated/
/// longTerm/relearning）、金=已掌握；点击浮层写学习数据。
class ListeningPlayerPage extends StatefulWidget {
  final ListeningArticle article;

  /// 从「今日复习播单」进入：到期块琥珀脉动，点块仍走既有复习正路（§二.1）。
  final bool reviewRun;

  const ListeningPlayerPage(
      {super.key, required this.article, this.reviewRun = false});

  @override
  State<ListeningPlayerPage> createState() => _ListeningPlayerPageState();
}

class _ListeningPlayerPageState extends State<ListeningPlayerPage>
    with SingleTickerProviderStateMixin {
  late ListeningPlayerController _c;
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _sentenceKeys = [];
  Map<String, ChunkAssetState> _states = {};
  int _lastIndex = -1;
  bool _notifiedComplete = false;
  double? _dragMs;

  /// 到期块琥珀脉动（指令 S §二.1）：仅复习播单进入时启动，避免常驻重绘。
  late final AnimationController _pulse;
  final Set<String> _dueChunkIds = {};
  bool _chunksOpen = false;

  /// 译文开关（§二.5）：默认开，偏好落库。
  bool _showTranslation = true;

  /// M1（#25 补齐）：收词六步真的走完才置位——撒花是氛围层，状态没变不放（DDS §24.2 R1）。
  bool _celebrateSix = false;

  /// 讲解徽标里展示块面用（候选块也在 article.chunks 里）。
  late final Map<String, String> _articleChunkText = {
    for (final c in widget.article.chunks) c.id: c.text,
  };

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.article.sentences.length; i++) {
      _sentenceKeys.add(GlobalKey());
    }
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _showTranslation = Provider.of<ProgressService>(context, listen: false)
        .listening
        .showTranslation;
    _createController();
    _loadStates();
    if (widget.reviewRun) unawaited(_loadDueChunks());
    // M1（#64）：取消进页面即静默索取通知——改到首次完听后带说明再问。
  }

  /// 复习播单入口：只读「哪些块到期」，不改任何到期时间（禁 force due-now）。
  Future<void> _loadDueChunks() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final rows = await progress.chunkStore.allRows();
    if (!mounted) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final due = {
      for (final r in rows)
        if (r.dueDate > 0 && r.dueDate <= nowMs && r.assetState.isReviewable)
          r.chunkKey
    };
    final inArticle = {
      for (final a in widget.article.chunks)
        if (due.contains(a.id)) a.id
    };
    setState(() {
      _dueChunkIds
        ..clear()
        ..addAll(inArticle);
    });
    if (_dueChunkIds.isNotEmpty && Motion.of(context).animates) {
      _pulse.repeat(reverse: true); // 到期块琥珀脉动（M1 起过闸）
    }
  }

  void _createController() {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final tts = Provider.of<TtsService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    _c = ListeningPlayerController(
      progress: progress,
      tts: tts,
      article: widget.article,
      content: content,
      loadStates: () async {
        final rows = await progress.chunkStore.allRows();
        return {for (final r in rows) r.chunkKey: r.assetState};
      },
    )
      ..onNotice = (m) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
        );
      }
      ..addListener(_onChange);
    _c.open();
  }

  Future<void> _loadStates() async {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final rows = await progress.chunkStore.allRows();
    if (!mounted) return;
    setState(() {
      _states = {
        ..._states,
        for (final r in rows) r.chunkKey: r.assetState,
      };
    });
  }

  void _onChange() {
    if (!mounted) return;
    final idx = _c.currentIndex;
    if (idx != _lastIndex) {
      _lastIndex = idx;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(idx));
    }
    if (_c.completed && !_notifiedComplete) {
      _notifiedComplete = true;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('本篇已播完，浸泡时长已记录'),
        duration: Duration(seconds: 2),
      ));
      unawaited(_maybeAskNotifications());
    }
    setState(() {});
  }

  /// M1（#64）：情境化索取——刚完听这一篇、且从没问过，才弹「为什么需要通知」说明卡。
  Future<void> _maybeAskNotifications() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    if (p.notifEnabled || p.notifAskDone) return;
    await p.setNotifAskDone();
    if (!mounted) return;
    await ensureNotificationsWithPreprompt(context);
  }

  void _scrollTo(int index) {
    if (!_scroll.hasClients || index < 0 || index >= _sentenceKeys.length) {
      return;
    }
    final ctx = _sentenceKeys[index].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      alignment: 0.35,
    );
  }

  void _retry() {
    final old = _c;
    old.removeListener(_onChange);
    _createController();
    setState(() {
      _lastIndex = -1;
      _notifiedComplete = false;
      _dragMs = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _pulse.dispose();
    _c.removeListener(_onChange);
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.article.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17)),
            Row(
              children: [
                Text(
                  '${widget.article.sceneLabel} · '
                  '${widget.article.sentences.length} 句',
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
                const SizedBox(width: 6),
                _levelBadge(widget.article.level),
                const SizedBox(width: 6),
                Text('默认 ${_c.baseRate}x',
                    style:
                        const TextStyle(fontSize: 11, color: Colors.white38)),
              ],
            ),
          ],
        ),
        actions: [
          if (_c.plan != null)
            IconButton(
              icon: const Icon(Icons.info_outline),
              tooltip: '音频信息',
              onPressed: _showAudioInfo,
            ),
        ],
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_c.phase) {
      case ListeningPlayerPhase.idle:
      case ListeningPlayerPhase.preparing:
        return _preparing();
      case ListeningPlayerPhase.error:
        return _error();
      case ListeningPlayerPhase.ready:
        return _ready();
    }
  }

  Widget _preparing() {
    final total = _c.prepTotal;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: kPrimary),
            const SizedBox(height: 20),
            const Text('正在准备离线音频…',
                style: TextStyle(color: kText, fontSize: 16)),
            const SizedBox(height: 8),
            if (total > 0) ...[
              Text('已合成 ${_c.prepDone} / $total 段',
                  style: const TextStyle(color: Colors.white54)),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: total == 0 ? null : _c.prepDone / total,
                backgroundColor: kLocked,
                color: kPrimary,
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              '首次播放需逐句合成，之后走本地缓存；全程离线，断网可用。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _error() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: kError, size: 40),
            const SizedBox(height: 12),
            Text(_c.error ?? '音频准备失败',
                textAlign: TextAlign.center,
                style: const TextStyle(color: kText)),
            const SizedBox(height: 20),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kPrimary),
              onPressed: _retry,
              child: const Text('重试', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ready() {
    final plan = _c.plan!;
    return Stack(
      children: [
        Column(
          children: [
            _explainToggle(plan),
            _modeBanner(plan),
            _legend(),
            _chunkStrip(),
            Expanded(child: _sentenceList(plan)),
            if (!_c.live && (_c.loopA != null || _c.abActive)) _abStatus(),
            _progress(plan),
            _transport(plan),
            _tools(),
          ],
        ),
        // 不跳页、不打断播放：只在原页面盖一层氛围彩带，播完自动收。
        if (_celebrateSix)
          Positioned.fill(
            child: ConfettiBurst(
              onDone: () {
                if (mounted) setState(() => _celebrateSix = false);
              },
            ),
          ),
      ],
    );
  }

  /// 原版/讲解版 toggle（指令 S+ §一.1）：偏好落库；播放中切换只在句界生效。
  Widget _explainToggle(ListeningAudioPlan plan) {
    final enabled = _c.canExplain;
    final explained = _c.explainMode;
    final hint = _c.rebuilding
        ? '正在切换…'
        : (plan.totalMs <= 0
            ? ''
            : '约 ${(plan.totalMs / 60000).ceil().clamp(1, 999)} 分钟'
                '${_c.explainedActive ? '（含讲解）' : ''}');
    return Container(
      key: const Key('listening_mode_toggle'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kUnlocked.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          _modeOption(
            key: const Key('listening_mode_original'),
            label: '原版',
            selected: !explained,
            enabled: enabled,
            onTap: () => _c.setExplainMode(false),
          ),
          _modeOption(
            key: const Key('listening_mode_explained'),
            label: '讲解版',
            selected: explained,
            enabled: enabled,
            onTap: () => _c.setExplainMode(true),
          ),
          const Spacer(),
          Text(
            enabled ? hint : '实时朗读不支持讲解版',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
          if (_c.inExplanation) ...[
            const SizedBox(width: 8),
            TextButton(
              key: const Key('listening_expl_skip'),
              onPressed: _c.skipExplanation,
              style: TextButton.styleFrom(
                foregroundColor: kPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
              ),
              child: const Text('跳过', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _modeOption({
    required Key key,
    required String label,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return PressableScale(
      key: key,
      scale: 0.94,
      enabled: enabled,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color:
              selected ? kPrimary.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected
                  ? kPrimary.withValues(alpha: 0.6)
                  : Colors.transparent),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: !enabled
                ? Colors.white24
                : (selected ? kPrimary : Colors.white54),
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _modeBanner(ListeningAudioPlan plan) {
    if (plan.live) {
      final available = _c.liveSystemReady;
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: available ? const Color(0x22FFB84D) : const Color(0x22FF6B6B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: (available ? kPrimary : kError).withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(available ? Icons.info_outline : Icons.error_outline,
                size: 16, color: available ? kPrimary : kError),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                available
                    ? '实时朗读模式：精确定位不可用；暂停后从本句开头继续。'
                    : '未检测到可用语音引擎，请到设置修复后再听。',
                style: TextStyle(
                    color: available ? kPrimary : kError, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }
    final synthesized = plan.synthesized;
    final reused = plan.reused;
    final detail = synthesized == 0
        ? '本地缓存命中 $reused 句'
        : '新合成 $synthesized 句 · 缓存 $reused 句';
    final expl = _c.explainedActive
        ? (plan.hasExplanations
            ? ' · 讲解 ${plan.items.where((e) => e.isExplanation).length} 段'
                '（新合成 ${plan.explanationSynthesized} / 缓存 ${plan.explanationReused}）'
            : ' · 本篇暂无可讲解词块')
        : '';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kUnlocked.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.offline_pin_outlined, size: 16, color: kUnlocked),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '句级离线音频已就绪（$detail）$expl',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
      child: Row(
        children: [
          _legendDot(kListeningMasteredText.withValues(alpha: 0.45), '已掌握'),
          const SizedBox(width: 12),
          _legendDot(kListeningLearningText.withValues(alpha: 0.35), '在学'),
          const SizedBox(width: 12),
          _legendDot(kListeningCandidateText.withValues(alpha: 0.35), '新块候选'),
          const Spacer(),
          const Text('轻点词块看释义',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }

  Widget _sentenceList(ListeningAudioPlan plan) {
    // 全量构建而非 ListView.builder：离屏句子若尚未构建，ensureVisible 拿不到
    // context，自动滚动就失效，讲解中的徽标会停在屏幕外。
    final list = SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(
        children: [
          for (var i = 0; i < plan.sentences.length; i++)
            _sentenceTile(plan, i),
        ],
      ),
    );
    // 讲解中轻点正文区 = 跳过本段，直接进下一句（§二.1）。
    // 包裹层常驻，只在讲解中挂 onTap：否则进入/退出讲解会重建滚动视图，列表跳回顶部。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _c.inExplanation ? _c.skipExplanation : null,
      child: list,
    );
  }

  Widget _sentenceTile(ListeningAudioPlan plan, int i) {
    final s = plan.sentences[i];
    final active = i == _c.currentIndex;
    final src = plan.article.sentences[i];
    final dueHere =
        widget.reviewRun && src.chunks.any((c) => _dueChunkIds.contains(c.id));
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, inner) => AnimatedContainer(
        key: _sentenceKeys[i],
        duration: Motion.of(context).dur(220),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
        decoration: BoxDecoration(
          color: dueHere
              ? Color.alphaBlend(
                  kListeningLearningText.withValues(
                      alpha: 0.05 + 0.14 * _pulse.value),
                  active ? kCard : kBg)
              : (active ? kCard : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            width: dueHere ? 1.6 : 1.0,
            color: dueHere
                ? kListeningLearningText.withValues(
                    alpha: 0.30 + 0.55 * _pulse.value)
                : (active
                    ? kPrimary.withValues(alpha: 0.45)
                    : Colors.transparent),
          ),
        ),
        child: inner,
      ),
      child: _sentenceBody(plan, i, s, active, dueHere),
    );
  }

  /// 单句正文：三色高亮 +（复习播单下）到期块脉动底色 + 译文开关 + 轻跟读。
  Widget _sentenceBody(
      ListeningAudioPlan plan, int i, dynamic s, bool active, bool dueHere) {
    final src = plan.article.sentences[i];
    final expl = _c.activeExplanation;
    final explaining = expl != null && expl.sentenceIndex == i;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 40,
          child: Column(
            children: [
              Text(
                '${i + 1}'.padLeft(2, '0'),
                style: TextStyle(
                  color: active ? kPrimary : Colors.white24,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${plan.precise ? '' : '≈'}${(s.durationMs / 1000).toStringAsFixed(1)}s',
                style: const TextStyle(color: Colors.white24, fontSize: 9),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SentenceRichText(
                sentence: s.text,
                chunks: src.chunks,
                states: _states,
                active: active,
                dueIds: dueHere ? _dueChunkIds : const {},
                emphasizedIds: explaining ? expl.chunkIds.toSet() : const {},
                onChunkTap: (chunk) => _showChunk(chunk, i),
              ),
              if (explaining) ...[
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _c.skipExplanation,
                  child: Row(
                    children: [
                      Container(
                        key: const Key('listening_explaining_badge'),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: kPrimary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: kPrimary.withValues(alpha: 0.55)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.graphic_eq, size: 12, color: kPrimary),
                            SizedBox(width: 4),
                            Text('讲解中',
                                style:
                                    TextStyle(color: kPrimary, fontSize: 11)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          expl.chunkIds
                              .map((id) => _articleChunkText[id] ?? id)
                              .join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ),
                      const Text('轻点跳过',
                          style:
                              TextStyle(color: Colors.white24, fontSize: 10)),
                    ],
                  ),
                ),
              ],
              if (_showTranslation && src.meaningCN.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  src.meaningCN,
                  style: TextStyle(
                    color: active ? Colors.white54 : Colors.white24,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: '跟读这一句',
          key: Key('listening_shadow_$i'),
          color: active ? kPrimary : Colors.white24,
          icon: const Icon(Icons.mic_none),
          onPressed: () => _openShadowRead(i),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          tooltip: '重播本句',
          color: active ? kPrimary : Colors.white24,
          icon: const Icon(Icons.replay),
          onPressed: () => _c.replaySentence(i),
        ),
      ],
    );
  }

  Widget _abStatus() {
    final a = _c.loopA;
    final b = _c.loopB;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kPrimary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.repeat, size: 16, color: kPrimary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              a == null
                  ? 'A-B 循环'
                  : 'A ${_fmtMs(a)} · B ${b == null ? '未设' : _fmtMs(b)}'
                      '${_c.abActive ? ' · 循环中' : ' · 播放到点后设 B'}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _c.clearLoop,
            child: const Text('清除', style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  Widget _progress(ListeningAudioPlan plan) {
    if (plan.live) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Column(
          children: [
            LinearProgressIndicator(
              value: plan.sentences.isEmpty
                  ? 0
                  : (_c.currentIndex + 1) / plan.sentences.length,
              backgroundColor: kLocked,
              color: kPrimary,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('第 ${_c.currentIndex + 1} / ${plan.sentences.length} 句',
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11)),
                const Text('进度为估算',
                    style: TextStyle(color: Colors.white24, fontSize: 11)),
              ],
            ),
          ],
        ),
      );
    }
    return ValueListenableBuilder<int>(
      valueListenable: _c.globalPosition,
      builder: (context, g, _) {
        final max = plan.totalMs <= 0 ? 1.0 : plan.totalMs.toDouble();
        final value = (_dragMs ?? g.toDouble()).clamp(0.0, max);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: value,
                  max: max,
                  activeColor: kPrimary,
                  inactiveColor: kLocked,
                  onChanged: (v) => setState(() => _dragMs = v),
                  onChangeEnd: (v) async {
                    setState(() => _dragMs = null);
                    await _c.seekToPositionMs(v.round());
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmtMs(g.round()),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                    Text(_fmtMs(plan.totalMs),
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _transport(ListeningAudioPlan plan) {
    final atEnd = _c.currentIndex >= plan.sentences.length - 1;
    final atStart = _c.currentIndex <= 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // M1（#38 附带项）：其余播控图标只补按下态，不做变形。
          PressableScale(
            scale: 0.96,
            child: IconButton(
              iconSize: 28,
              tooltip: '上一句',
              color: atStart ? Colors.white24 : Colors.white70,
              onPressed: atStart ? null : _c.previous,
              icon: const Icon(Icons.skip_previous),
            ),
          ),
          SizedBox(
            width: 64,
            height: 64,
            child: PressableScale(
              scale: 0.92,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  backgroundColor: _c.canPlay ? kPrimary : kLocked,
                  padding: EdgeInsets.zero,
                ),
                onPressed: _c.canPlay ? _c.togglePlay : null,
                child: PlayPauseMorph(
                  playing: _c.playing,
                  size: 34,
                  color: _c.canPlay ? Colors.black : Colors.white38,
                ),
              ),
            ),
          ),
          PressableScale(
            scale: 0.96,
            child: IconButton(
              iconSize: 28,
              tooltip: '下一句',
              color: atEnd ? Colors.white24 : Colors.white70,
              onPressed: atEnd ? null : _c.next,
              icon: const Icon(Icons.skip_next),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('第 ${_c.currentIndex + 1} / ${plan.sentences.length} 句',
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
              if (_c.completed)
                const Text('已完听',
                    style: TextStyle(color: kUnlocked, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tools() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        spacing: 8,
        runSpacing: 4,
        children: [
          _toolButton(
            icon: Icons.speed,
            label: ListeningPlayerController.kSpeedLabels[_c.speedIndex],
            enabled: !_c.live,
            onTap: _pickSpeed,
          ),
          _toolButton(
            icon: Icons.repeat,
            label: _c.abActive ? 'AB 循环中' : 'A-B',
            active: _c.abActive,
            enabled: !_c.live,
            onTap: _pickAb,
          ),
          _toolButton(
            icon: Icons.timer_outlined,
            label: _sleepLabel(),
            active: _c.sleepOption != SleepTimerOption.off,
            onTap: _pickSleep,
          ),
          _toolButton(
            icon: Icons.translate,
            label: '中',
            active: _showTranslation,
            onTap: _toggleTranslation,
          ),
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    bool enabled = true,
  }) {
    return TextButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon,
          size: 16,
          color:
              enabled ? (active ? kPrimary : Colors.white54) : Colors.white24),
      label: Text(
        label,
        style: TextStyle(
          color:
              enabled ? (active ? kPrimary : Colors.white70) : Colors.white24,
          fontSize: 12,
        ),
      ),
      style: TextButton.styleFrom(
        backgroundColor: active ? kPrimary.withValues(alpha: 0.12) : kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }

  String _sleepLabel() {
    return switch (_c.sleepOption) {
      SleepTimerOption.off => '定时',
      SleepTimerOption.m5 => '定时 5 分',
      SleepTimerOption.m15 => '定时 15 分',
      SleepTimerOption.m30 => '定时 30 分',
      SleepTimerOption.endOfArticle => '本篇结束',
    };
  }

  Future<void> _pickSpeed() async {
    final picked = await showAppSheet<int>(
      context: context,
      backgroundColor: kCard,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('播放速度', style: TextStyle(color: kText, fontSize: 16)),
            ),
            for (var i = 0; i < ListeningPlayerController.kSpeeds.length; i++)
              ListTile(
                title: Text(ListeningPlayerController.kSpeedLabels[i],
                    style: TextStyle(
                        color: i == _c.speedIndex ? kPrimary : kText)),
                trailing: i == _c.speedIndex
                    ? const Icon(Icons.check, color: kPrimary, size: 18)
                    : null,
                onTap: () => Navigator.pop(ctx, i),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) await _c.setSpeedIndex(picked);
  }

  Future<void> _pickAb() async {
    if (_c.live) return;
    await showAppSheet<void>(
      context: context,
      backgroundColor: kCard,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('A-B 循环',
                  style: TextStyle(color: kText, fontSize: 16)),
              const SizedBox(height: 6),
              const Text(
                '播放到起点按「设 A」，到终点按「设 B」；跨句边界同样生效。',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        _c.markLoopA();
                        Navigator.pop(ctx);
                      },
                      child: const Text('设 A（当前）'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        _c.markLoopB();
                        Navigator.pop(ctx);
                      },
                      child: const Text('设 B（当前）'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_c.loopA == null ? 'A 未设' : 'A ${_fmtMs(_c.loopA!)}'}'
                      ' · ${_c.loopB == null ? 'B 未设' : 'B ${_fmtMs(_c.loopB!)}'}',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      _c.clearLoop();
                      Navigator.pop(ctx);
                    },
                    child: const Text('清除', style: TextStyle(color: kError)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickSleep() async {
    final picked = await showAppSheet<SleepTimerOption>(
      context: context,
      backgroundColor: kCard,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('定时关闭', style: TextStyle(color: kText, fontSize: 16)),
            ),
            for (final option in SleepTimerOption.values)
              ListTile(
                title: Text(_sleepOptionLabel(option),
                    style: TextStyle(
                        color: option == _c.sleepOption ? kPrimary : kText)),
                trailing: option == _c.sleepOption
                    ? const Icon(Icons.check, color: kPrimary, size: 18)
                    : null,
                onTap: () => Navigator.pop(ctx, option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) _c.setSleep(picked);
  }

  String _sleepOptionLabel(SleepTimerOption option) => switch (option) {
        SleepTimerOption.off => '关闭定时',
        SleepTimerOption.m5 => '5 分钟后暂停',
        SleepTimerOption.m15 => '15 分钟后暂停',
        SleepTimerOption.m30 => '30 分钟后暂停',
        SleepTimerOption.endOfArticle => '本篇播完暂停',
      };

  ListeningLearnService _learnService() {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    return ListeningLearnService(
      store: progress.chunkStore,
      listening: progress.listening,
      content: content,
      articleId: widget.article.id,
      logEvent: progress.logEvent,
      articleCollectLimit: widget.article.collectLimit,
    );
  }

  /// 级别徽标（与首页同一套色：级别=篇目属性，不与三色块状态混义）。
  Widget _levelBadge(ListeningLevel level) {
    final tone = listeningLevelColor(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tone.withValues(alpha: 0.6)),
      ),
      child: Text(level.key,
          style: TextStyle(
              color: tone, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

  /// 译文开关（§二.5）：偏好落库，默认开。
  Future<void> _toggleTranslation() async {
    final next = !_showTranslation;
    setState(() => _showTranslation = next);
    await Provider.of<ProgressService>(context, listen: false)
        .listening
        .setShowTranslation(next);
  }

  /// 本文词块条（§二.2）：可展开横滑 chips，按三色阶梯着色，
  /// 点击复用既有浮层——不建第二套状态口径。
  Widget _chunkStrip() {
    final chunks = widget.article.chunks;
    if (chunks.isEmpty) return const SizedBox.shrink();
    final firstIndex = <String, int>{};
    for (var i = 0; i < widget.article.sentences.length; i++) {
      for (final c in widget.article.sentences[i].chunks) {
        firstIndex.putIfAbsent(c.id, () => i);
      }
    }
    return Column(
      children: [
        Material(
          color: kCard,
          child: InkWell(
            key: const Key('listening_chunk_strip'),
            onTap: () => setState(() => _chunksOpen = !_chunksOpen),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.category_outlined,
                      size: 16, color: kPrimary),
                  const SizedBox(width: 8),
                  Text('本文 ${chunks.length} 块',
                      style: const TextStyle(color: kText, fontSize: 13)),
                  const Spacer(),
                  Text(_chunksOpen ? '收起' : '展开',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12)),
                  Icon(_chunksOpen ? Icons.expand_less : Icons.expand_more,
                      size: 18, color: Colors.white38),
                ],
              ),
            ),
          ),
        ),
        if (_chunksOpen)
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: chunks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final c = chunks[i];
                final tone = listeningChunkTone(c, _states);
                final fg = switch (tone) {
                  ListeningChunkTone.candidate => kListeningCandidateText,
                  ListeningChunkTone.learning => kListeningLearningText,
                  ListeningChunkTone.mastered => kListeningMasteredText,
                  ListeningChunkTone.none => Colors.white38,
                };
                return ActionChip(
                  key: Key('listening_strip_${c.id}'),
                  label:
                      Text(c.text, style: TextStyle(color: fg, fontSize: 12)),
                  onPressed: () => _showChunk(c, firstIndex[c.id] ?? 0),
                  backgroundColor: kCard,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(color: fg.withValues(alpha: 0.55)),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  /// 句级轻跟读（§二.4）：浮层内录音→判定→三态，关闭即删临时文件。
  Future<void> _openShadowRead(int index) async {
    final wasPlaying = _c.playing || _c.livePlaying;
    await _c.pause();
    if (!mounted) return;
    final src = widget.article.sentences[index];
    await showAppSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (_) => _ShadowReadSheet(
        sentence: src.text,
        onAttempt: (passed, similarity) {
          // 浸泡层不产资产：只记 attempt 事件，不改块状态、不写会话轴。
          _c.progress.logEvent('listen_shadow_attempt', {
            'article': widget.article.id,
            'sentence': src.id,
            'passed': passed,
            'similarity': similarity,
          });
        },
      ),
    );
    if (wasPlaying && mounted && !_c.playing && !_c.livePlaying) {
      await _c.togglePlay();
    }
  }

  Future<void> _showChunk(ListeningChunk chunk, int sentenceIndex) async {
    final wasPlaying = _c.playing || _c.livePlaying;
    await _c.pause();
    await _c.seekToSentence(sentenceIndex);
    if (!mounted) return;

    final service = _learnService();
    final resolution = await service.resolve(chunk);
    if (!mounted) return;
    if (resolution.action == ListeningChunkAction.reviewNow ||
        resolution.action == ListeningChunkAction.mastered) {
      await service.markReunion();
    }
    if (!mounted) return;

    final result = await showAppSheet<_SheetResult>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (_) => _ChunkSheet(
        service: service,
        initial: resolution,
        onChanged: _loadStates,
        example: widget.article.sentences[sentenceIndex].text,
      ),
    );
    if (!mounted) return;

    if (result?.chunk != null) {
      switch (result!.command) {
        case _SheetCommand.openSix:
          await _openSix(result.chunk!);
        case _SheetCommand.openReview:
          await _openReview(result.chunk!);
      }
    }
    if (wasPlaying && mounted && !_c.playing && !_c.livePlaying) {
      await _c.togglePlay();
    }
  }

  Future<void> _openSix(Chunk c) async {
    final service = _learnService();
    await service.beginSix(c.id);
    if (!mounted) return;
    var completed = false;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (routeCtx) => Scaffold(
        appBar: AppBar(title: const Text('收听收词 · 六步')),
        body: PracticeLoop(
          level: service.sixLevel(c),
          chunks: [c],
          onDone: (_) {
            completed = true;
            Navigator.of(routeCtx).pop();
          },
        ),
      ),
    ));
    if (completed) await service.finishSix(c.id);
    if (!mounted) return;
    await _loadStates();
    if (!mounted) return;
    if (completed) setState(() => _celebrateSix = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(completed ? '六步完成 · 已回到文章，可继续听' : '进度已保存 · 可从浮层继续学习'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _openReview(Chunk c) async {
    final service = _learnService();
    final progress = Provider.of<ProgressService>(context, listen: false);
    final before = (await progress.chunkStore.get(c.id)).assetSnapshot;
    await service.beginReview(c.id);
    if (!mounted) return;
    var completed = false;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (routeCtx) => Scaffold(
        appBar: AppBar(title: const Text('重逢复习')),
        body: PracticeLoop(
          level: service.reviewLevel(c),
          chunks: [c],
          reviewMode: true,
          onDone: (_) {
            completed = true;
            Navigator.of(routeCtx).pop();
          },
        ),
      ),
    ));
    final after = (await progress.chunkStore.get(c.id)).assetSnapshot;
    final text = ListeningLearnService.reviewOutcomeText(before, after);
    await service.finishReview(c.id, completed: completed, outcome: text);
    if (!mounted) return;
    await _loadStates();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  void _showAudioInfo() {
    final plan = _c.plan;
    if (plan == null) return;
    showAppSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('音频信息（离线合成）',
                  style: TextStyle(color: kText, fontSize: 16)),
              const SizedBox(height: 8),
              Text('音源：${_sourceLabel(plan)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 4),
              Text(
                '播放模式：${_c.explainedActive ? '讲解版' : '原版'}'
                '${plan.hasExplanations ? ' · 讲解 ${plan.items.where((e) => e.isExplanation).length} 段'
                    '（新合成 ${plan.explanationSynthesized} / 缓存 ${plan.explanationReused}）' : ''}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text('缓存键音色：${plan.voiceKey}',
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontFamily: 'monospace')),
              const SizedBox(height: 4),
              Text(
                '总时长：${_fmtMs(plan.totalMs)} · '
                '${plan.precise ? '实测时长回填时间轴' : '估算时间轴（精确定位不可用）'}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: plan.items.isEmpty
                      ? plan.sentences.length
                      : plan.items.length,
                  itemBuilder: (_, i) {
                    final item = plan.items.isEmpty ? null : plan.items[i];
                    final s = item == null
                        ? plan.sentences[i]
                        : ListeningSentenceAudio(
                            id: item.id,
                            text: item.text,
                            path: item.path,
                            startMs: item.startMs,
                            endMs: item.endMs,
                          );
                    final expl = item?.isExplanation ?? false;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 26,
                            child: Text(
                                expl
                                    ? '讲'
                                    : '${(item?.sentenceIndex ?? i) + 1}',
                                style: TextStyle(
                                    color: expl ? kPrimary : Colors.white38,
                                    fontSize: 11)),
                          ),
                          Expanded(
                            child: Text(expl ? '讲解 · ${s.text}' : s.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: expl ? kPrimary : Colors.white54,
                                    fontSize: 11)),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${_fmtMs(s.startMs)}–${_fmtMs(s.endMs)}'
                            '（${(s.durationMs / 1000).toStringAsFixed(2)}s）',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11),
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
      ),
    );
  }

  String _sourceLabel(ListeningAudioPlan plan) => switch (plan.source) {
        ListeningAudioSource.hd => '高清发音包（VITS 离线）',
        ListeningAudioSource.system => '系统 TTS 离线合成',
        ListeningAudioSource.live => '系统 TTS 实时朗读（降级）',
      };

  String _fmtMs(int ms) {
    final total = (ms / 1000).round();
    final m = total ~/ 60;
    final s = total % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// 句内词块着色：已掌握金色、新块候选蓝色；点击只回调（不写学习数据）。
class _SentenceRichText extends StatefulWidget {
  final String sentence;
  final List<ListeningChunk> chunks;
  final Map<String, ChunkAssetState> states;
  final bool active;

  /// 复习播单里到期的块：加一层更重的琥珀底色（脉动由外层容器负责）。
  final Set<String> dueIds;

  /// 正在讲解的块：底色/字重再加强一层（讲解中徽标已在外层展示）。
  final Set<String> emphasizedIds;
  final void Function(ListeningChunk chunk) onChunkTap;

  const _SentenceRichText({
    required this.sentence,
    required this.chunks,
    required this.states,
    required this.active,
    this.dueIds = const {},
    this.emphasizedIds = const {},
    required this.onChunkTap,
  });

  @override
  State<_SentenceRichText> createState() => _SentenceRichTextState();
}

class _SentenceRichTextState extends State<_SentenceRichText> {
  final List<TapGestureRecognizer> _recognizers = [];
  List<InlineSpan>? _spans;

  @override
  void didUpdateWidget(covariant _SentenceRichText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sentence != widget.sentence ||
        oldWidget.states != widget.states ||
        oldWidget.chunks != widget.chunks ||
        oldWidget.emphasizedIds != widget.emphasizedIds) {
      _disposeRecognizers();
    }
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    _spans = null;
  }

  List<InlineSpan> _buildSpans() {
    final text = widget.sentence;
    final lower = text.toLowerCase();
    final matches = <_ChunkMatch>[];
    for (final c in widget.chunks) {
      final needle = c.text.toLowerCase();
      if (needle.isEmpty) continue;
      var at = lower.indexOf(needle);
      while (at >= 0) {
        matches.add(_ChunkMatch(at, at + needle.length, c));
        at = lower.indexOf(needle, at + needle.length);
      }
    }
    matches.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : b.end.compareTo(a.end);
    });
    final chosen = <_ChunkMatch>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start < cursor) continue;
      chosen.add(m);
      cursor = m.end;
    }
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in chosen) {
      if (m.start > at) {
        spans.add(TextSpan(text: text.substring(at, m.start)));
      }
      final tone = listeningChunkTone(m.chunk, widget.states);
      final Color? color = switch (tone) {
        ListeningChunkTone.candidate => kListeningCandidateText,
        ListeningChunkTone.learning => kListeningLearningText,
        ListeningChunkTone.mastered => kListeningMasteredText,
        ListeningChunkTone.none => null,
      };
      var background = switch (tone) {
        ListeningChunkTone.candidate => kListeningCandidateBg,
        ListeningChunkTone.learning => kListeningLearningBg,
        ListeningChunkTone.mastered => kListeningMasteredBg,
        ListeningChunkTone.none => null,
      };
      if (widget.dueIds.contains(m.chunk.id)) {
        background = kListeningLearningText.withValues(alpha: 0.34);
      }
      final emphasized = widget.emphasizedIds.contains(m.chunk.id);
      if (emphasized) {
        background = kPrimary.withValues(alpha: 0.30);
      }
      final highlighted = tone != ListeningChunkTone.none;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onChunkTap(m.chunk);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: text.substring(m.start, m.end),
        recognizer: recognizer,
        style: TextStyle(
          color: emphasized ? Colors.white : color,
          backgroundColor: background,
          fontWeight: emphasized
              ? FontWeight.w700
              : (highlighted ? FontWeight.w600 : null),
          decoration:
              (highlighted || emphasized) ? TextDecoration.underline : null,
          decorationStyle: (tone == ListeningChunkTone.mastered || emphasized)
              ? TextDecorationStyle.solid
              : TextDecorationStyle.dotted,
          decorationColor: emphasized
              ? kPrimary
              : (highlighted ? color?.withValues(alpha: 0.45) : null),
        ),
      ));
      at = m.end;
    }
    if (at < text.length) {
      spans.add(TextSpan(text: text.substring(at)));
    }
    return spans;
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _spans ??= _buildSpans();
    return Text.rich(
      TextSpan(children: _spans),
      style: TextStyle(
        color: widget.active ? kText : Colors.white70,
        fontSize: 18,
        height: 1.55,
      ),
    );
  }
}

class _ChunkMatch {
  final int start;
  final int end;
  final ListeningChunk chunk;
  const _ChunkMatch(this.start, this.end, this.chunk);
}

enum _SheetCommand { openSix, openReview }

class _SheetResult {
  final _SheetCommand command;
  final Chunk? chunk;
  const _SheetResult(this.command, this.chunk);
}

/// 词块浮层：按账本/资产状态分派主按钮；收词只落账，不强制进六步。
/// 播放暂停由页面负责，本浮层只做状态与跳转意图，关闭后由页面决定续播/导航。
class _ChunkSheet extends StatefulWidget {
  final ListeningLearnService service;
  final ListeningChunkResolution initial;
  final Future<void> Function() onChanged;

  /// 从文章某句打开浮层时优先展示所在句（指令 S §二.3）。
  final String example;

  const _ChunkSheet({
    required this.service,
    required this.initial,
    required this.onChanged,
    this.example = '',
  });

  @override
  State<_ChunkSheet> createState() => _ChunkSheetState();
}

class _ChunkSheetState extends State<_ChunkSheet> {
  late ListeningChunkResolution _r = widget.initial;
  bool _busy = false;
  bool _justJoined = false;

  Future<void> _collect() async {
    setState(() => _busy = true);
    final outcome = await widget.service.collect(_r.chunk);
    await widget.onChanged();
    final next = await widget.service.resolve(_r.chunk);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _r = next;
      _justJoined = outcome == ListeningCollectOutcome.collected ||
          outcome == ListeningCollectOutcome.already;
    });
    _snack(switch (outcome) {
      ListeningCollectOutcome.collected => '已加入学习 · 明日进入复习',
      ListeningCollectOutcome.already => '这块已在词块库',
      ListeningCollectOutcome.capReached => '本篇收词已达上限，先把已收的块学完',
      ListeningCollectOutcome.invalid => '未找到词块，未落账',
    });
  }

  Future<void> _wish() async {
    setState(() => _busy = true);
    final added = await widget.service.wish(_r.chunk);
    final next = await widget.service.resolve(_r.chunk);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _r = next;
    });
    _snack(added ? '已记录 · 会反哺内容排产' : '这块的意愿已记录过');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _primary() {
    if (_busy || _justJoined || !_r.primaryEnabled) return;
    switch (_r.action) {
      case ListeningChunkAction.candidate:
        _wish();
      case ListeningChunkAction.join:
        _collect();
      case ListeningChunkAction.continueLearning:
        Navigator.of(context)
            .pop(_SheetResult(_SheetCommand.openSix, _r.contentChunk));
      case ListeningChunkAction.reviewNow:
        Navigator.of(context)
            .pop(_SheetResult(_SheetCommand.openReview, _r.contentChunk));
      case ListeningChunkAction.mastered:
      case ListeningChunkAction.unavailable:
        break;
    }
  }

  Color get _statusColor {
    switch (_r.action) {
      case ListeningChunkAction.candidate:
        return const Color(0xFF90CAF9);
      case ListeningChunkAction.mastered:
        return kPrimary;
      case ListeningChunkAction.reviewNow:
        return kUnlocked;
      case ListeningChunkAction.join:
      case ListeningChunkAction.continueLearning:
      case ListeningChunkAction.unavailable:
        return Colors.white54;
    }
  }

  String? get _note {
    if (_justJoined) {
      return '已加入词块库 · 可在词块库或再次点开本块继续六步。';
    }
    switch (_r.action) {
      case ListeningChunkAction.candidate:
        return '只记录想学意愿（文章 + 块文本），不建词块、不计学习进度。';
      case ListeningChunkAction.unavailable:
        return '内容包里找不到这个词块，暂不支持操作。';
      case ListeningChunkAction.join:
        if (_r.capReached) {
          return '本篇已收 ${_r.collectedCount}/${_r.collectCap} 块，达到上限；'
              '先把已收的块学完，明天再收。';
        }
        return '加入后进入词块库，并排入明日复习；不强制立刻学六步。';
      case ListeningChunkAction.continueLearning:
        return _r.sixStarted ? '有六步断点，将从上次的步骤继续。' : '已收词，继续六步可完成这块。';
      case ListeningChunkAction.reviewNow:
        return '复习走后四步；通过后按 1/3/7/14 天档升一级。';
      case ListeningChunkAction.mastered:
        return '已完成全部复习间隔，只试听，不再排期。';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tts = Provider.of<TtsService>(context, listen: false);
    final color = _statusColor;
    final status = _justJoined ? '已加入 · 待学习' : _r.statusLabel;
    final primary = _justJoined ? '已加入 · 待学习' : _r.primaryLabel;
    final showCap = !_r.isCandidate &&
        _r.action != ListeningChunkAction.unavailable &&
        _r.action != ListeningChunkAction.mastered;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 18, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_r.chunk.text,
                      style: const TextStyle(
                          color: kText,
                          fontSize: 22,
                          fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '试听',
                  icon: const Icon(Icons.volume_up, color: kPrimary, size: 22),
                  onPressed: () => speakOrHint(context, tts, _r.chunk.text),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(_r.chunk.meaningCN,
                style: const TextStyle(color: Colors.white70, fontSize: 15)),
            if (widget.example.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '文中原句：${widget.example}',
                key: const Key('chunkSheetExample'),
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Text(status, style: TextStyle(color: color, fontSize: 11)),
            ),
            if (_note != null) ...[
              const SizedBox(height: 12),
              Text(_note!,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12, height: 1.4)),
            ],
            if (showCap) ...[
              const SizedBox(height: 6),
              Text('本篇已收 ${_r.collectedCount}/${_r.collectCap} 块',
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
            if (primary != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kPrimary,
                    disabledBackgroundColor: Colors.white12,
                  ),
                  onPressed: (_busy || _justJoined || !_r.primaryEnabled)
                      ? null
                      : _primary,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white70))
                      : Text(primary,
                          style: TextStyle(
                              color: _r.primaryEnabled && !_justJoined
                                  ? Colors.black87
                                  : Colors.white54)),
                ),
              ),
            ],
            if (_r.action == ListeningChunkAction.mastered) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kPrimary.withValues(alpha: 0.35)),
                ),
                child: const Text('已掌握 · 完成全部复习间隔',
                    style: TextStyle(color: kPrimary, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// 句级轻跟读浮层（指令 S §二.4）。
///
/// 复用六步④的判定与阈值（judgeSpeech + guardAsr + asrVerdictFor，闭合跟读文案），
/// 但**不写词块资产、不写会话轴**：浸泡层只记一次 attempt 事件。
/// 录音只落在系统临时目录，浮层关闭即删，不做任何留存（回放只针对当前这一次）。
class _ShadowReadSheet extends StatefulWidget {
  final String sentence;
  final void Function(bool passed, int similarity) onAttempt;

  const _ShadowReadSheet({required this.sentence, required this.onAttempt});

  @override
  State<_ShadowReadSheet> createState() => _ShadowReadSheetState();
}

class _ShadowReadSheetState extends State<_ShadowReadSheet> {
  final RecordingService _rec = RecordingService();
  final SpeechService _speech = SpeechService();

  String? _path;
  bool _recording = false;
  bool _thinking = false;
  ShadowVerdict? _verdict;

  @override
  void dispose() {
    _discardWav();
    super.dispose();
  }

  void _discardWav() {
    final path = _path;
    _path = null;
    if (path == null) return;
    unawaited(() async {
      try {
        await File(path).delete();
      } catch (_) {
        // 删不掉也交给系统临时目录回收；口径是「应用不主动留存」
      }
    }());
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  Future<void> _start() async {
    final perm = await ensureMicWithPreprompt(context, _rec);
    if (!mounted) return;
    if (perm != MicPerm.granted) {
      _snack(perm == MicPerm.permanentlyDenied
          ? '麦克风被系统拒绝，去设置里开一下'
          : '没拿到麦克风权限，先不录');
      return;
    }
    final path = await _rec.start();
    if (!mounted) return;
    if (path == null) {
      _snack('录音没起来，再试一次');
      return;
    }
    setState(() {
      _path = path;
      _recording = true;
      _verdict = null;
    });
  }

  Future<void> _stopAndJudge() async {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _thinking = true;
    });
    final stopped = await _rec.stop();
    if (stopped != null) _path = stopped;
    final path = _path;
    if (path == null || !await _speech.initVosk()) {
      if (!mounted) return;
      setState(() => _thinking = false);
      _snack('识别引擎没就绪，本次不判定');
      return;
    }
    final r = await _speech.recognizeOpen(path);
    final dur = await _speech.durationSec(path);
    if (!mounted) return;
    final v = judgeShadowRead(
      target: widget.sentence,
      recognized: r.text,
      confidence: r.confidence,
      durationSec: dur,
      wordConfidences: r.wordConfidences,
    );
    setState(() {
      _thinking = false;
      _verdict = v;
    });
    widget.onAttempt(v.passed, (v.similarity * 100).round());
  }

  Future<void> _replay() async {
    final path = _path;
    if (path == null) return;
    await _rec.play(path);
  }

  @override
  Widget build(BuildContext context) {
    final v = _verdict;
    final verdict = v?.verdict;
    final color = switch (verdict?.kind) {
      AsrVerdictKind.pass => kUnlocked,
      AsrVerdictKind.retry => kPrimary,
      _ => kError,
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 18, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('跟读这一句',
                style: TextStyle(
                    color: kText, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Text(widget.sentence,
                key: const Key('shadowTarget'),
                style:
                    const TextStyle(color: kText, fontSize: 18, height: 1.35)),
            const SizedBox(height: 12),
            if (v != null) ...[
              Text('你说：${v.recognized}',
                  key: const Key('shadowTranscript'),
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 6),
              Text('相似度 ${(v.similarity * 100).round()}%',
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
            if (verdict != null) ...[
              const SizedBox(height: 8),
              Text(verdict.text,
                  key: const Key('shadowVerdict'),
                  style: TextStyle(
                      color: color, fontSize: 15, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 6),
            const Text('只跟读，不计进度：这块的状态仍由六步和复习决定',
                style: TextStyle(color: Colors.white30, fontSize: 12)),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('shadowRecordButton'),
                    onPressed: _thinking
                        ? null
                        : (_recording ? _stopAndJudge : _start),
                    icon: Icon(_recording ? Icons.stop : Icons.mic),
                    label: Text(
                        _thinking ? '识别中…' : (_recording ? '说完，判定' : '按住说完这句')),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  key: const Key('shadowReplay'),
                  tooltip: '回放刚才那次',
                  onPressed: _path == null ? null : _replay,
                  icon: const Icon(Icons.play_circle_outline,
                      color: kPrimary, size: 28),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../models/listening_article.dart';
import '../services/chunk_asset.dart';
import '../services/listening_audio.dart';
import '../services/listening_learn.dart';
import '../services/listening_palette.dart';
import '../services/listening_player.dart';
import '../services/loaders.dart';
import '../services/notification_service.dart';
import '../steps/practice_loop.dart';
import '../ui/feedback.dart';
import '../ui/theme.dart';


/// 浸泡层播放页（应用内）。
///
/// 三色阶梯：蓝=候选、琥珀=在学（learning/consolidating/consolidated/
/// longTerm/relearning）、金=已掌握；点击浮层写学习数据。
class ListeningPlayerPage extends StatefulWidget {
  final ListeningArticle article;
  const ListeningPlayerPage({super.key, required this.article});

  @override
  State<ListeningPlayerPage> createState() => _ListeningPlayerPageState();
}

class _ListeningPlayerPageState extends State<ListeningPlayerPage> {
  late ListeningPlayerController _c;
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _sentenceKeys = [];
  Map<String, ChunkAssetState> _states = {};
  int _lastIndex = -1;
  bool _notifiedComplete = false;
  double? _dragMs;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.article.sentences.length; i++) {
      _sentenceKeys.add(GlobalKey());
    }
    _createController();
    _loadStates();
    unawaited(NotificationService.instance.requestPermission());
  }

  void _createController() {
    final progress = Provider.of<ProgressService>(context, listen: false);
    final tts = Provider.of<TtsService>(context, listen: false);
    _c = ListeningPlayerController(
      progress: progress,
      tts: tts,
      article: widget.article,
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
    }
    setState(() {});
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
            Text(
              '${widget.article.sceneLabel} · ${widget.article.sentences.length} 句',
              style: const TextStyle(fontSize: 11, color: Colors.white38),
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
              Text('已合成 ${_c.prepDone} / $total 句',
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
    return Column(
      children: [
        _modeBanner(plan),
        _legend(),
        Expanded(child: _sentenceList(plan)),
        if (!_c.live && (_c.loopA != null || _c.abActive)) _abStatus(),
        _progress(plan),
        _transport(plan),
        _tools(),
      ],
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
              '句级离线音频已就绪（$detail）',
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
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      itemCount: plan.sentences.length,
      itemBuilder: (context, i) {
        final s = plan.sentences[i];
        final active = i == _c.currentIndex;
        return AnimatedContainer(
          key: _sentenceKeys[i],
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
          decoration: BoxDecoration(
            color: active ? kCard : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? kPrimary.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: Row(
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
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 9),
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
                      chunks: plan.article.sentences[i].chunks,
                      states: _states,
                      active: active,
                      onChunkTap: (chunk) => _showChunk(chunk, i),
                    ),
                    if (plan.article.sentences[i].meaningCN.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        plan.article.sentences[i].meaningCN,
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
                tooltip: '重播本句',
                color: active ? kPrimary : Colors.white24,
                icon: const Icon(Icons.replay),
                onPressed: () => _c.replaySentence(i),
              ),
            ],
          ),
        );
      },
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
              style:
                  const TextStyle(color: Colors.white70, fontSize: 12),
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
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11)),
                const Text('进度为估算',
                    style:
                        TextStyle(color: Colors.white24, fontSize: 11)),
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
          IconButton(
            iconSize: 28,
            tooltip: '上一句',
            color: atStart ? Colors.white24 : Colors.white70,
            onPressed: atStart ? null : _c.previous,
            icon: const Icon(Icons.skip_previous),
          ),
          SizedBox(
            width: 64,
            height: 64,
            child: FilledButton(
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                backgroundColor: _c.canPlay ? kPrimary : kLocked,
                padding: EdgeInsets.zero,
              ),
              onPressed: _c.canPlay ? _c.togglePlay : null,
              child: Icon(
                _c.playing ? Icons.pause : Icons.play_arrow,
                size: 34,
                color: _c.canPlay ? Colors.black : Colors.white38,
              ),
            ),
          ),
          IconButton(
            iconSize: 28,
            tooltip: '下一句',
            color: atEnd ? Colors.white24 : Colors.white70,
            onPressed: atEnd ? null : _c.next,
            icon: const Icon(Icons.skip_next),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('第 ${_c.currentIndex + 1} / ${plan.sentences.length} 句',
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 11)),
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
      icon: Icon(icon, size: 16, color: enabled ? (active ? kPrimary : Colors.white54) : Colors.white24),
      label: Text(
        label,
        style: TextStyle(
          color: enabled ? (active ? kPrimary : Colors.white70) : Colors.white24,
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
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kCard,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('播放速度',
                  style: TextStyle(color: kText, fontSize: 16)),
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
    await showModalBottomSheet<void>(
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
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
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
    final picked = await showModalBottomSheet<SleepTimerOption>(
      context: context,
      backgroundColor: kCard,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('定时关闭',
                  style: TextStyle(color: kText, fontSize: 16)),
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

    final result = await showModalBottomSheet<_SheetResult>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (_) => _ChunkSheet(
        service: service,
        initial: resolution,
        onChanged: _loadStates,
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
          sentenceChallenge: false,
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
    showModalBottomSheet<void>(
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
              Text('缓存键音色：${plan.voiceKey}',
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontFamily: 'monospace')),
              const SizedBox(height: 4),
              Text(
                '总时长：${_fmtMs(plan.totalMs)} · '
                '${plan.precise ? '实测时长回填时间轴' : '估算时间轴（精确定位不可用）'}',
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: plan.sentences.length,
                  itemBuilder: (_, i) {
                    final s = plan.sentences[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 26,
                            child: Text('${i + 1}',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 11)),
                          ),
                          Expanded(
                            child: Text(s.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11)),
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
  final void Function(ListeningChunk chunk) onChunkTap;

  const _SentenceRichText({
    required this.sentence,
    required this.chunks,
    required this.states,
    required this.active,
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
        oldWidget.chunks != widget.chunks) {
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
      final Color? background = switch (tone) {
        ListeningChunkTone.candidate => kListeningCandidateBg,
        ListeningChunkTone.learning => kListeningLearningBg,
        ListeningChunkTone.mastered => kListeningMasteredBg,
        ListeningChunkTone.none => null,
      };
      final highlighted = tone != ListeningChunkTone.none;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onChunkTap(m.chunk);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: text.substring(m.start, m.end),
        recognizer: recognizer,
        style: TextStyle(
          color: color,
          backgroundColor: background,
          fontWeight: highlighted ? FontWeight.w600 : null,
          decoration: highlighted ? TextDecoration.underline : null,
          decorationStyle: tone == ListeningChunkTone.mastered
              ? TextDecorationStyle.solid
              : TextDecorationStyle.dotted,
          decorationColor:
              highlighted ? color?.withValues(alpha: 0.45) : null,
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

  const _ChunkSheet({
    required this.service,
    required this.initial,
    required this.onChanged,
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
        Navigator.of(context).pop(
            _SheetResult(_SheetCommand.openSix, _r.contentChunk));
      case ListeningChunkAction.reviewNow:
        Navigator.of(context).pop(
            _SheetResult(_SheetCommand.openReview, _r.contentChunk));
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
        return _r.sixStarted
            ? '有六步断点，将从上次的步骤继续。'
            : '已收词，继续六步可完成这块。';
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
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
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

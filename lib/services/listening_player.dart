import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/content_pack.dart';
import '../models/listening_article.dart';
import 'chunk_asset.dart';
import 'listening_audio.dart';
import 'listening_explanation.dart';
import 'listening_playback.dart';
import 'listening_store.dart';
import 'loaders.dart';

enum ListeningPlayerPhase { idle, preparing, ready, error }

enum SleepTimerOption { off, m5, m15, m30, endOfArticle }

/// 浸泡层播放器（应用内）。
///
/// 红线：只记浸泡时长/完听/行为事件，不写学习会话轴、不改词块资产。
/// 音频精确模式用句级 WAV 队列；合成不可用时退化为系统 TTS 顺序朗读，
/// 此时句内定位不可用，UI 必须明示。
class ListeningPlayerController extends ChangeNotifier {
  ListeningPlayerController({
    required this.progress,
    required this.tts,
    required this.article,
    this.content,
    this.loadStates,
    ListeningAudioPipeline? pipeline,
    AudioPlayer? player,
    ListeningPlayback? playback,
  })  : pipeline = pipeline ?? ListeningAudioPipeline(),
        _player = player ?? AudioPlayer(),
        playback = playback ?? ListeningPlayback.instance,
        _preferExplain = progress.listening.explainMode {
    this.playback.onAction = _handlePlaybackAction;
    // 打开文章先定档：用户本级记忆 → 内容声明的 baseRate → 级别默认（指令 S §一.5）。
    speedIndex = indexForRate(defaultRateFor(article, progress.listening));
  }

  /// 本级默认语速的取值顺序；变速只走播放速率，不进音频缓存键。
  static double defaultRateFor(ListeningArticle a, ListeningStore store) =>
      store.speedOverrideFor(a.level.key) ?? a.baseRate ?? a.level.baseRate;

  /// 把任意速率吸附到既有速率梯的最近一档。
  static int indexForRate(double rate) {
    var best = 1, bestDiff = double.infinity;
    for (var i = 0; i < kSpeeds.length; i++) {
      final d = (kSpeeds[i] - rate).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = i;
      }
    }
    return best;
  }

  /// 当前文章生效的默认语速（未手动变速时的落点）。
  double get baseRate => defaultRateFor(article, progress.listening);

  final ProgressService progress;
  final TtsService tts;
  final ListeningArticle article;

  /// 讲解版需要库内释义；缺内容包时所有块按「缺释义」优雅跳过。
  final ContentPack? content;

  /// 切模式时现读资产状态（收词后返回文章能立刻反映新状态）。
  final Future<Map<String, ChunkAssetState>> Function()? loadStates;

  final ListeningAudioPipeline pipeline;
  final ListeningPlayback playback;
  final AudioPlayer _player;

  /// 全局播放位置（跨句毫秒）：页面用 ValueListenableBuilder 订阅，避免整页高频重建。
  final ValueNotifier<int> globalPosition = ValueNotifier<int>(0);

  ListeningPlayerPhase phase = ListeningPlayerPhase.idle;
  ListeningAudioPlan? plan;
  String? error;
  int currentIndex = 0;

  /// 播放条目索引（含讲解段）；currentIndex 始终是正文句索引。
  int currentItemIndex = 0;
  bool playing = false;
  bool completed = false;
  int speedIndex = 1; // 0=0.75x 1=1.0x 2=1.25x
  int prepDone = 0;
  int prepTotal = 0;
  int? loopA;
  int? loopB;
  bool abActive = false;
  SleepTimerOption sleepOption = SleepTimerOption.off;
  DateTime? sleepDeadline;

  /// 用户选择的模式（toggle 落点）；[_planExplained] 是当前计划实际形态。
  bool explainMode = false;
  bool _preferExplain = false;
  bool _planExplained = false;

  /// 播放中切模式时等到下一句边界再换队列，保证不打断当前句。
  bool? _pendingExplainMode;
  bool rebuilding = false;
  ListeningPlaybackItem? _currentExpl;
  bool _explInterrupted = false;

  /// 页面注册的一次性提示（定时结束/AB 参数不合法等）。
  void Function(String message)? onNotice;

  static const List<double> kSpeeds = [0.75, 1.0, 1.25];
  static const List<String> kSpeedLabels = ['0.75x', '1.0x', '1.25x'];

  bool get live => plan?.live ?? false;
  bool get precise => plan?.precise ?? false;

  /// 直播降级只走系统 TTS：高清包可用不代表实时朗读可用。
  bool get liveSystemReady => tts.status == TtsStatus.ready;
  bool get canPlay =>
      phase == ListeningPlayerPhase.ready && (!live || liveSystemReady);
  double get speed => kSpeeds[speedIndex];

  /// 当前播放计划是否真的带讲解（原版/讲解版 toggle 的显示依据）。
  bool get explainedActive => _planExplained;

  /// 直播降级没有可缓存的 WAV，讲解版不可用。
  bool get canExplain => !live && plan != null;

  bool get inExplanation => _currentExpl != null;
  ListeningPlaybackItem? get activeExplanation => _currentExpl;
  ListeningSentenceAudio? get currentSentence {
    final p = plan;
    if (p == null || p.sentences.isEmpty) return null;
    return p.sentences[currentIndex.clamp(0, p.sentences.length - 1)];
  }

  bool get livePlaying => _livePlaying;

  StreamSubscription<int?>? _indexSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Timer? _flushTimer;
  Timer? _saveTimer;
  Timer? _sleepTimer;
  DateTime? _countStart;
  int _sessionSeconds = 0;
  bool _pauseLogged = true;
  bool _opened = false;
  bool _disposed = false;
  bool _loopSeeking = false;
  bool _livePlaying = false;
  bool _restarting = false;
  bool _serviceStarted = false;
  int _liveToken = 0;

  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    phase = ListeningPlayerPhase.preparing;
    _notify();
    try {
      // 先初始化系统 TTS：音色键在 init 后才稳定，缓存键才不会漂移。
      await tts.init();
      final segments = _preferExplain ? await _explanationSegments() : null;
      final p = await pipeline.prepare(
        article,
        tts,
        explanations: segments,
        onProgress: (done, total) {
          prepDone = done;
          prepTotal = total;
          _notify();
        },
      );
      plan = p;
      _planExplained = _preferExplain && p.precise;
      explainMode = _planExplained;
      if (_preferExplain && p.live) {
        explainMode = false;
        onNotice?.call('实时朗读模式不支持讲解版，已按原版播放');
      }
      final restore = progress.listening.positionFor(article.id);
      final sameMode = restore != null &&
          restore.mode == (_planExplained ? 'x' : 'o');
      var idx = restore?.sentenceIndex ?? 0;
      var within = 0;
      if (restore != null && p.precise) {
        // 跨模式时两个时间轴含讲解与否不同，完听判定以「正文末句结束」为参照。
        final endRef = sameMode
            ? p.totalMs
            : (p.sentences.isEmpty ? 0 : p.sentences.last.endMs);
        final atEnd = restore.positionMs >= endRef - 1500;
        if (atEnd) {
          idx = 0;
        } else if (sameMode) {
          final start = p.startMsOf(idx);
          final bodyEnd = p.sentences.isEmpty
              ? start
              : p.sentences[idx.clamp(0, p.sentences.length - 1)].endMs;
          within = (restore.positionMs - start).clamp(0, bodyEnd - start);
        }
      }
      idx = idx.clamp(0, p.sentences.isEmpty ? 0 : p.sentences.length - 1);
      currentIndex = idx;
      currentItemIndex = p.itemIndexForSentence(idx);
      if (!p.live && p.sentences.isNotEmpty) {
        await _player.setAudioSources(
          _sourcesFor(p),
          initialIndex: currentItemIndex,
          initialPosition: Duration(milliseconds: within),
        );
        await _player.setSpeed(speed);
        _bindStreams();
        globalPosition.value = p.startMsOf(idx) + within;
      } else {
        globalPosition.value = p.startMsOf(idx);
      }
      phase = ListeningPlayerPhase.ready;
      _notify();
    } catch (e) {
      phase = ListeningPlayerPhase.error;
      error = '音频准备失败：$e';
      _notify();
    }
  }

  List<AudioSource> _sourcesFor(ListeningAudioPlan p) => [
        for (final it in p.items)
          if (it.path != null) AudioSource.file(it.path!, tag: it.id),
      ];

  Future<List<ListeningExplanationSegment>?> _explanationSegments() async {
    final pack = content;
    if (pack == null) return const [];
    final states = loadStates == null
        ? const <String, ChunkAssetState>{}
        : await loadStates!();
    return ListeningExplanationBuilder.build(
      article: article,
      states: states,
      content: pack,
      alreadyExplained: progress.listening.explainedKeys,
    );
  }

  void _bindStreams() {
    _indexSub = _player.currentIndexStream.listen((i) {
      if (i == null || plan == null || rebuilding) return;
      final p = plan!;
      if (i < 0 || i >= p.items.length) return;
      final item = p.items[i];
      final previousExpl = _currentExpl;
      currentItemIndex = i;
      if (previousExpl != null && previousExpl.id != item.id) {
        _closeExplanation(previousExpl, natural: !_explInterrupted);
        _explInterrupted = false;
      }
      if (item.isExplanation) {
        if (previousExpl == null || previousExpl.id != item.id) {
          _currentExpl = item;
          _logExplanationStart(item);
        }
      } else {
        _currentExpl = null;
      }
      currentIndex = item.sentenceIndex;
      globalPosition.value = globalPositionMs;
      _syncPlayback();
      _notify();
      _maybeApplyPending(item);
    });
    _posSub = _player.positionStream.listen((pos) {
      final p = plan;
      if (p == null || p.items.isEmpty) return;
      final item =
          p.items[currentItemIndex.clamp(0, p.items.length - 1)];
      final g = item.startMs + pos.inMilliseconds;
      globalPosition.value = g;
      if (abActive &&
          loopA != null &&
          loopB != null &&
          _player.playing &&
          g >= loopB!) {
        _enforceLoop();
      }
    });
    _stateSub = _player.playerStateStream.listen((st) {
      final was = playing;
      playing = st.playing && st.processingState != ProcessingState.completed;
      if (rebuilding) {
        // 换队列期间的状态抖动不记暂停/完听，避免污染学习口径。
        _notify();
        return;
      }
      if (st.processingState == ProcessingState.completed) {
        // 重播 seek 前后可能仍收到 completed 事件，忽略以免刚点播放就被打回。
        if (!_restarting) _onCompleted();
      } else {
        _restarting = false;
        if (was && !playing) {
          _onPaused();
        }
      }
      _syncPlayback();
      _notify();
    });
  }

  void _maybeApplyPending(ListeningPlaybackItem item) {
    final pending = _pendingExplainMode;
    if (pending == null) return;
    if (item.isExplanation) {
      if (pending == false) {
        // 切回原版时，句尾讲解不属于任何正文句，直接跳过去下一句。
        _pendingExplainMode = null;
        final expl = _currentExpl ?? item;
        _logExplanationSkip(expl, reason: 'mode_switch');
        _closeExplanation(expl, natural: false);
        _explInterrupted = false;
        final next = currentItemIndex + 1;
        if (next < plan!.items.length) {
          unawaited(_rebuildForMode(plan!.items[next].sentenceIndex,
              autoplay: playing));
        } else {
          _onCompleted();
        }
      }
      return;
    }
    if (pending == _planExplained) {
      _pendingExplainMode = null; // 用户又切回当前形态，无需换队列
      return;
    }
    _pendingExplainMode = null;
    final was = playing;
    unawaited(_rebuildForMode(item.sentenceIndex, autoplay: was));
  }

  void _logExplanationStart(ListeningPlaybackItem item) {
    progress.logEvent('listen_expl_start', {
      'article': article.id,
      'sentence': item.sentenceIndex,
      'chunks': item.chunkIds,
      'ms': item.durationMs,
    });
  }

  void _logExplanationSkip(ListeningPlaybackItem item,
      {String reason = 'user'}) {
    progress.logEvent('listen_expl_skip', {
      'article': article.id,
      'sentence': item.sentenceIndex,
      'chunks': item.chunkIds,
      'reason': reason,
      'ms': globalPositionMs,
    });
  }

  void _closeExplanation(ListeningPlaybackItem item,
      {required bool natural}) {
    if (natural) {
      progress.logEvent('listen_expl_complete', {
        'article': article.id,
        'sentence': item.sentenceIndex,
        'chunks': item.chunkIds,
      });
      unawaited(progress.listening.markExplained(item.memoryKeys));
    }
    if (_currentExpl?.id == item.id) _currentExpl = null;
  }

  /// 通知栏/锁屏动作；页面上其他交互不受影响。
  Future<void> _handlePlaybackAction(String action) async {
    if (_disposed) return;
    switch (action) {
      case 'play':
        if (!playing && !_livePlaying && canPlay) await togglePlay();
        break;
      case 'pause':
        await pause();
        break;
      case 'next':
        await next();
        break;
      case 'prev':
        await previous();
        break;
      case 'stop':
        _serviceStarted = false;
        await pause();
        await playback.stop();
        _notify();
        break;
    }
  }

  /// 把当前播放态同步给前台服务；首次进入播放才拉起通知，未播放不打扰。
  void _syncPlayback() {
    final p = plan;
    if (p == null) return;
    final isPlaying = playing || _livePlaying;
    if (!isPlaying && !_serviceStarted) return;
    if (isPlaying) _serviceStarted = true;
    unawaited(playback.sync(
      title: article.title,
      scene: article.sceneLabel.isNotEmpty
          ? article.sceneLabel
          : article.scene,
      playing: isPlaying,
      precise: p.precise,
      index: currentIndex,
      total: p.sentences.length,
      positionMs: globalPositionMs,
      speed: p.precise ? speed : 1.0,
    ));
  }

  void _enforceLoop() {
    if (_loopSeeking || loopA == null) return;
    _loopSeeking = true;
    unawaited(_seekGlobalMs(loopA!).whenComplete(() => _loopSeeking = false));
  }

  int get globalPositionMs {
    final p = plan;
    if (p == null) return 0;
    if (p.live) return p.startMsOf(currentIndex);
    if (p.items.isEmpty) return 0;
    final item = p.items[currentItemIndex.clamp(0, p.items.length - 1)];
    return item.startMs + _player.position.inMilliseconds;
  }

  Future<void> togglePlay() async {
    if (!canPlay || rebuilding) return;
    if (live) return _toggleLive();
    if (_player.playing) {
      await _player.pause(); // 状态流统一记 pause
      return;
    }
    if (completed) {
      completed = false;
      _restarting = true;
      await _player.seek(Duration.zero, index: 0);
      if (_disposed) return;
      _restarting = false;
      currentIndex = 0;
      currentItemIndex = 0;
      _currentExpl = null;
    }
    _pauseLogged = false;
    _beginCounting();
    progress.logEvent('listen_start', {
      'article': article.id,
      'mode': 'precise',
      'resume': currentIndex > 0 || _player.position.inMilliseconds > 0,
    });
    unawaited(_player.play());
  }

  Future<void> _toggleLive() async {
    if (_livePlaying) {
      _stopLive();
      _onPaused();
      _notify();
      return;
    }
    if (completed) {
      completed = false;
      currentIndex = 0;
    }
    final token = ++_liveToken;
    _livePlaying = true;
    _pauseLogged = false;
    _beginCounting();
    progress.logEvent('listen_start', {
      'article': article.id,
      'mode': 'live',
      'resume': currentIndex > 0,
    });
    _syncPlayback();
    _notify();
    while (token == _liveToken && currentIndex < plan!.sentences.length) {
      final ok = await tts.speakAndWait(plan!.sentences[currentIndex].text);
      if (token != _liveToken) return;
      if (!ok) {
        _livePlaying = false;
        _stopCounting();
        _syncPlayback();
        onNotice?.call('实时朗读失败，请检查系统语音引擎');
        _notify();
        return;
      }
      if (currentIndex >= plan!.sentences.length - 1) {
        _finishLive();
        return;
      }
      currentIndex++;
      globalPosition.value = plan!.startMsOf(currentIndex);
      _savePosition();
      _syncPlayback();
      _notify();
    }
  }

  void _finishLive() {
    _liveToken++;
    _livePlaying = false;
    completed = true;
    _serviceStarted = false;
    unawaited(playback.stop());
    _stopCounting();
    _savePosition();
    progress.logEvent('listen_complete', {
      'article': article.id,
      'secs': _sessionSeconds,
      'mode': 'live',
    });
    unawaited(progress.listening.markCompleted(article.id));
    if (sleepOption == SleepTimerOption.endOfArticle) {
      _resetSleep();
      onNotice?.call('本篇已播完，定时结束');
    }
    _notify();
  }

  void _stopLive() {
    _liveToken++;
    _livePlaying = false;
    _syncPlayback();
    unawaited(tts.stop());
  }

  Future<void> next() async {
    if (!canPlay) return;
    if (live) {
      final was = _livePlaying;
      _stopLive();
      if (currentIndex < plan!.sentences.length - 1) currentIndex++;
      globalPosition.value = plan!.startMsOf(currentIndex);
      _notify();
      _syncPlayback();
      if (was) unawaited(_toggleLive());
      return;
    }
    // 句级跳转：讲解段不占「下一句」，避免按两次才过一句。
    final target = currentIndex + 1;
    if (target >= plan!.sentences.length) return;
    await seekToSentence(target);
  }

  Future<void> previous() async {
    if (!canPlay) return;
    if (live) {
      final was = _livePlaying;
      _stopLive();
      if (currentIndex > 0) currentIndex--;
      globalPosition.value = plan!.startMsOf(currentIndex);
      _notify();
      _syncPlayback();
      if (was) unawaited(_toggleLive());
      return;
    }
    final target = currentIndex - 1;
    if (target < 0) return;
    await seekToSentence(target);
  }

  /// 点句重播：seek 到句起点（直播模式从该句重新读）。
  Future<void> replaySentence(int index) async {
    final p = plan;
    if (p == null || index < 0 || index >= p.sentences.length) return;
    progress.logEvent('sentence_replay', {'article': article.id, 'i': index});
    await seekToSentence(index);
  }

  /// 点块抽卡：只定位，不记重播事件。
  Future<void> seekToSentence(int index) async {
    final p = plan;
    if (p == null || index < 0 || index >= p.sentences.length) return;
    if (live) {
      final was = _livePlaying;
      _stopLive();
      currentIndex = index;
      globalPosition.value = p.startMsOf(index);
      _syncPlayback();
      _notify();
      if (was) unawaited(_toggleLive());
      return;
    }
    final itemIndex = p.itemIndexForSentence(index);
    final interrupted = _currentExpl;
    if (interrupted != null) {
      _logExplanationSkip(interrupted, reason: 'seek');
      _closeExplanation(interrupted, natural: false);
    }
    await _player.seek(Duration.zero, index: itemIndex);
    currentItemIndex = itemIndex;
    currentIndex = index;
    _currentExpl = null;
    _explInterrupted = false;
    globalPosition.value = p.startMsOf(index);
    _syncPlayback();
    _notify();
  }

  /// 跳过讲解：立刻进入下一句；最后一句的讲解跳过后视为整篇完听。
  Future<void> skipExplanation() async {
    final p = plan;
    final expl = _currentExpl;
    if (p == null || expl == null || live) return;
    _logExplanationSkip(expl, reason: 'user');
    _closeExplanation(expl, natural: false);
    final next = currentItemIndex + 1;
    if (next >= p.items.length) {
      _explInterrupted = false;
      _onCompleted();
      return;
    }
    _explInterrupted = true;
    await _player.seek(Duration.zero, index: next);
    final item = p.items[next];
    currentItemIndex = next;
    currentIndex = item.sentenceIndex;
    _currentExpl = null;
    _explInterrupted = false;
    globalPosition.value = item.startMs;
    _syncPlayback();
    _notify();
  }

  Future<void> _seekGlobalMs(int ms) async {
    final p = plan;
    if (p == null || p.live || p.items.isEmpty) return;
    final itemIndex = p.itemIndexForPositionMs(ms);
    final item = p.items[itemIndex];
    // 留在条目尾之前：拖到最右不应被系统判定为「整篇播完」。
    final cap = item.durationMs > 50 ? item.durationMs - 50 : 0;
    final within = (ms - item.startMs).clamp(0, cap);
    final previous = _currentExpl;
    if (previous != null &&
        (!item.isExplanation || previous.id != item.id)) {
      _logExplanationSkip(previous, reason: 'seek');
      _closeExplanation(previous, natural: false);
    }
    await _player.seek(Duration(milliseconds: within), index: itemIndex);
    currentItemIndex = itemIndex;
    currentIndex = item.sentenceIndex;
    _currentExpl = item.isExplanation ? item : null;
    if (item.isExplanation &&
        (previous == null || previous.id != item.id)) {
      _logExplanationStart(item);
    }
    _explInterrupted = false;
    globalPosition.value = item.startMs + within;
  }

  /// 拖动进度条：只跳转，不按「重播句」计事件。
  Future<void> seekToPositionMs(int ms) async {
    await _seekGlobalMs(ms);
    _syncPlayback();
    _notify();
  }

  Future<void> setSpeedIndex(int index) async {
    final i = index.clamp(0, kSpeeds.length - 1);
    if (i == speedIndex) return;
    speedIndex = i;
    if (!live) await _player.setSpeed(speed);
    // 手动变速按级别记忆，只影响本级文章的默认落点。
    await progress.listening.setSpeedOverride(article.level.key, speed);
    progress.logEvent('speed_change', {
      'article': article.id,
      'speed': speed,
    });
    _syncPlayback();
    _notify();
  }

  /// 原版/讲解版切换（指令 S+ §一.1）。
  ///
  /// 正在播正文句时只登记待切，等这句播完的条目边界再换队列——不打断当前句；
  /// 暂停时立即换队列并停在同句起点。
  Future<void> setExplainMode(bool on) async {
    if (rebuilding) return;
    if (live) {
      onNotice?.call('实时朗读模式不支持讲解版');
      return;
    }
    if (on == explainMode) {
      if (_pendingExplainMode != null) {
        // 播放中先切到 X 又切回来：取消待切，偏好同步回当前形态。
        _pendingExplainMode = null;
        _preferExplain = on;
        await progress.listening.setExplainMode(on);
      }
      _notify();
      return;
    }
    _preferExplain = on;
    await progress.listening.setExplainMode(on);
    progress.logEvent('listen_mode_switch', {
      'article': article.id,
      'mode': on ? 'explained' : 'original',
      'i': currentIndex,
      'playing': playing,
    });
    if (playing && !inExplanation) {
      // 当前句先播完；pending 在下一句边界生效。
      explainMode = on;
      _pendingExplainMode = on;
      _notify();
      return;
    }
    explainMode = on;
    _pendingExplainMode = null;
    if (playing && inExplanation) {
      final expl = _currentExpl!;
      _logExplanationSkip(expl, reason: 'mode_switch');
      _closeExplanation(expl, natural: false);
      final next = currentIndex + 1;
      await _rebuildForMode(
          next < plan!.sentences.length ? next : currentIndex,
          autoplay: true);
      return;
    }
    final within = _currentExpl == null ? _player.position.inMilliseconds : 0;
    _currentExpl = null;
    await _rebuildForMode(currentIndex, withinMs: within, autoplay: false);
  }

  /// 用新模式的计划替换播放队列，并回到同一句；调用前保证语义上不在句中。
  Future<void> _rebuildForMode(
    int sentenceIndex, {
    int withinMs = 0,
    required bool autoplay,
  }) async {
    if (_disposed || rebuilding) return;
    rebuilding = true;
    final wasPlaying = playing;
    try {
      // 先把这段时长记到旧模式名下；准备期间不计浸泡。
      if (wasPlaying) _stopCounting();
      if (_player.playing) await _player.pause();
      final segments = explainMode ? await _explanationSegments() : null;
      final p = await pipeline.prepare(
        article,
        tts,
        explanations: segments,
        onProgress: (done, total) {
          prepDone = done;
          prepTotal = total;
          _notify();
        },
      );
      if (_disposed) return;
      plan = p;
      _planExplained = segments != null && p.precise;
      if (p.live) {
        _planExplained = false;
        explainMode = false;
        onNotice?.call('音频源已降级为实时朗读，讲解版不可用');
      }
      final target =
          sentenceIndex.clamp(0, p.sentences.isEmpty ? 0 : p.sentences.length - 1);
      currentIndex = target;
      currentItemIndex = p.itemIndexForSentence(target);
      _currentExpl = null;
      _pendingExplainMode = null;
      if (!p.live && p.items.isNotEmpty) {
        await _player.setAudioSources(
          _sourcesFor(p),
          initialIndex: currentItemIndex,
          initialPosition: Duration(milliseconds: withinMs),
        );
        await _player.setSpeed(speed);
        globalPosition.value = p.startMsOf(target) + withinMs;
        if (autoplay && wasPlaying) {
          _beginCounting();
          unawaited(_player.play());
        }
      }
      _syncAfterRebuild();
    } catch (e) {
      explainMode = _planExplained;
      onNotice?.call('切换播放模式失败：$e');
    } finally {
      rebuilding = false;
      _notify();
    }
  }

  /// setAudioSources 不会换 player，但换队列期间的索引事件可能被丢弃；
  /// 重建完成后主动把条目索引对齐，避免 UI/后台通知停在上一条。
  void _syncAfterRebuild() {
    final p = plan;
    if (p == null || p.items.isEmpty) return;
    currentItemIndex = p.itemIndexForSentence(currentIndex);
    _syncPlayback();
  }

  void markLoopA() {
    if (live) return;
    loopA = globalPositionMs;
    loopB = null;
    abActive = false;
    _notify();
  }

  void markLoopB() {
    if (live) return;
    final b = globalPositionMs;
    final a = loopA;
    if (a == null) {
      loopA = b;
      _notify();
      return;
    }
    if (b <= a + 300) {
      onNotice?.call('B 需晚于 A 至少 0.3 秒');
      return;
    }
    loopB = b;
    abActive = true;
    progress.logEvent('ab_loop_use', {
      'article': article.id,
      'a': a,
      'b': b,
      'cross': plan!.indexForPositionMs(a) != plan!.indexForPositionMs(b),
    });
    unawaited(_seekGlobalMs(a));
    _notify();
  }

  void clearLoop() {
    loopA = null;
    loopB = null;
    abActive = false;
    _notify();
  }

  void setSleep(SleepTimerOption option) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepDeadline = null;
    sleepOption = option;
    final minutes = switch (option) {
      SleepTimerOption.m5 => 5,
      SleepTimerOption.m15 => 15,
      SleepTimerOption.m30 => 30,
      _ => 0,
    };
    if (minutes > 0) {
      final d = Duration(minutes: minutes);
      sleepDeadline = DateTime.now().add(d);
      _sleepTimer = Timer(d, () {
        _resetSleep();
        unawaited(pause());
        onNotice?.call('定时结束，已暂停');
        _notify();
      });
    }
    _notify();
  }

  void _resetSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepDeadline = null;
    sleepOption = SleepTimerOption.off;
  }

  Future<void> pause() async {
    if (live) {
      if (_livePlaying) {
        _stopLive();
        _onPaused();
        _notify();
      }
      return;
    }
    if (_player.playing) await _player.pause();
  }

  void _beginCounting() {
    if (_countStart != null) return;
    _countStart = DateTime.now();
    _flushTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      _flushSeconds();
    });
    _saveTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (playing || _livePlaying) _savePosition();
    });
  }

  void _flushSeconds() {
    final start = _countStart;
    if (start == null) return;
    final now = DateTime.now();
    final secs = now.difference(start).inSeconds;
    if (secs <= 0) return;
    _countStart = now;
    _sessionSeconds += secs;
    unawaited(progress.listening.addSeconds(secs));
    unawaited(progress.listening
        .addModeSeconds(_planExplained ? 'x' : 'o', secs));
  }

  void _stopCounting() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _saveTimer?.cancel();
    _saveTimer = null;
    _flushSeconds();
    _countStart = null;
  }

  void _savePosition() {
    final p = plan;
    if (p == null) return;
    final ms = globalPositionMs;
    unawaited(progress.listening.savePosition(
      article.id,
      ms,
      currentIndex,
      mode: _planExplained ? 'x' : 'o',
    ));
  }

  void _onPaused() {
    if (_pauseLogged) return;
    _pauseLogged = true;
    _stopCounting();
    _savePosition();
    progress.logEvent('listen_pause', {
      'article': article.id,
      'ms': globalPositionMs,
      'secs': _sessionSeconds,
    });
    _syncPlayback();
    _notify();
    // 暂停时不必再等句界：立刻按新模式重建队列，停在同句（讲解段内则回句首）。
    final pending = _pendingExplainMode;
    if (pending != null && !live && !rebuilding) {
      _pendingExplainMode = null;
      final within =
          _currentExpl == null ? _player.position.inMilliseconds : 0;
      _currentExpl = null;
      unawaited(
          _rebuildForMode(currentIndex, withinMs: within, autoplay: false));
    }
  }

  void _onCompleted() {
    if (completed) return;
    final expl = _currentExpl;
    if (expl != null) {
      _closeExplanation(expl, natural: !_explInterrupted);
      _currentExpl = null;
      _explInterrupted = false;
    }
    completed = true;
    playing = false;
    _pauseLogged = true;
    _serviceStarted = false;
    unawaited(playback.stop());
    _stopCounting();
    _savePosition();
    progress.logEvent('listen_complete', {
      'article': article.id,
      'secs': _sessionSeconds,
      'mode': 'precise',
    });
    unawaited(progress.listening.markCompleted(article.id));
    if (sleepOption == SleepTimerOption.endOfArticle) {
      _resetSleep();
      onNotice?.call('本篇已播完，定时结束');
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _liveToken++;
    _serviceStarted = false;
    playback.onAction = null;
    unawaited(playback.stop());
    _sleepTimer?.cancel();
    _flushTimer?.cancel();
    _saveTimer?.cancel();
    _flushSeconds();
    _countStart = null;
    _savePosition();
    if (playing || _livePlaying) {
      progress.logEvent('listen_pause', {
        'article': article.id,
        'ms': globalPositionMs,
        'secs': _sessionSeconds,
        'exit': true,
      });
    }
    unawaited(tts.stop());
    _indexSub?.cancel();
    _posSub?.cancel();
    _stateSub?.cancel();
    unawaited(_player.dispose());
    globalPosition.dispose();
    super.dispose();
  }
}

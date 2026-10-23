import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/listening_article.dart';
import 'listening_audio.dart';
import 'listening_playback.dart';
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
    ListeningAudioPipeline? pipeline,
    AudioPlayer? player,
    ListeningPlayback? playback,
  })  : pipeline = pipeline ?? ListeningAudioPipeline(),
        _player = player ?? AudioPlayer(),
        playback = playback ?? ListeningPlayback.instance {
    this.playback.onAction = _handlePlaybackAction;
  }

  final ProgressService progress;
  final TtsService tts;
  final ListeningArticle article;
  final ListeningAudioPipeline pipeline;
  final ListeningPlayback playback;
  final AudioPlayer _player;

  /// 全局播放位置（跨句毫秒）：页面用 ValueListenableBuilder 订阅，避免整页高频重建。
  final ValueNotifier<int> globalPosition = ValueNotifier<int>(0);

  ListeningPlayerPhase phase = ListeningPlayerPhase.idle;
  ListeningAudioPlan? plan;
  String? error;
  int currentIndex = 0;
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
      final p = await pipeline.prepare(
        article,
        tts,
        onProgress: (done, total) {
          prepDone = done;
          prepTotal = total;
          _notify();
        },
      );
      plan = p;
      final restore = progress.listening.positionFor(article.id);
      var idx = restore?.sentenceIndex ?? 0;
      var within = 0;
      if (restore != null && p.precise) {
        final atEnd = restore.positionMs >= p.totalMs - 1500;
        idx = atEnd ? 0 : p.indexForPositionMs(restore.positionMs);
        within =
            atEnd ? 0 : (restore.positionMs - p.startMsOf(idx)).clamp(0, 600000);
      }
      idx = idx.clamp(0, p.sentences.isEmpty ? 0 : p.sentences.length - 1);
      currentIndex = idx;
      if (!p.live && p.sentences.isNotEmpty) {
        await _player.setAudioSources(
          [
            for (final s in p.sentences) AudioSource.file(s.path!, tag: s.id),
          ],
          initialIndex: idx,
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

  void _bindStreams() {
    _indexSub = _player.currentIndexStream.listen((i) {
      if (i == null || plan == null) return;
      if (i != currentIndex) {
        currentIndex = i;
        globalPosition.value = globalPositionMs;
        _syncPlayback();
        _notify();
      }
    });
    _posSub = _player.positionStream.listen((pos) {
      if (plan == null) return;
      final g = plan!.startMsOf(currentIndex) + pos.inMilliseconds;
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
    return p.startMsOf(currentIndex) + _player.position.inMilliseconds;
  }

  Future<void> togglePlay() async {
    if (!canPlay) return;
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
    await _player.seekToNext();
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
    await _player.seekToPrevious();
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
    await _player.seek(Duration.zero, index: index);
    currentIndex = index;
    globalPosition.value = p.startMsOf(index);
    _syncPlayback();
    _notify();
  }

  Future<void> _seekGlobalMs(int ms) async {
    final p = plan;
    if (p == null || p.live) return;
    final idx = p.indexForPositionMs(ms);
    final s = p.sentences[idx];
    // 留在句尾之前：拖到最右不应被系统判定为「整篇播完」。
    final cap = s.durationMs > 50 ? s.durationMs - 50 : 0;
    final within = (ms - p.startMsOf(idx)).clamp(0, cap);
    await _player.seek(Duration(milliseconds: within), index: idx);
    currentIndex = idx;
    globalPosition.value = p.startMsOf(idx) + within;
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
    progress.logEvent('speed_change', {
      'article': article.id,
      'speed': speed,
    });
    _syncPlayback();
    _notify();
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
    unawaited(progress.listening.savePosition(article.id, ms, currentIndex));
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
  }

  void _onCompleted() {
    if (completed) return;
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

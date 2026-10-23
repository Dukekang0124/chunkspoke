import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'hd_voice_engine.dart';
import 'hd_voice_player.dart';
import 'hd_voice_types.dart';
import 'vosk_model.dart';
import 'wav_codec.dart';

/// 高清发音包：下载 → 落盘校验 → VITS 离线合成 → 原生播放。
///
/// 下载/续传/清场全部复用 ModelManager（B3 硬化链），本类只负责状态机与发声路由。
class HdVoiceService extends ChangeNotifier
    implements HdVoiceSpeaker, HdVoiceSynthesizer {
  HdVoiceService({
    required bool Function() isEnabled,
    required Future<void> Function(bool) setEnabled,
    ModelManifest? manifest,
    HdVoiceDownloader? downloader,
    HdVoiceSynth Function()? synthFactory,
    HdVoicePlayer? player,
    Future<Directory> Function()? cacheDir,
    void Function(String event, Map<String, dynamic> params)? onEvent,
  })  : _isEnabled = isEnabled,
        _onEvent = onEvent,
        _setEnabledPref = setEnabled,
        _manifest = manifest,
        _downloader = downloader,
        _synthFactory = synthFactory ?? IsolateHdVitsEngine.new,
        _player = player ?? MethodChannelHdVoicePlayer(),
        _cacheDir = cacheDir {
    _synth = _synthFactory();
    _enabled = _isEnabled();
  }

  /// 14 词标定句 5.59s ≈ 150 wpm，与系统 TTS 0.22 档（5.46s ≈ 154 wpm）对齐。
  static const double kSpeed = 0.58;
  static const String kAuditionText = "I'd like a cup of coffee.";

  final bool Function() _isEnabled;
  final Future<void> Function(bool) _setEnabledPref;
  final HdVoiceSynth Function() _synthFactory;
  final HdVoicePlayer _player;
  final Future<Directory> Function()? _cacheDir;

  /// 观测埋点回调（首启高清包下载完成率分开统计用）；抛错绝不影响下载。
  final void Function(String event, Map<String, dynamic> params)? _onEvent;

  void _emit(String event, [Map<String, dynamic> params = const {}]) {
    final cb = _onEvent;
    if (cb == null) return;
    try {
      cb(event, params);
    } catch (_) {}
  }

  ModelManifest? _manifest;
  HdVoiceDownloader? _downloader;
  late HdVoiceSynth _synth;

  Future<void>? _initInFlight;
  StreamSubscription<ModelProgress>? _progressSub;
  ModelProgress? _progress;
  String? _modelDir;
  String? _error;
  String? _engineError;
  bool _ready = false;
  bool _enabled = false;
  bool _downloading = false;
  bool _deleting = false;
  bool _disposed = false;
  bool _engineUp = false;
  Future<bool>? _engineStarting;
  int _speakToken = 0;

  bool get ready => _ready;
  bool get enabled => _enabled;

  @override
  bool get active => _ready && _enabled;

  @override
  String get modelTag {
    final m = _manifest;
    final v = (m?.modelVersion ?? '').trim();
    if (v.isNotEmpty) return v;
    final n = (m?.name ?? '').trim();
    return n.isEmpty ? 'vits' : n;
  }

  bool get downloading => _downloading;
  bool get deleting => _deleting;
  bool get engineUp => _engineUp;
  ModelProgress? get progress => _progress;
  String? get error => _error;
  String? get engineError => _engineError;

  Future<void> init() {
    final inFlight = _initInFlight;
    if (inFlight != null) return inFlight;
    final f = _doInit().whenComplete(() => _initInFlight = null);
    _initInFlight = f;
    return f;
  }

  Future<void> _doInit() async {
    try {
      _enabled = _isEnabled();
      _manifest ??= await loadHdVoiceManifest();
      final d = _downloader ??=
          ManagerHdVoiceDownloader(ModelManager(manifest: _manifest!));
      _progressSub ??= d.progress.listen((p) {
        _progress = p;
        _notify();
      });
      _ready = await d.isReady();
      if (_ready) _modelDir = await d.modelDirPath();
    } catch (e) {
      debugPrint('[hd-voice] init failed: $e');
      _ready = false;
      _error = '高清发音包暂不可用，请更新应用后重试';
    }
    _notify();
  }

  Future<void> download({bool retry = false}) async {
    await init();
    final d = _downloader;
    if (d == null) {
      _error = '高清发音包暂不可用，请更新应用后重试';
      _notify();
      return;
    }
    if (_downloading) return;
    _downloading = true;
    _error = null;
    _engineError = null;
    _progress = null;
    _notify();
    final startedAt = DateTime.now();
    _emit('hd_dl_start', {'retry': retry, 'size': _manifest?.size ?? 0});
    try {
      if (retry) await d.resetIncomplete();
      final dir = await d.ensureModel();
      await _resetEngine();
      _modelDir = dir;
      _ready = true;
      _progress = null;
      _enabled = true;
      try {
        await _setEnabledPref(true);
      } catch (_) {}
      _emit('hd_dl_done', {
        'secs': DateTime.now().difference(startedAt).inSeconds,
        'size': _manifest?.size ?? 0,
      });
    } catch (e) {
      debugPrint('[hd-voice] download failed: $e');
      _error = friendlyHdError(e);
      _emit('hd_dl_fail', {
        'secs': DateTime.now().difference(startedAt).inSeconds,
        'err': _error,
      });
    } finally {
      _downloading = false;
      _notify();
    }
  }

  Future<void> setEnabled(bool value) async {
    if (value && !_ready) return;
    _enabled = value;
    try {
      await _setEnabledPref(value);
    } catch (_) {}
    _notify();
  }

  Future<void> delete() async {
    if (_downloading || _deleting) return;
    _deleting = true;
    _notify();
    try {
      _speakToken++;
      await _player.stop();
      await _resetEngine();
      await _downloader?.discard();
      _ready = false;
      _modelDir = null;
      _progress = null;
      _error = null;
      _enabled = false;
      try {
        await _setEnabledPref(false);
      } catch (_) {}
      await _deleteCachedWav();
    } catch (e) {
      _error = '高清发音包删除失败，请重试';
      debugPrint('[hd-voice] delete failed: $e');
    } finally {
      _deleting = false;
      _notify();
    }
  }

  /// 试听/朗读入口。失败返回 false，由 TtsService 回落到系统引擎。
  @override
  Future<bool> speak(String text) async {
    if (!active) return false;
    final t = text.trim();
    if (t.isEmpty) return false;
    final token = ++_speakToken;
    try {
      await _player.stop();
      if (!await _ensureEngine()) return false;
      final audio = await _synth.synthesize(t, speed: kSpeed);
      if (token != _speakToken || _disposed) return false;
      final dir = await _cache();
      final f = File(p.join(dir.path, 'last.wav'));
      await writeWavFile(f, audio.samples, audio.sampleRate);
      if (token != _speakToken || _disposed) return false;
      await _player.playWav(f.path);
      _error = null;
      return true;
    } catch (e) {
      debugPrint('[hd-voice] speak failed: $e');
      _error = '高清发音暂不可用，已切回系统发音';
      _notify();
      return false;
    }
  }

  /// 离线合成到指定 WAV（浸泡层缓存管线）。不占播放通道，不动 speakToken。
  @override
  Future<bool> synthesizeToFile(String text, String fullPath) async {
    final t = text.trim();
    if (t.isEmpty || !active) return false;
    try {
      if (!await _ensureEngine()) return false;
      final audio = await _synth.synthesize(t, speed: kSpeed);
      await writeWavFile(File(fullPath), audio.samples, audio.sampleRate);
      return true;
    } catch (e) {
      debugPrint('[hd-voice] synthesizeToFile failed: $e');
      _error = '高清发音暂不可用，已切回系统发音';
      _notify();
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _speakToken++;
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<Directory> _cache() async {
    if (_cacheDir != null) return _cacheDir();
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'hd_voice'));
  }

  /// 固定路径清理试听音频：删除操作可能发生在重启之后，此时内存里没有路径。
  Future<void> _deleteCachedWav() async {
    try {
      final dir = await _cache();
      final f = File(p.join(dir.path, 'last.wav'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<bool> _ensureEngine() {
    final inFlight = _engineStarting;
    if (inFlight != null) return inFlight;
    if (_engineUp) return Future<bool>.value(true);
    final f = _startEngine().whenComplete(() => _engineStarting = null);
    _engineStarting = f;
    return f;
  }

  Future<bool> _startEngine() async {
    final dir = _modelDir;
    if (dir == null) return false;
    try {
      await _synth.init(dir);
      _engineUp = true;
      _engineError = null;
      _notify();
      return true;
    } catch (e) {
      debugPrint('[hd-voice] engine init failed: $e');
      _engineUp = false;
      _engineError = '高清发音包加载失败，建议删除后重新下载';
      _notify();
      return false;
    }
  }

  Future<void> _resetEngine() async {
    _engineUp = false;
    try {
      await _synth.dispose();
    } catch (_) {}
    _synth = _synthFactory();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _speakToken++;
    _progressSub?.cancel();
    _synth.dispose();
    _player.dispose();
    _downloader?.dispose();
    super.dispose();
  }
}

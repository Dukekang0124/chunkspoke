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

/// 自然人声（离线）：多音色目录 → 按需下载 → VITS 合成 → 原生播放。
///
/// 每个音色独立成包、独立目录、独立校验/续传/删除（复用 ModelManager B3 链）；
/// 同一时刻只有一个音色生效，引擎故障时自动落到另一个已装音色或系统发音。
class HdVoiceService extends ChangeNotifier
    implements HdVoiceSpeaker, HdVoiceSynthesizer {
  HdVoiceService({
    required bool Function() isEnabled,
    required Future<void> Function(bool) setEnabled,
    ModelManifest? manifest,
    List<HdVoiceOption>? voices,
    HdVoiceDownloader? downloader,
    HdVoiceDownloader Function(ModelManifest)? downloaderFactory,
    String? Function()? readVoiceId,
    Future<void> Function(String)? persistVoiceId,
    HdVoiceSynth Function()? synthFactory,
    HdVoicePlayer? player,
    Future<Directory> Function()? cacheDir,
    void Function(String event, Map<String, dynamic> params)? onEvent,
  })  : _isEnabled = isEnabled,
        _onEvent = onEvent,
        _setEnabledPref = setEnabled,
        _voicesOverride = voices,
        _manifest = manifest,
        _downloaderOverride = downloader,
        _downloaderFactory = downloaderFactory,
        _readVoiceId = readVoiceId,
        _persistVoiceId = persistVoiceId,
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
  final HdVoiceDownloader Function(ModelManifest)? _downloaderFactory;
  final String? Function()? _readVoiceId;
  final Future<void> Function(String)? _persistVoiceId;

  /// 观测埋点回调（下载完成率/音色切换分口径）；抛错绝不影响业务。
  final void Function(String event, Map<String, dynamic> params)? _onEvent;

  void _emit(String event, [Map<String, dynamic> params = const {}]) {
    final cb = _onEvent;
    if (cb == null) return;
    try {
      cb(event, params);
    } catch (_) {}
  }

  final ModelManifest? _manifest;
  List<HdVoiceOption>? _voicesOverride;
  final HdVoiceDownloader? _downloaderOverride;

  List<HdVoiceOption> _voices = const [];
  final Map<String, HdVoiceDownloader> _downloaders = {};
  final Map<String, bool> _readyById = {};
  final Map<String, String> _dirById = {};
  final Map<String, ModelProgress> _progressById = {};
  final Map<String, String> _errorById = {};
  final Map<String, StreamSubscription<ModelProgress>> _subs = {};

  String? _activeId;
  String? _downloadingId;
  String? _catalogError;
  late HdVoiceSynth _synth;

  Future<void>? _initInFlight;
  String? _engineError;
  bool _enabled = false;
  bool _deleting = false;
  bool _disposed = false;
  bool _engineUp = false;
  Future<bool>? _engineStarting;
  int _speakToken = 0;

  List<HdVoiceOption> get voices => _voices;

  HdVoiceOption? get activeVoice {
    for (final v in _voices) {
      if (v.id == _activeId) return v;
    }
    return null;
  }

  String? get activeVoiceId => _activeId;

  /// 已装音色的模型目录（基准/排障用；未就绪返回 null）。
  String? modelDirFor(String id) => _dirById[id];

  bool isReady(String id) => _readyById[id] ?? false;

  bool isActive(String id) => id == _activeId && (_readyById[id] ?? false);

  bool isDownloading(String id) => _downloadingId == id;

  ModelProgress? progressFor(String id) => _progressById[id];

  String? errorFor(String id) => _errorById[id];

  /// 当前生效音色是否已就绪（决定是否接管朗读）。
  bool get ready => _activeId != null && isReady(_activeId!);
  bool get enabled => _enabled;

  @override
  bool get active => ready && _enabled;

  @override
  String get modelTag {
    final m = activeVoice?.manifest ?? _manifest;
    final v = (m?.modelVersion ?? '').trim();
    if (v.isNotEmpty) return v;
    final n = (m?.name ?? '').trim();
    return n.isEmpty ? 'vits' : n;
  }

  bool get downloading => _downloadingId != null;
  bool get deleting => _deleting;
  bool get engineUp => _engineUp;
  ModelProgress? get progress =>
      _progressById[_downloadingId ?? _activeId];
  String? get error {
    final e = _errorById[_downloadingId ?? _activeId ?? ''];
    return e ?? _catalogError;
  }

  String? get engineError => _engineError;

  /// 兼容旧调用：下载当前生效音色（未选则第一个）。
  Future<void> download({bool retry = false}) =>
      downloadVoice(_activeId ?? (_voices.isEmpty ? '' : _voices.first.id),
          retry: retry);

  /// 兼容旧调用：删除当前生效音色。
  Future<void> delete() async {
    final id = _activeId;
    if (id != null) await deleteVoice(id);
  }

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
      if (_voices.isEmpty) {
        _voices = _voicesOverride ??
            (_manifest != null
                ? [
                    HdVoiceOption(
                        label: '高清发音包', desc: '真人质感美音', manifest: _manifest)
                  ]
                : await loadHdVoiceCatalog());
        _voicesOverride = null;
      }
      for (final v in _voices) {
        final d = _downloaderFor(v.manifest);
        _subscribe(v.id, d);
        final ok = await d.isReady();
        _readyById[v.id] = ok;
        if (ok) _dirById[v.id] = await d.modelDirPath();
      }
      final want = _readVoiceId?.call();
      _activeId = _pickActive(want);
    } catch (e) {
      debugPrint('[hd-voice] init failed: $e');
      _activeId = null;
      _catalogError = '高清发音包暂不可用，请更新应用后重试';
    }
    _notify();
  }

  String? _pickActive(String? want) {
    if (want != null && isReady(want)) return want;
    for (final v in _voices) {
      if (isReady(v.id)) return v.id;
    }
    // 一个都没装：保留用户上次的选择（用于下载完成后原地生效），否则第一个。
    if (want != null && _voiceById(want) != null) return want;
    return _voices.isEmpty ? null : _voices.first.id;
  }

  HdVoiceOption? _voiceById(String id) {
    for (final v in _voices) {
      if (v.id == id) return v;
    }
    return null;
  }

  HdVoiceDownloader _downloaderFor(ModelManifest manifest) {
    final existing = _downloaders[manifest.name];
    if (existing != null) return existing;
    final created = _downloaderOverride != null && _voices.length <= 1
        ? _downloaderOverride
        : (_downloaderFactory?.call(manifest) ??
            ManagerHdVoiceDownloader(ModelManager(manifest: manifest)));
    _downloaders[manifest.name] = created;
    return created;
  }

  void _subscribe(String id, HdVoiceDownloader d) {
    _subs[id] ??= d.progress.listen((pr) {
      _progressById[id] = pr;
      _notify();
    });
  }

  Future<void> downloadVoice(String id, {bool retry = false}) async {
    await init();
    final v = _voiceById(id);
    if (v == null) {
      _catalogError = '高清发音包暂不可用，请更新应用后重试';
      _notify();
      return;
    }
    if (_downloadingId != null) return;
    _downloadingId = id;
    _errorById.remove(id);
    _engineError = null;
    _progressById.remove(id);
    _notify();
    final startedAt = DateTime.now();
    _emit('hd_dl_start', {'voice': id, 'retry': retry, 'size': v.manifest.size});
    try {
      final d = _downloaderFor(v.manifest);
      if (retry) await d.resetIncomplete();
      final dir = await d.ensureModel();
      _speakToken++;
      try {
        await _player.stop();
      } catch (_) {}
      await _resetEngine();
      _dirById[id] = dir;
      _readyById[id] = true;
      _activeId = id;
      _progressById.remove(id);
      _enabled = true;
      try {
        await _persistVoiceId?.call(id);
      } catch (_) {}
      try {
        await _setEnabledPref(true);
      } catch (_) {}
      _emit('hd_dl_done', {
        'voice': id,
        'secs': DateTime.now().difference(startedAt).inSeconds,
        'size': v.manifest.size,
      });
    } catch (e) {
      debugPrint('[hd-voice] download failed: $e');
      _errorById[id] = friendlyHdError(e);
      _emit('hd_dl_fail', {
        'voice': id,
        'secs': DateTime.now().difference(startedAt).inSeconds,
        'err': _errorById[id],
      });
    } finally {
      _downloadingId = null;
      _notify();
    }
  }

  /// 切换生效音色：仅已下载可用；切换即清引擎，下次朗读按新目录加载。
  Future<void> selectVoice(String id) async {
    await init();
    if (!isReady(id)) return;
    if (id != _activeId) {
      _speakToken++;
      try {
        await _player.stop();
      } catch (_) {}
      await _resetEngine();
      _activeId = id;
      try {
        await _persistVoiceId?.call(id);
      } catch (_) {}
      _emit('hd_voice_select', {'voice': id});
    }
    _enabled = true;
    try {
      await _setEnabledPref(true);
    } catch (_) {}
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    if (value && !ready) return;
    _enabled = value;
    try {
      await _setEnabledPref(value);
    } catch (_) {}
    _notify();
  }

  Future<void> deleteVoice(String id) async {
    await init();
    if (_deleting || _downloadingId == id) return;
    _deleting = true;
    _notify();
    try {
      final wasActive = id == _activeId;
      if (wasActive) {
        _speakToken++;
        try {
          await _player.stop();
        } catch (_) {}
        await _resetEngine();
      }
      final v = _voiceById(id);
      if (v != null) await _downloaderFor(v.manifest).discard();
      _readyById[id] = false;
      _dirById.remove(id);
      _progressById.remove(id);
      _errorById.remove(id);
      if (wasActive) {
        _activeId = _pickActive(null);
        if (ready) {
          try {
            await _persistVoiceId?.call(_activeId!);
          } catch (_) {}
        } else {
          _enabled = false;
          try {
            await _setEnabledPref(false);
          } catch (_) {}
        }
      }
      await _deleteCachedWav();
    } catch (e) {
      _errorById[id] = '高清发音包删除失败，请重试';
      debugPrint('[hd-voice] delete failed: $e');
    } finally {
      _deleting = false;
      _notify();
    }
  }

  /// 单个音色在磁盘上的占用（未下载返回 0）。
  Future<int> sizeOf(String id) async {
    final d = _downloaders[id];
    if (d == null) return 0;
    try {
      final dir = Directory(await d.modelDirPath());
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<int> installedBytes() async {
    var total = 0;
    for (final v in _voices) {
      if (isReady(v.id)) total += await sizeOf(v.id);
    }
    return total;
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
      _errorById.remove(_activeId ?? '');
      return true;
    } catch (e) {
      debugPrint('[hd-voice] speak failed: $e');
      _errorById[_activeId ?? ''] = '高清发音暂不可用，已切回系统发音';
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
      _errorById[_activeId ?? ''] = '高清发音暂不可用，已切回系统发音';
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
    final ids = <String>[
      if (_activeId != null) _activeId!,
      for (final v in _voices)
        if (v.id != _activeId && isReady(v.id)) v.id,
    ];
    for (final id in ids) {
      final dir = _dirById[id];
      if (dir == null) continue;
      try {
        await _synth.init(dir);
        _engineUp = true;
        _engineError = null;
        if (id != _activeId) {
          // 旧音色兜底：新音色加载失败时自动退回另一个已装音色。
          _activeId = id;
          try {
            await _persistVoiceId?.call(id);
          } catch (_) {}
          _emit('hd_voice_fallback', {'voice': id});
        }
        _notify();
        return true;
      } catch (e) {
        debugPrint('[hd-voice] engine init failed ($id): $e');
        _engineUp = false;
        await _resetEngine();
      }
    }
    _engineError = '高清发音包加载失败，建议删除后重新下载';
    _notify();
    return false;
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
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    _synth.dispose();
    _player.dispose();
    final seen = <HdVoiceDownloader>{};
    for (final d in _downloaders.values) {
      if (seen.add(d)) d.dispose();
    }
    final override = _downloaderOverride;
    if (override != null && seen.add(override)) override.dispose();
    super.dispose();
  }
}

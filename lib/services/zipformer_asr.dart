import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'audio_format.dart';
import 'vosk_engine.dart' show VoskResult, pcmFromWav;
import 'vosk_model.dart';

/// 增强识别（sherpa-onnx 流式 zipformer）· ASR-191 · 模式 B 并列高档包。
///
/// 纪律（与 ASR-188/190 一致）：
/// - **默认仍 Vosk**：本文件只在用户显式下载并开启后接管「开放式识别」；
///   跟读/评测的锁词表二过、所有受限解码仍走 Vosk，本后端不参与。
/// - **模型不走 huggingface**：清单由 `tools/pack_asr_model.py` 自打包 zip + 分片现算，
///   上游 LFS 指针只作来源留档；运行时只认 `assets/version.json` 的 `asrModel` 段。
/// - **失败必须回落**：任何下载/加载/识别异常都返回 null，由调用方继续用 Vosk，
///   且把可读原因留给设置页，不做静默换引擎。
/// - 增强结果没有置信度字段（sherpa 不产出），[VoskResult.confidence] 恒为 null；
///   判定层按既有口径走文本相似度，不把它当 0 拒判。

/// 增强识别清单（`assets/version.json` 的 `asrModel` 段）。
/// 缺段/无效返回 null —— 老版本清单或裁剪包不应因此崩。
Future<ModelManifest?> loadAsrEnhancementManifest() async {
  try {
    final raw = await rootBundle.loadString('assets/version.json');
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final m = j['asrModel'];
    if (m is! Map) return null;
    final manifest = ModelManifest.fromJson(m);
    if (!manifest.isValid) return null;
    const base = String.fromEnvironment('ASR_MODEL_BASE_URL');
    if (base.isEmpty) return manifest;
    // 模拟通道（仅取证）：与 Vosk 的 MODEL_BASE_URL 同法，报告须标「模拟通道」。
    return ModelManifest(
      name: manifest.name,
      modelVersion: manifest.modelVersion,
      sha256: manifest.sha256,
      size: manifest.size,
      parts: [
        for (var i = 0; i < manifest.parts.length; i++)
          ModelPart('$base/asr.part$i', manifest.parts[i].size,
              sha256: manifest.parts[i].sha256),
      ],
      mirrorUrl: '$base/${manifest.name}.zip',
    );
  } catch (e) {
    debugPrint('[asr+] 增强清单读取失败：$e');
    return null;
  }
}

/// 开关持久化：`<支持目录>/asr_backend.json`。
/// 不引入 shared_preferences（与 legacy_gate / update_service 同法，避免新增依赖）。
class AsrBackendPrefs {
  AsrBackendPrefs({Future<Directory> Function()? dir}) : _dir = dir;

  final Future<Directory> Function()? _dir;

  Future<File> _file() async {
    final d =
        _dir == null ? await getApplicationSupportDirectory() : await _dir();
    if (!await d.exists()) await d.create(recursive: true);
    return File(path.join(d.path, 'asr_backend.json'));
  }

  Future<bool> enhancedEnabled() async {
    try {
      final f = await _file();
      if (!await f.exists()) return false;
      final j = jsonDecode(await f.readAsString());
      return j is Map && j['enhanced'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setEnhancedEnabled(bool value) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({'enhanced': value}));
    } catch (e) {
      debugPrint('[asr+] 开关写入失败：$e');
    }
  }
}

/// 模型存储抽象：生产实现包一层 [ModelManager]；单测注入内存假件。
abstract class AsrModelStore {
  Future<bool> isReady();
  Future<String> ensureModel();
  Future<String> modelDirPath();
  Stream<ModelProgress> get getProgress;
}

class _ManagerModelStore implements AsrModelStore {
  _ManagerModelStore(this._m);
  final ModelManager _m;

  @override
  Future<bool> isReady() => _m.isReady();

  @override
  Future<String> ensureModel() => _m.ensureModel();

  @override
  Future<String> modelDirPath() => _m.modelDirPath();

  @override
  Stream<ModelProgress> get getProgress => _m.progress;
}

/// 识别后端抽象（生产 = 常驻 isolate + sherpa；单测 = 假件）。
abstract class AsrBackend {
  bool get isLoaded;
  Future<void> init(String modelDir);
  Future<String> transcribe(String wavPath, {List<String> hotwords = const []});
  Future<void> dispose();
}

/// 16 位单声道 PCM → [-1,1] 浮点（sherpa 只认浮点，塞 int16 会静默出空串）。
Float32List pcm16ToFloat32(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  final out = Float32List(n);
  final bd = ByteData.sublistView(pcm);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// 生产后端：每个进程一个持久 isolate，模型只加载一次。
/// 放到 isolate 的理由与 `hd_voice_engine` 同：43MB int8 模型加载/解码不能卡 UI 线程。
class SherpaAsrBackend implements AsrBackend {
  Isolate? _iso;
  SendPort? _worker;
  ReceivePort? _rx;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _seq = 0;
  bool _loaded = false;
  Future<void>? _initInFlight;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> init(String modelDir) {
    final inFlight = _initInFlight;
    if (inFlight != null) return inFlight;
    final f = _init(modelDir).whenComplete(() => _initInFlight = null);
    _initInFlight = f;
    return f;
  }

  Future<void> _init(String modelDir) async {
    if (_loaded) return;
    if (_iso == null) {
      final rx = ReceivePort();
      _rx = rx;
      final handshake = Completer<SendPort>();
      rx.listen((msg) {
        if (msg is! Map) return;
        if (msg['id'] == 0) {
          final p = msg['port'];
          if (p is SendPort && !handshake.isCompleted) handshake.complete(p);
          return;
        }
        final id = msg['id'];
        final c = id is int ? _pending.remove(id) : null;
        if (c != null && !c.isCompleted) {
          c.complete(Map<String, dynamic>.from(msg));
        }
      });
      _iso = await Isolate.spawn(_asrWorkerMain, rx.sendPort,
          debugName: 'zipformer-asr', errorsAreFatal: false);
      _worker = await handshake.future.timeout(const Duration(seconds: 10));
    }
    final res = await _call(
      {'cmd': 'init', 'modelDir': modelDir},
      const Duration(seconds: 90),
    );
    if (res['ok'] != true) {
      throw StateError('${res['error'] ?? '增强引擎加载失败'}');
    }
    _loaded = true;
  }

  Future<Map<String, dynamic>> _call(
      Map<String, dynamic> cmd, Duration timeout) {
    final worker = _worker;
    if (worker == null) throw StateError('增强引擎未启动');
    final id = ++_seq;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    worker.send(<String, dynamic>{...cmd, 'id': id});
    return c.future.timeout(timeout).whenComplete(() => _pending.remove(id));
  }

  @override
  Future<String> transcribe(String wavPath,
      {List<String> hotwords = const []}) async {
    if (!_loaded) throw StateError('增强引擎未加载');
    final res = await _call({
      'cmd': 'transcribe',
      'wavPath': wavPath,
      'hotwords': hotwords.join(' '),
    }, const Duration(seconds: 60));
    if (res['ok'] != true) {
      throw StateError('${res['error'] ?? '增强识别失败'}');
    }
    return (res['text'] as String?) ?? '';
  }

  @override
  Future<void> dispose() async {
    if (_worker != null) {
      try {
        await _call({'cmd': 'dispose'}, const Duration(seconds: 3));
      } catch (_) {}
    }
    _worker = null;
    _pending.clear();
    _loaded = false;
    try {
      _rx?.close();
    } catch (_) {}
    _rx = null;
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
  }
}

/// Worker 入口（顶层函数，供 Isolate.spawn）。
/// 消息协议：`{cmd: init|transcribe|dispose, id, ...}` → `{id, ok, ...}`。
void _asrWorkerMain(SendPort mainPort) {
  final rx = ReceivePort();
  mainPort.send(<String, dynamic>{'id': 0, 'port': rx.sendPort});
  sherpa.initBindings();
  sherpa.OnlineRecognizer? rec;

  sherpa.OnlineRecognizer build(String modelDir) {
    final encoder = _pickModelFile(modelDir, 'encoder');
    final decoder = _pickModelFile(modelDir, 'decoder');
    final joiner = _pickModelFile(modelDir, 'joiner');
    final tokens = path.join(modelDir, 'tokens.txt');
    if (!File(tokens).existsSync()) {
      throw StateError('模型缺少 tokens.txt');
    }
    return sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: encoder,
          decoder: decoder,
          joiner: joiner,
        ),
        tokens: tokens,
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
      decodingMethod: 'modified_beam_search',
      maxActivePaths: 4,
      enableEndpoint: false,
    ));
  }

  String run(String wavPath, String hotwords) {
    final r = rec;
    if (r == null) throw StateError('增强引擎未加载');
    final wav = File(wavPath).readAsBytesSync();
    final pcm = pcmFromWav(wav);
    if (pcm.isEmpty) return '';
    final samples = pcm16ToFloat32(pcm);
    final stream = hotwords.isEmpty
        ? r.createStream()
        : r.createStream(hotwords: hotwords);
    const chunk = 1600; // 0.1s @16k
    for (var i = 0; i < samples.length; i += chunk) {
      final end =
          (i + chunk) < samples.length ? i + chunk : samples.length;
      stream.acceptWaveform(
          samples: Float32List.sublistView(samples, i, end),
          sampleRate: kCaptureSampleRate);
    }
    stream.inputFinished();
    while (r.isReady(stream)) {
      r.decode(stream);
    }
    final text = r.getResult(stream).text;
    stream.free();
    return text.trim();
  }

  rx.listen((msg) {
    if (msg is! Map) return;
    final id = msg['id'];
    final reply = mainPort;
    try {
      switch (msg['cmd']) {
        case 'init':
          rec?.free();
          rec = build((msg['modelDir'] ?? '').toString());
          reply.send(<String, dynamic>{'id': id, 'ok': true});
          break;
        case 'transcribe':
          final text = run(
              (msg['wavPath'] ?? '').toString(),
              (msg['hotwords'] ?? '').toString());
          reply.send(<String, dynamic>{'id': id, 'ok': true, 'text': text});
          break;
        case 'dispose':
          rec?.free();
          rec = null;
          reply.send(<String, dynamic>{'id': id, 'ok': true});
          rx.close();
          return;
      }
    } catch (e) {
      reply.send(<String, dynamic>{'id': id, 'ok': false, 'error': '$e'});
    }
  });
}

/// 在模型目录里挑主干文件：优先 int8，其次任意 onnx（兼容 06-26 等档位命名）。
String _pickModelFile(String dir, String prefix) {
  final files = Directory(dir)
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => path.basename(p).startsWith('$prefix-'))
      .toList()
    ..sort();
  if (files.isEmpty) throw StateError('模型缺少 $prefix');
  final int8 = files.where((p) => p.endsWith('.int8.onnx')).toList();
  if (int8.isNotEmpty) return int8.first;
  final onnx = files.where((p) => p.endsWith('.onnx')).toList();
  if (onnx.isEmpty) throw StateError('模型缺少 $prefix');
  return onnx.first;
}

/// 增强识别编排：清单 → 下载 → 常驻后端 → 开关 → 失败回落。
class EnhancedAsrService extends ChangeNotifier {
  EnhancedAsrService({
    Future<ModelManifest?> Function()? loadManifest,
    Future<AsrModelStore> Function(ModelManifest)? createStore,
    AsrBackend Function()? createBackend,
    AsrBackendPrefs? prefs,
  })  : _loadManifest = loadManifest ?? loadAsrEnhancementManifest,
        _createStore = createStore ?? _defaultStore,
        _createBackend = createBackend ?? (() => SherpaAsrBackend()),
        _prefs = prefs ?? AsrBackendPrefs();

  static final EnhancedAsrService instance = EnhancedAsrService();

  static Future<AsrModelStore> _defaultStore(ModelManifest m) async =>
      _ManagerModelStore(ModelManager(manifest: m));

  final Future<ModelManifest?> Function() _loadManifest;
  final Future<AsrModelStore> Function(ModelManifest) _createStore;
  final AsrBackend Function() _createBackend;
  final AsrBackendPrefs _prefs;

  ModelManifest? _manifest;
  AsrModelStore? _store;
  AsrBackend? _backend;
  Future<void>? _refreshInFlight;

  bool _enabled = false;
  bool _installed = false;
  bool _busy = false;
  bool _refreshed = false;
  String? _lastError;
  ModelPhase? _phase;
  int _received = 0;
  int _total = 0;

  bool get enabled => _enabled;
  bool get installed => _installed;
  bool get busy => _busy;
  bool get ready => _backend?.isLoaded == true;
  String? get lastError => _lastError;
  ModelPhase? get phase => _phase;
  int get progressReceived => _received;
  int get progressTotal => _total;
  ModelManifest? get manifest => _manifest;

  /// 展示用体积（十进制 MB，与 ASR-190 复核口径一致）。
  String get modelSizeLabel {
    final s = _manifest?.size ?? 0;
    if (s <= 0) return '—';
    return '${(s / 1000000).toStringAsFixed(2)} MB';
  }

  void _emit() {
    if (hasListeners) notifyListeners();
  }

  /// 读清单/开关/磁盘状态（轻量，不加载模型、不触发下载）。
  Future<void> refresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final f = _doRefresh().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = f;
    return f;
  }

  Future<void> _doRefresh() async {
    if (_refreshed) return;
    _manifest = await _loadManifest();
    _enabled = await _prefs.enhancedEnabled();
    if (_manifest == null) {
      _installed = false;
      _refreshed = true;
      _emit();
      return;
    }
    try {
      _store ??= await _createStore(_manifest!);
      _installed = await _store!.isReady();
    } catch (e) {
      _installed = false;
      debugPrint('[asr+] 磁盘检查失败：$e');
    }
    _refreshed = true;
    _emit();
  }

  /// 下载并启用（用户在设置页显式点击）。
  Future<bool> downloadAndEnable() async {
    await refresh();
    final m = _manifest;
    if (m == null) {
      _lastError = '增强识别清单缺失，请更新应用后重试';
      _emit();
      return false;
    }
    if (_busy) return false;
    _busy = true;
    _lastError = null;
    _phase = ModelPhase.downloading;
    _received = 0;
    _total = m.size;
    _emit();
    StreamSubscription<ModelProgress>? sub;
    try {
      _store ??= await _createStore(m);
      sub = _store!.getProgress.listen((p) {
        _phase = p.phase;
        _received = p.received;
        _total = p.total;
        _emit();
      });
      final dir = await _store!.ensureModel();
      _installed = true;
      _phase = null;
      final ok = await _loadBackend(dir);
      if (ok) {
        _enabled = true;
        await _prefs.setEnhancedEnabled(true);
      }
      return ok;
    } catch (e) {
      _lastError = e is ModelDownloadException ? e.message : '增强模型下载失败，请重试';
      debugPrint('[asr+] 下载失败：$e');
      return false;
    } finally {
      await sub?.cancel();
      _busy = false;
      _phase = null;
      _emit();
    }
  }

  /// 开关。开启但未下载 → 直接走下载；关闭 → 释放常驻识别器（可切回默认）。
  Future<bool> setEnabled(bool value) async {
    await refresh();
    if (value) {
      if (!_installed) return downloadAndEnable();
      final store = _store;
      if (store == null) return false;
      final dir = await store.modelDirPath();
      if (!await _loadBackend(dir)) return false;
    }
    _enabled = value;
    await _prefs.setEnhancedEnabled(value);
    if (!value) {
      await _backend?.dispose();
      _backend = null;
    }
    _emit();
    return true;
  }

  Future<bool> _loadBackend(String modelDir) async {
    if (_backend?.isLoaded == true) return true;
    _busy = true;
    _phase = null;
    _emit();
    final b = _createBackend();
    try {
      await b.init(modelDir);
      _backend = b;
      return true;
    } catch (e) {
      _lastError = '增强引擎加载失败，已回落 Vosk';
      debugPrint('[asr+] 后端加载失败：$e');
      try {
        await b.dispose();
      } catch (_) {}
      return false;
    } finally {
      _busy = false;
      _emit();
    }
  }

  /// 启动时预热（非阻塞）：开关开着且模型在盘才加载，否则什么都不做。
  Future<void> warmUp() async {
    try {
      await refresh();
      if (!_enabled || !_installed) return;
      final store = _store;
      if (store == null) return;
      final dir = await store.modelDirPath();
      await _loadBackend(dir);
    } catch (e) {
      debugPrint('[asr+] 预热失败：$e');
    }
  }

  /// 开放式识别。未启用/未就绪/任何异常 → null，调用方继续 Vosk。
  Future<VoskResult?> transcribeOpen(String wavPath) async {
    if (!_enabled) return null;
    try {
      if (_backend?.isLoaded != true) {
        await refresh();
        if (!_installed) return null;
        final store = _store;
        if (store == null) return null;
        final dir = await store.modelDirPath();
        if (!await _loadBackend(dir)) return null;
      }
      final text = await _backend!.transcribe(wavPath);
      return VoskResult(text, null);
    } catch (e) {
      _lastError = '增强识别失败，已回落 Vosk';
      debugPrint('[asr+] 识别失败：$e');
      _emit();
      return null;
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:vosk_flutter/vosk_flutter.dart' as vosk;

import 'vosk_model.dart';

/// Vosk 识别结果：文本 + 置信度。
/// [confidence] = null 表示输出里**没有**置信度字段（Vosk 顶层默认不产出）——
/// 判定层须据此「以文本相似度为准」，禁止当成 0 拒判（P0 v1.2.3）。
class VoskResult {
  final String text;
  final double? confidence;
  const VoskResult(this.text, this.confidence);
}

/// 语音转写抽象：wav 音频 + 短语表 → 识别文本 + 置信度。
/// - 真实实现 [VoskTranscriber]（离线默认，随包内置，零配置可用）；
/// - 宿主单测可注入桩实现（宿主无法运行 Android 原生 libvosk）。
abstract class Transcriber {
  /// 初始化引擎；成功返回 true，失败置为不可用（上层据此走降级/报错）。
  Future<bool> init();

  /// 引擎是否就绪。
  bool get isReady;

  /// 引擎是否加载失败（用于 UI 明确报错，而非静默）。
  bool get failed;

  /// 将本地 wav（16k 单声道 PCM）转写为文本 + 置信度；phrases 限定识别范围。
  Future<VoskResult> transcribe(String wavPath, List<String> phrases);
}

/// 从 16 位单声道 WAV 提取 PCM 数据（跳过 RIFF 头，定位 'data' 子块）。
/// 兼容非标准 44 字节头（遍历 chunk）。
Uint8List pcmFromWav(Uint8List wav) {
  if (wav.length < 12 || wav[0] != 0x52 || wav[1] != 0x49 || // 'RI'
      wav[8] != 0x57 || wav[9] != 0x41) {
    // 'WA'（WAVE）
    return Uint8List(0);
  }
  final bd = ByteData.sublistView(wav);
  var pos = 12;
  while (pos + 8 <= wav.length) {
    final id = String.fromCharCodes(wav.sublist(pos, pos + 4));
    final size = bd.getUint32(pos + 4, Endian.little);
    if (id == 'data') {
      final start = pos + 8;
      final end = (start + size) <= wav.length ? start + size : wav.length;
      return Uint8List.sublistView(wav, start, end);
    }
    pos += 8 + size + (size & 1); // chunk 双字对齐
  }
  return Uint8List(0);
}

/// 从目标短语构建 Vosk 限定词表。
/// Vosk 词表必须是「单词」列表（插件会 jsonEncode 后交给 JSGF 解析器，
/// 整句短语会被当成单个非法词元 → 零识别）。这里拆词、归小写、去重。
List<String> voskGrammarWords(List<String> phrases) => <String>{
      for (final p in phrases)
        ...p
            .toLowerCase()
            .split(RegExp(r"[^a-z0-9']+"))
            .where((w) => w.isNotEmpty),
    }.toList();

/// 从内置 version.json 读取模型清单（v1.4.2 模型外移：唯一事实源在 version.json 的 model 段）。
///
/// 调试覆写（模拟通道，仅 E2E 取证用）：构建时传
/// `--dart-define=MODEL_BASE_URL=http://10.0.2.2:8899` 会把分块/整包 URL 重写到
/// 本地 harness；报告中注明「模拟通道」，不用于真实分发包。
Future<ModelManifest> loadDefaultModelManifest() async {
  final raw = await rootBundle.loadString('assets/version.json');
  final j = jsonDecode(raw) as Map<String, dynamic>;
  final m = j['model'];
  if (m is! Map) {
    throw const FormatException('version.json 缺少 model 段');
  }
  final manifest = ModelManifest.fromJson(m);
  if (!manifest.isValid) {
    throw const FormatException('version.json 的 model 段无效');
  }
  const base = String.fromEnvironment('MODEL_BASE_URL');
  if (base.isEmpty) return manifest;
  return ModelManifest(
    name: manifest.name,
    modelVersion: manifest.modelVersion,
    sha256: manifest.sha256,
    size: manifest.size,
    parts: [
      for (var i = 0; i < manifest.parts.length; i++)
        ModelPart('$base/model.part$i', manifest.parts[i].size,
            sha256: manifest.parts[i].sha256),
    ],
    mirrorUrl: '$base/${manifest.name}.zip',
  );
}

/// 真实 Vosk 转写实现（Android 走插件 MethodChannel 原生 libvosk）。
class VoskTranscriber implements Transcriber {
  vosk.Model? _model;
  bool _ready = false;
  bool _failed = false;

  // 延迟取插件实例：构造不触发 FFI 加载，宿主测试不会因缺 libvosk 崩溃。
  vosk.VoskFlutterPlugin get _plugin => vosk.VoskFlutterPlugin.instance();

  @override
  bool get isReady => _ready;

  @override
  bool get failed => _failed;

  /// 从外部解压目录加载模型（v1.4.2：模型已移出 assets，首启分块下载后落盘）。
  /// [modelPath] 为已解压的模型根目录；返回是否加载成功。
  Future<bool> loadModel(String modelPath) async {
    if (_ready) return true;
    try {
      _model = await _plugin.createModel(modelPath);
      _ready = true;
      _failed = false;
    } catch (_) {
      _ready = false;
      _failed = true;
    }
    return _ready;
  }

  @override
  Future<bool> init() async => _ready; // 兼容旧接口；实际编排由 SpeechEngine 完成

  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) async {
    if (!_ready || _model == null) return const VoskResult('', null);
    try {
      final wav = await File(wavPath).readAsBytes();
      final pcm = pcmFromWav(wav);
      if (pcm.isEmpty) return const VoskResult('', null);
      // 限定词表（单词列表，见 voskGrammarWords）。
      final words = voskGrammarWords(phrases);
      final constrained = await _runRecognizer(pcm, words);
      // 词表过严导致零结果时，回退到无约束全模型识别，避免误判“没听到”。
      if (constrained.text.trim().isNotEmpty) return constrained;
      return await _runRecognizer(pcm, null);
    } catch (_) {
      return const VoskResult('', null);
    }
  }

  /// 无约束识别（自由造句：用户自由开口，不限词表）。
  Future<VoskResult> transcribeFree(String wavPath) async {
    if (!_ready || _model == null) return const VoskResult('', null);
    try {
      final wav = await File(wavPath).readAsBytes();
      final pcm = pcmFromWav(wav);
      if (pcm.isEmpty) return const VoskResult('', null);
      return await _runRecognizer(pcm, null);
    } catch (_) {
      return const VoskResult('', null);
    }
  }

  /// 用给定词表（null=无约束）跑一次识别，返回文本 + 置信度。
  Future<VoskResult> _runRecognizer(Uint8List pcm, List<String>? grammar) async {
    final rec = await _plugin.createRecognizer(
      model: _model!,
      sampleRate: 16000,
      grammar: grammar,
    );
    const chunk = 4000; // ~0.125s @16kHz×2B
    for (var i = 0; i < pcm.length; i += chunk) {
      final end = (i + chunk) < pcm.length ? i + chunk : pcm.length;
      await rec.acceptWaveformBytes(Uint8List.sublistView(pcm, i, end));
    }
    final res = jsonDecode(await rec.getFinalResult()) as Map<String, dynamic>;
    await rec.dispose();
    final text = (res['text'] as String?) ?? '';
    return VoskResult(text, _parseConfidence(res));
  }
}

/// 解析 Vosk 结果里的置信度；**字段缺失返回 null**（而非 0），供判定层走文本相似度兜底。
/// 优先取顶层 `confidence`；若无则取词级 `result[].conf` 的平均（词级置信度需识别器显式开启）。
double? _parseConfidence(Map<String, dynamic> res) {
  final top = res['confidence'];
  if (top is num) return top.toDouble();
  final arr = res['result'];
  if (arr is List) {
    final confs = <double>[];
    for (final e in arr) {
      if (e is Map && e['conf'] is num) confs.add((e['conf'] as num).toDouble());
    }
    if (confs.isNotEmpty) {
      return confs.reduce((a, b) => a + b) / confs.length;
    }
  }
  return null;
}

/// 从 wav 文件估算录音时长（秒）：PCM 字节数 / 2 / 16000。
/// 供判定管线的「过短录音无效」防噪兜底使用；失败返回 0。
Future<double> wavDurationSec(String wavPath) async {
  try {
    final wav = await File(wavPath).readAsBytes();
    final pcm = pcmFromWav(wav);
    if (pcm.isEmpty) return 0;
    return pcm.length / 2 / 16000;
  } catch (_) {
    return 0;
  }
}

/// 识别引擎生命周期状态（六态：缺缺失态由 failed/unknown 表达）。
enum EngineState { unknown, downloading, extracting, loading, ready, failed }

/// 全局识别引擎：单例共享一次模型加载，SAY / L4 / 设置页共用，避免重复下载/解压 40MB 模型。
/// 实现 [Transcriber]，可直接作为 SpeechService 的默认转写器。
class SpeechEngine implements Transcriber {
  SpeechEngine._({ModelManager? manager, Future<bool> Function(String)? createModel})
      : _injectedManager = manager,
        _injectedCreateModel = createModel;

  /// 生产单例（真实 ModelManager + 真实 Vosk createModel）。
  static final SpeechEngine instance = SpeechEngine._();

  /// 测试工厂：注入假 ModelManager / 假 createModel（宿主无法运行原生 libvosk）。
  @visibleForTesting
  SpeechEngine.forTesting({
    ModelManager? manager,
    Future<bool> Function(String)? createModel,
  }) : this._(manager: manager, createModel: createModel);

  final ModelManager? _injectedManager;
  final Future<bool> Function(String)? _injectedCreateModel;
  final VoskTranscriber _impl = VoskTranscriber();

  EngineState _state = EngineState.unknown;
  Future<bool>? _inFlight;
  int _createModelFailures = 0;
  String? _lastError;
  ModelManifest? _manifest;
  ModelManager? _manager;

  EngineState get state => _state;

  /// 是否已加载（内存标志，进程生命周期内只初始化一次）。
  bool get isLoaded => _state == EngineState.ready;

  /// 最近一次失败原因（供 UI 展示可读提示）。
  String? get lastError => _lastError;

  /// 下载/解压进度流（供首启引导页展示 0.5% 节流进度 + 速度 + 剩余时间）。
  /// 需在 [init] 前调用，以拿到与 init 同一个 manager 的流，避免错过事件。
  Future<Stream<ModelProgress>> ensureProgressStream() async {
    final m = await _ensureManager();
    return m.progress;
  }

  /// 轻量检查：模型是否已解压到磁盘且 model.json 版本一致（不读 40MB 资产、不触发下载）。
  static Future<bool> modelOnDisk() async {
    try {
      final manifest = await loadDefaultModelManifest();
      return await ModelManager(manifest: manifest).isReady();
    } catch (_) {
      return false;
    }
  }

  @override
  bool get isReady => _state == EngineState.ready;

  @override
  bool get failed => _state == EngineState.failed;

  Future<ModelManager> _ensureManager() async {
    if (_injectedManager != null) return _injectedManager;
    if (_manager != null) return _manager!;
    _manifest ??= await loadDefaultModelManifest();
    _manager = ModelManager(manifest: _manifest!);
    return _manager!;
  }

  /// 用户点「重试」前调用：先删干净未完成分块/拼接临时文件/未就绪模型目录，
  /// 保证坏模型兜底重下在真机路径生效（B3）。
  Future<void> prepareRetry() async {
    final manager = await _ensureManager();
    await manager.resetIncomplete();
    _lastError = null;
    _createModelFailures = 0;
    _state = EngineState.unknown;
  }

  /// 并发保护：同一时刻只有一次初始化在途；重复调用等待同一次结果。
  @override
  Future<bool> init() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final f = _run().whenComplete(() => _inFlight = null);
    _inFlight = f;
    return f;
  }

  Future<bool> _run() async {
    if (_state == EngineState.ready) return true;
    final manager = await _ensureManager();
    StreamSubscription<ModelProgress>? sub;
    try {
      sub = manager.progress.listen((p) {
        _state = p.phase == ModelPhase.downloading
            ? EngineState.downloading
            : EngineState.extracting;
      });
      _state = EngineState.downloading;
      final modelPath = await manager.ensureModel();
      await sub.cancel();
      sub = null;

      _state = EngineState.loading;
      final ok = await (_injectedCreateModel ?? _impl.loadModel)(modelPath);
      if (ok) {
        _createModelFailures = 0;
        _lastError = null;
        _state = EngineState.ready;
        return true;
      }

      _createModelFailures++;
      if (_createModelFailures >= 2) {
        // 硬化④：createModel 连续失败 ≥2 次 → 视为模型损坏 → 回「缺失」全量重下。
        _createModelFailures = 0;
        await manager.discard();
        _lastError = '模型损坏，已重置，请重试下载';
      } else {
        _lastError = '模型加载失败，请重试';
      }
      _state = EngineState.failed;
      return false;
    } catch (e) {
      _lastError = e is ModelDownloadException ? e.message : '$e';
      _state = EngineState.failed;
      return false;
    } finally {
      await sub?.cancel();
    }
  }

  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) =>
      _impl.transcribe(wavPath, phrases);

  /// 无约束识别（自由造句用，不限词表）。
  Future<VoskResult> transcribeFree(String wavPath) =>
      _impl.transcribeFree(wavPath);
}

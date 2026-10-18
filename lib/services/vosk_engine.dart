import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:vosk_flutter/vosk_flutter.dart' as vosk;

/// Vosk 离线模型资源（随包内置 zip，构建期由 tools/fetch_vosk_model.py 落位）。
const String kVoskModelAsset = 'assets/vosk-model-small-en-us-0.15.zip';

/// 模型解压目录名（与 ModelLoader 默认行为一致：<docsDir>/models/<此名>）。
/// 仅用于设置页零资产状态检查，避免触发 41MB 资产加载。
const String _kVoskModelDirName = 'vosk-model-small-en-us-0.15';

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

  @override
  Future<bool> init() async {
    if (_ready) return true;
    try {
      final loader = vosk.ModelLoader();
      final modelPath = await loader.loadFromAssets(kVoskModelAsset);
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

/// 识别引擎生命周期状态（供 UI 可见化：就绪 / 失败 / 检测中）。
enum EngineState { unknown, loading, ready, failed }

/// 全局识别引擎：单例共享一次模型加载，SAY / L4 / 设置页共用，避免重复解压 40MB 模型。
/// 实现 [Transcriber]，可直接作为 SpeechService 的默认转写器。
class SpeechEngine implements Transcriber {
  SpeechEngine._();
  static final SpeechEngine instance = SpeechEngine._();
  final VoskTranscriber _impl = VoskTranscriber();
  EngineState _state = EngineState.unknown;

  EngineState get state => _state;

  /// 是否已加载（内存标志，进程生命周期内只初始化一次）。
  /// 设置页用它做零资产状态检查，不触发任何资产读取。
  bool get isLoaded => _state == EngineState.ready;

  /// 轻量检查：模型是否已解压到磁盘（不读 41MB 资产，仅查目录存在）。
  /// 供设置页状态展示，彻底移除 initState 触发模型加载 → 低端机内存尖峰退桌面（P0 根因）。
  static Future<bool> modelOnDisk() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return Directory(path.join(dir.path, 'models', _kVoskModelDirName))
          .existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  bool get isReady => _state == EngineState.ready;

  @override
  bool get failed => _state == EngineState.failed;

  @override
  Future<bool> init() async {
    if (_state == EngineState.ready) return true;
    // 加载中：等待在途的那次完成，避免 FTUE 与练习环节并发二次解压 41MB 资产。
    if (_state == EngineState.loading) {
      while (_state == EngineState.loading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return _state == EngineState.ready;
    }
    if (_state == EngineState.failed) return false;
    _state = EngineState.loading;
    final ok = await _impl.init();
    _state = ok ? EngineState.ready : EngineState.failed;
    return ok;
  }

  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) =>
      _impl.transcribe(wavPath, phrases);

  /// 无约束识别（自由造句用，不限词表）。
  Future<VoskResult> transcribeFree(String wavPath) =>
      _impl.transcribeFree(wavPath);
}


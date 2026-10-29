import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'audio_format.dart';
import 'crash_log.dart';

/// 麦克风权限预检结果（禁止静默失败）。
enum MicPerm { granted, denied, permanentlyDenied }

/// 真实录音（原生 AudioRecord → 16k 单声道 WAV）+ 实时采集电平 + 本地回放。
/// 通过 MethodChannel 调原生实现，规避 record 包在构建链路上的平台子包不兼容问题。
class RecordingService {
  static const MethodChannel _ch = MethodChannel('chunkspoke/recorder');
  static const EventChannel _levelCh = EventChannel('chunkspoke/recorder_level');

  /// 调试开关（默认关）：打开后每次停止录音都把 WAV 复制到应用文档目录
  /// `asr_debug/last.wav`，供复现与走查取证；不写日志、不上传。
  static bool keepLastWavForDebug = false;
  static String? lastDebugWavPath;

  /// 最近一次录音的实际格式（从 WAV 头读回来）。§30.3-8 三处采样率核对的
  /// Dart 端落点：不是 [kCaptureSampleRate] 就记一条 CrashLog，并把值透出给诊断行。
  static WavInfo? lastWavInfo;

  bool _available = false;
  MicPerm _perm = MicPerm.denied;
  DateTime? _startedAt;

  /// 显式权限预检：进入语音题前调用。
  /// - 已授予 → granted；
  /// - 未授予 → 弹系统权限框，授予则 granted，否则 denied；
  /// - 被永久拒绝 / 受限 → permanentlyDenied（上层必须引导到系统设置页）。
  Future<MicPerm> ensurePermission() async {
    try {
      var st = await Permission.microphone.status;
      if (st.isGranted) {
        _perm = MicPerm.granted;
        _available = true;
        return _perm;
      }
      if (st.isPermanentlyDenied || st.isRestricted) {
        _perm = MicPerm.permanentlyDenied;
        _available = false;
        return _perm;
      }
      st = await Permission.microphone.request();
      if (st.isGranted) {
        _perm = MicPerm.granted;
        _available = true;
      } else if (st.isPermanentlyDenied || st.isRestricted) {
        _perm = MicPerm.permanentlyDenied;
        _available = false;
      } else {
        _perm = MicPerm.denied;
        _available = false;
      }
    } catch (_) {
      _perm = MicPerm.denied;
      _available = false;
    }
    return _perm;
  }

  /// 兼容旧调用：返回是否可用。
  Future<bool> init() async => (await ensurePermission()) == MicPerm.granted;

  bool get available => _available;
  MicPerm get permission => _perm;

  /// 录音期间实时电平流（0..1 峰值）。UI 订阅它自检采集是否正常。
  Stream<double> get levels => _levelCh
      .receiveBroadcastStream()
      .map((e) => (e as num).toDouble().clamp(0.0, 1.0));

  /// 句首预卷（§30.3-2）：按下按钮时先「起采」，最多把按下到 [start] 之间的
  /// [kPreRollMs] 毫秒回灌进 WAV，避免句首弱读首词被切。
  ///
  /// 实现方式裁定：**提前起录（按下即起采）+ 原生环形缓冲**，不做页面级常驻热麦——
  /// 常驻会让系统麦克风指示灯整页常亮，与本产品「只在你按下时采集」的隐私取向冲突。
  /// 热麦窗口 = 按下到抬起之间（典型 <150ms），原生 3 秒无 [start] 自动释放。
  Future<bool> arm() async {
    if (!_available) return false;
    try {
      await _ch.invokeMethod('arm');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 松手/取消时释放已 armed 但没进入 [start] 的采集（幂等，可随时调）。
  Future<void> disarm() async {
    try {
      await _ch.invokeMethod('disarm');
    } catch (_) {}
  }

  Future<String?> start() async {
    if (!_available) return null;
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/say_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _ch.invokeMethod('start', path);
      _startedAt = DateTime.now();
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 自本次录音开始已采集的时长（用于 no-speech 2 秒宽限判定）。
  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  Future<String?> stop() async {
    try {
      final p = await _ch.invokeMethod('stop') as String?;
      _startedAt = null;
      if (p != null) {
        // 格式核对是旁路取证：录音已经落盘，读头失败/慢盘都不许拖住 UI 返回。
        unawaited(_checkWavFormat(p));
      }
      if (p != null && keepLastWavForDebug) await _copyDebugWav(p);
      return p;
    } catch (_) {
      _startedAt = null;
      return null;
    }
  }

  /// §30.3-8：把录制产物的真实格式读回来核对一次。不是 16k/单声道/16bit 就记档，
  /// 不抛异常——录音已经发生了，此刻崩掉只会让用户白说一遍。
  Future<void> _checkWavFormat(String path) async {
    try {
      final raf = await File(path).open();
      try {
        final head = await raf.read(1024);
        final info = parseWavHeader(Uint8List.fromList(head));
        lastWavInfo = info;
        if (info == null) {
          CrashLog.write('RecordingService: WAV 头解析失败 $path',
              StackTrace.current);
        } else if (!info.isCaptureFormat) {
          CrashLog.write(
              'RecordingService: 采集格式不符 $info（期望 ${kCaptureSampleRate}Hz/1ch/16bit）',
              StackTrace.current);
        }
      } finally {
        await raf.close();
      }
    } catch (e, st) {
      CrashLog.write('RecordingService._checkWavFormat: $e', st);
    }
  }

  Future<void> _copyDebugWav(String path) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final targetDir = Directory('${dir.path}/asr_debug');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);
      final target = '${targetDir.path}/last.wav';
      await File(path).copy(target);
      lastDebugWavPath = target;
    } catch (_) {}
  }

  /// 分享录音时的固定说明（用户自己确认后再发出去）。
  static const String kShareText = '你刚才的录音，分享前自行确认';

  /// §拾音-分享（最小形态）：只分享**最近一次**留存的录音，走系统分享面板。
  ///
  /// - 来源唯一：[lastDebugWavPath]（进程内），重启后回落到
  ///   `文档/asr_debug/last.wav`，仍是「最近一次留存」那一份；
  /// - 先复制到 `cache/share/recording.wav` 再分享：FileProvider 只暴露这个
  ///   子目录，不为了一次分享把整个文档/缓存目录开放出去；
  /// - 返回值只表示「面板叫起来了」，不代表用户真的发出去了。
  static Future<bool> shareLast() async {
    try {
      final src = await _latestDebugWav();
      if (src == null) return false;
      final dir = await getTemporaryDirectory();
      final shareDir = Directory('${dir.path}/share');
      if (!await shareDir.exists()) await shareDir.create(recursive: true);
      final dst = '${shareDir.path}/recording.wav';
      await File(src).copy(dst);
      await _ch.invokeMethod('share', {'path': dst, 'text': kShareText});
      return true;
    } catch (e, st) {
      CrashLog.write('RecordingService.shareLast: $e', st);
      return false;
    }
  }

  /// 最近一次留存的排障录音；没有则 null（不是错误）。
  static Future<String?> _latestDebugWav() async {
    final mem = lastDebugWavPath;
    if (mem != null && await File(mem).exists()) return mem;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final p = '${dir.path}/asr_debug/last.wav';
      return await File(p).exists() ? p : null;
    } catch (_) {
      return null;
    }
  }

  /// 回放本地录音（降级路径“录音自听”）。
  Future<void> play(String path) async {
    try {
      await _ch.invokeMethod('play', path);
    } catch (_) {}
  }

  Future<void> stopPlay() async {
    try {
      await _ch.invokeMethod('stopPlay');
    } catch (_) {}
  }

  /// 引导到系统设置页（永久拒绝时）。
  Future<void> openSettings() => openAppSettings();
}

/// 端点检测：检测到人声后，连续 [window] 静音自动触发 [onSilence]（只触发一次）。
/// 用来把环境音/尾音裁掉，避免 Vosk 对静音段硬解码。UI 在停止录音时须 [detach]。
///
/// 阈值与静音窗的默认值来自 [audio_format.dart] 的单一真源（§30.3-2 / §30.3-9）：
/// 静音窗 1200 ms 是「起调值」，放宽值必须由 #248 基准集选，不许拍脑袋。
class SilenceAutoStop {
  SilenceAutoStop({
    required this.onSilence,
    this.threshold = kSilenceThreshold,
    this.window = const Duration(milliseconds: kSilenceWindowMs),
  });

  final void Function() onSilence;
  final double threshold;
  final Duration window;

  StreamSubscription<double>? _sub;
  Timer? _timer;
  DateTime? _lastVoiceAt;
  bool _fired = false;

  void attach(Stream<double> levels) {
    detach();
    _fired = false;
    _sub = levels.listen(_onLevel, onError: (_) {});
  }

  void _onLevel(double v) {
    if (v < threshold) return;
    _lastVoiceAt = DateTime.now();
    _timer ??= Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _tick() {
    if (_fired) return;
    final last = _lastVoiceAt;
    if (last == null) return;
    if (DateTime.now().difference(last) < window) return;
    _fired = true;
    detach();
    onSilence();
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _lastVoiceAt = null;
  }
}

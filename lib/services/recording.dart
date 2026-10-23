import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

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
      if (p != null && keepLastWavForDebug) await _copyDebugWav(p);
      return p;
    } catch (_) {
      _startedAt = null;
      return null;
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
class SilenceAutoStop {
  SilenceAutoStop({
    required this.onSilence,
    this.threshold = 0.06,
    this.window = const Duration(milliseconds: 1200),
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

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
      return p;
    } catch (_) {
      _startedAt = null;
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

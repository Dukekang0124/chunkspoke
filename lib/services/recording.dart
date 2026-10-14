import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 真实录音（原生 AudioRecord → 16k 单声道 WAV），供 Azure 发音评测使用。
/// 通过 MethodChannel 调原生实现，规避 record 包在构建链路上的平台子包不兼容问题。
class RecordingService {
  static const MethodChannel _ch = MethodChannel('chunkspoke/recorder');
  bool _available = false;

  Future<bool> init() async {
    try {
      var st = await Permission.microphone.status;
      if (!st.isGranted) st = await Permission.microphone.request();
      _available = st.isGranted;
    } catch (_) {
      _available = false;
    }
    return _available;
  }

  bool get available => _available;

  Future<String?> start() async {
    if (!_available) return null;
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/say_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _ch.invokeMethod('start', path);
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> stop() async {
    try {
      return await _ch.invokeMethod('stop') as String?;
    } catch (_) {
      return null;
    }
  }
}

import 'package:flutter/services.dart';

import 'hd_voice_types.dart';

/// 原生 MediaPlayer 播放 WAV（22050 Hz 单声道 16-bit）。
/// 不用第三方播放插件：项目已有 MainActivity 原生通道，这里只加一个独立实例。
class MethodChannelHdVoicePlayer implements HdVoicePlayer {
  static const MethodChannel _channel = MethodChannel('chunkspoke/voice');

  @override
  Future<void> playWav(String path) async {
    await _channel.invokeMethod<void>('playWav', {'path': path});
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<void> dispose() => stop();
}

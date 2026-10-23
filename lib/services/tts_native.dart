import 'package:flutter/services.dart';

/// 系统 TTS 设置 / 应用商店跳转（Android 原生 MethodChannel）。
/// 失败返回 false，由调用方给出可见提示，绝不静默。
class TtsNative {
  static const MethodChannel _ch = MethodChannel('chunkspoke/tts');

  static Future<bool> openSettings() async {
    try {
      return await _ch.invokeMethod<bool>('openSettings') == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openStore(String query) async {
    try {
      return await _ch.invokeMethod<bool>('openStore', query) == true;
    } catch (_) {
      return false;
    }
  }
}

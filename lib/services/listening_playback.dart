import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 磨耳朵后台播放桥：前台服务、通知栏与锁屏动作。
///
/// 音频仍由 Dart 侧 just_audio / flutter_tts 播放；本桥只让系统知道
/// 正在播放、并回传通知栏/锁屏的 play / pause / next / prev / stop。
/// 任何通道失败都静默降级，不影响收听本身。
class ListeningPlayback {
  ListeningPlayback._();
  static final ListeningPlayback instance = ListeningPlayback._();

  static const MethodChannel _methods =
      MethodChannel('chunkspoke/listening_playback');
  static const EventChannel _events =
      EventChannel('chunkspoke/listening_playback_events');

  StreamSubscription<dynamic>? _sub;
  String? _lastSignature;
  bool _started = false;

  /// 通知栏/锁屏动作回调；由当前播放器注册。
  void Function(String action)? onAction;

  bool get supported => Platform.isAndroid;

  void _ensureEvents() {
    if (!supported || _sub != null) return;
    _sub = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is String) onAction?.call(event);
      },
      onError: (_) {},
    );
  }

  Future<void> sync({
    required String title,
    required String scene,
    required bool playing,
    required bool precise,
    required int index,
    required int total,
    required int positionMs,
    required double speed,
  }) async {
    if (!supported) return;
    final payload = <String, Object?>{
      'title': title,
      'scene': scene,
      'playing': playing,
      'precise': precise,
      'index': index,
      'total': total,
      'positionMs': positionMs,
      'speed': speed,
    };
    final signature = jsonEncode(payload);
    if (_started && signature == _lastSignature) return;
    _ensureEvents();
    try {
      final ok = await _methods.invokeMethod<bool>(
        _started ? 'update' : 'start',
        payload,
      );
      // 原生明确拒绝（前台服务不可用）时，下次退回 start 重试。
      if (ok == false) throw StateError('foreground service unavailable');
      _started = true;
      _lastSignature = signature;
    } catch (_) {
      // 前台服务不可用时回到应用内收听，不向上抛。
      _started = false;
      _lastSignature = null;
    }
  }

  Future<void> stop() async {
    if (!supported) return;
    _started = false;
    _lastSignature = null;
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {}
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    onAction = null;
    _started = false;
    _lastSignature = null;
  }
}

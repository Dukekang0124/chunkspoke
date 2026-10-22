import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'hd_voice_types.dart';

class HdVoiceException implements Exception {
  final String message;
  const HdVoiceException(this.message);
  @override
  String toString() => 'HdVoiceException: $message';
}

/// 在独立 isolate 里跑 VITS 推理：63MB 模型加载与合成都不阻塞 UI。
/// 每个 isolate 需各自 initBindings（sherpa-onnx 的 FFI 绑定不跨 isolate）。
class IsolateHdVitsEngine implements HdVoiceSynth {
  IsolateHdVitsEngine({this.numThreads = 2});

  final int numThreads;
  Isolate? _isolate;
  ReceivePort? _port;
  StreamSubscription<dynamic>? _sub;
  SendPort? _toWorker;
  Completer<void>? _ready;
  final Map<int, Completer<HdAudio>> _pending = {};
  int _nextId = 1;
  bool _up = false;
  bool _disposed = false;
  Future<void>? _starting;

  @override
  Future<void> init(String modelDir) {
    if (_up) return Future<void>.value();
    return _starting ??= _start(modelDir)
        .whenComplete(() => _starting = null);
  }

  Future<void> _start(String modelDir) async {
    await _teardown();
    if (_disposed) throw const HdVoiceException('engine disposed');
    final port = ReceivePort();
    _port = port;
    final ready = Completer<void>();
    _ready = ready;
    _sub = port.listen((msg) {
      if (msg is! Map) return;
      switch (msg['kind']) {
        case 'port':
          final worker = msg['port'];
          if (worker is! SendPort) return;
          _toWorker = worker;
          worker.send({
            'cmd': 'init',
            'modelDir': modelDir,
            'numThreads': numThreads,
          });
        case 'ready':
          _up = true;
          if (!ready.isCompleted) ready.complete();
        case 'initError':
          if (!ready.isCompleted) {
            ready.completeError(HdVoiceException('${msg['error']}'));
          }
        case 'audio':
          final id = msg['id'];
          final samples = msg['samples'];
          final rate = msg['sampleRate'];
          if (id is int && samples is Float32List && rate is int) {
            _pending.remove(id)?.complete(HdAudio(samples, rate));
          }
        case 'synthError':
          final id = msg['id'];
          if (id is int) {
            _pending
                .remove(id)
                ?.completeError(HdVoiceException('${msg['error']}'));
          }
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _voiceWorker,
        port.sendPort,
        errorsAreFatal: true,
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      await ready.future.timeout(const Duration(seconds: 45));
    } catch (e) {
      debugPrint('[hd-voice] engine init failed: $e');
      await _teardown();
      rethrow;
    }
  }

  @override
  Future<HdAudio> synthesize(String text, {required double speed}) async {
    final worker = _toWorker;
    if (!_up || worker == null) {
      throw const HdVoiceException('engine not ready');
    }
    final id = _nextId++;
    final c = Completer<HdAudio>();
    _pending[id] = c;
    worker.send({'cmd': 'synth', 'id': id, 'text': text, 'speed': speed});
    try {
      return await c.future.timeout(const Duration(seconds: 60));
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _toWorker?.send({'cmd': 'quit'});
    await _teardown();
  }

  Future<void> _teardown() async {
    _up = false;
    _toWorker = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(const HdVoiceException('engine stopped'));
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const HdVoiceException('engine stopped'));
    }
    _pending.clear();
    await _sub?.cancel();
    _sub = null;
    _port?.close();
    _port = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

void _voiceWorker(SendPort main) {
  final recv = ReceivePort();
  main.send({'kind': 'port', 'port': recv.sendPort});
  sherpa.OfflineTts? tts;
  recv.listen((msg) {
    if (msg is! Map) return;
    switch (msg['cmd']) {
      case 'init':
        try {
          sherpa.initBindings();
          final root = msg['modelDir'] as String;
          tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
            model: sherpa.OfflineTtsModelConfig(
              vits: sherpa.OfflineTtsVitsModelConfig(
                model: '$root/model.onnx',
                tokens: '$root/tokens.txt',
                dataDir: '$root/espeak-ng-data',
              ),
              numThreads: (msg['numThreads'] as int?) ?? 2,
              debug: false,
            ),
          ));
          main.send({'kind': 'ready'});
        } catch (e) {
          main.send({'kind': 'initError', 'error': '$e'});
        }
      case 'synth':
        final id = msg['id'];
        try {
          final a = tts?.generate(
            text: msg['text'] as String,
            sid: 0,
            speed: (msg['speed'] as num).toDouble(),
          );
          if (a == null) throw StateError('model not loaded');
          main.send({
            'kind': 'audio',
            'id': id,
            'samples': a.samples,
            'sampleRate': a.sampleRate,
          });
        } catch (e) {
          main.send({'kind': 'synthError', 'id': id, 'error': '$e'});
        }
      case 'quit':
        tts?.free();
        tts = null;
        recv.close();
    }
  });
}

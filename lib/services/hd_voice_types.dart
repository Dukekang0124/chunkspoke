import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'vosk_model.dart';

/// 高清发音包合成结果（22050 Hz 单声道 Float32）。
class HdAudio {
  final Float32List samples;
  final int sampleRate;
  const HdAudio(this.samples, this.sampleRate);
}

/// TtsService 只依赖这一层：判定是否接管发音、发声、停止。
abstract class HdVoiceSpeaker {
  bool get active;
  Future<bool> speak(String text);
  Future<void> stop();
}

abstract class HdVoiceSynth {
  Future<void> init(String modelDir);
  Future<HdAudio> synthesize(String text, {required double speed});
  Future<void> dispose();
}

abstract class HdVoicePlayer {
  Future<void> playWav(String path);
  Future<void> stop();
  Future<void> dispose();
}

/// 包一层 ModelManager：下载/校验/解压/续传/清场全部沿用 B3 硬化链。
abstract class HdVoiceDownloader {
  Stream<ModelProgress> get progress;
  Future<bool> isReady();
  Future<String> modelDirPath();
  Future<String> ensureModel();
  Future<void> resetIncomplete();
  Future<void> discard();
  void dispose();
}

class ManagerHdVoiceDownloader implements HdVoiceDownloader {
  ManagerHdVoiceDownloader(this._manager);
  final ModelManager _manager;

  @override
  Stream<ModelProgress> get progress => _manager.progress;

  @override
  Future<bool> isReady() => _manager.isReady();

  @override
  Future<String> modelDirPath() => _manager.modelDirPath();

  @override
  Future<String> ensureModel() => _manager.ensureModel();

  @override
  Future<void> resetIncomplete() => _manager.resetIncomplete();

  @override
  Future<void> discard() => _manager.discard();

  @override
  void dispose() => _manager.dispose();
}

String friendlyHdError(Object e) {
  if (e is ModelDownloadException) return e.message;
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('ClientException')) {
    return '无法连接下载服务器，请检查网络后重试';
  }
  if (s.contains('TimeoutException')) return '下载超时，请检查网络后重试';
  return '高清发音包处理失败，请重试';
}

/// version.json 的 voiceModel 段 → ModelManifest。
///
/// `--dart-define=VOICE_MODEL_BASE_URL=http://10.0.2.2:8899` 仅用于 E2E 本地
/// 模拟通道：分块改写到 `<base>/voice.partN`，整包改写到 `<base>/<name>.zip`。
ModelManifest parseHdVoiceManifest(String raw, {String base = ''}) {
  final v = jsonDecode(raw);
  if (v is! Map<String, dynamic>) {
    throw const FormatException('version.json 不是对象');
  }
  final m = v['voiceModel'];
  if (m is! Map) throw const FormatException('version.json 缺少 voiceModel 段');
  final manifest = ModelManifest.fromJson(m);
  if (!manifest.isValid) {
    throw const FormatException('version.json 的 voiceModel 段无效');
  }
  if (base.isEmpty) return manifest;
  return ModelManifest(
    name: manifest.name,
    modelVersion: manifest.modelVersion,
    sha256: manifest.sha256,
    size: manifest.size,
    parts: [
      for (var i = 0; i < manifest.parts.length; i++)
        ModelPart('$base/voice.part$i', manifest.parts[i].size,
            sha256: manifest.parts[i].sha256),
    ],
    mirrorUrl: '$base/${manifest.name}.zip',
  );
}

Future<ModelManifest> loadHdVoiceManifest() async {
  final raw = await rootBundle.loadString('assets/version.json');
  return parseHdVoiceManifest(raw,
      base: const String.fromEnvironment('VOICE_MODEL_BASE_URL'));
}

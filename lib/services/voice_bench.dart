import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'hd_voice_types.dart';

/// 单个音色的真机性能基准。
///
/// RTF（实时率）= 合成耗时 / 音频时长；连续朗读时 RTF 必须明显低于 1，
/// 本项目按低端机连读节奏把门槛定为 0.5，超过即淘汰该音色。
class VoiceBenchResult {
  const VoiceBenchResult({
    required this.voiceId,
    required this.loadMs,
    required this.firstSynthMs,
    required this.steadySynthMs,
    required this.audioSecs,
    required this.sampleRate,
    required this.rssMb,
    required this.text,
    required this.speed,
  });

  static const double kMaxRtf = 0.5;

  final String voiceId;
  final int loadMs;
  final int firstSynthMs;
  final int steadySynthMs;
  final double audioSecs;
  final int sampleRate;
  final int rssMb;
  final String text;
  final double speed;

  /// 冷启动首音延迟：引擎加载 + 首次合成，对应「刚打开应用第一次朗读」。
  int get coldFirstAudioMs => loadMs + firstSynthMs;

  /// 引擎已加载后的首音延迟（稳态）。
  int get warmFirstAudioMs => steadySynthMs;

  double get rtf =>
      audioSecs <= 0 ? double.infinity : steadySynthMs / 1000 / audioSecs;

  bool get pass => rtf <= kMaxRtf;

  Map<String, dynamic> toJson() => {
        'voice': voiceId,
        'loadMs': loadMs,
        'firstSynthMs': firstSynthMs,
        'steadySynthMs': steadySynthMs,
        'coldFirstAudioMs': coldFirstAudioMs,
        'warmFirstAudioMs': warmFirstAudioMs,
        'audioSecs': double.parse(audioSecs.toStringAsFixed(3)),
        'rtf': double.parse(rtf.toStringAsFixed(3)),
        'rssMb': rssMb,
        'sampleRate': sampleRate,
        'speed': speed,
        'text': text,
        'threshold': kMaxRtf,
        'verdict': pass ? 'keep' : 'drop',
      };
}

/// 在设备上跑一段固定文本：加载一次、连续合成两次（第一次测首音，第二次测稳态 RTF）。
/// 调用方负责 dispose 传入的 synth（基准结束即释放，避免占内存）。
class VoiceBench {
  static const String kText =
      "I'd like a cup of coffee and a piece of cake, please. "
      'The weather is nice today.';

  static Future<VoiceBenchResult> run({
    required HdVoiceSynth synth,
    required String voiceId,
    required String modelDir,
    String text = kText,
    double speed = 0.58,
  }) async {
    final load = Stopwatch()..start();
    await synth.init(modelDir);
    load.stop();

    final first = Stopwatch()..start();
    await synth.synthesize(text, speed: speed);
    first.stop();

    final steady = Stopwatch()..start();
    final audio = await synth.synthesize(text, speed: speed);
    steady.stop();

    final secs =
        audio.sampleRate > 0 ? audio.samples.length / audio.sampleRate : 0.0;
    return VoiceBenchResult(
      voiceId: voiceId,
      loadMs: load.elapsedMilliseconds,
      firstSynthMs: first.elapsedMilliseconds,
      steadySynthMs: steady.elapsedMilliseconds,
      audioSecs: secs,
      sampleRate: audio.sampleRate,
      rssMb: currentRssMb(),
      text: text,
      speed: speed,
    );
  }

  /// 当前进程常驻内存（MB）；平台不支持时返回 0。
  static int currentRssMb() {
    try {
      return ProcessInfo.currentRss ~/ (1024 * 1024);
    } catch (_) {
      return 0;
    }
  }

  /// 结果写入应用文档目录（未显式给目录时），返回文件绝对路径。
  static Future<String> writeResults(
    List<VoiceBenchResult> results, {
    Directory? dir,
    DateTime Function()? clock,
  }) async {
    final base = dir ?? await getApplicationDocumentsDirectory();
    await base.create(recursive: true);
    final f = File('${base.path}/voice_bench.json');
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'generatedAt': (clock ?? DateTime.now)().toIso8601String(),
        'threshold': VoiceBenchResult.kMaxRtf,
        'results': [for (final r in results) r.toJson()],
      }),
      flush: true,
    );
    return f.path;
  }
}

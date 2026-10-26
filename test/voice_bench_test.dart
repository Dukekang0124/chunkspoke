import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/hd_voice_types.dart';
import 'package:chunkspoke_flutter/services/voice_bench.dart';

class _FakeSynth implements HdVoiceSynth {
  _FakeSynth(this.samplesPerCall);
  final int samplesPerCall;
  String? dir;
  int initCalls = 0;
  int synthCalls = 0;
  double? lastSpeed;
  String? lastText;

  @override
  Future<void> init(String modelDir) async {
    initCalls++;
    dir = modelDir;
  }

  @override
  Future<HdAudio> synthesize(String text, {required double speed}) async {
    synthCalls++;
    lastText = text;
    lastSpeed = speed;
    return HdAudio(Float32List(samplesPerCall), 22050);
  }

  @override
  Future<void> dispose() async {}
}

VoiceBenchResult _result({
  int steadyMs = 400,
  double audioSecs = 1.0,
  int loadMs = 900,
  int firstMs = 700,
  int rssMb = 180,
}) =>
    VoiceBenchResult(
      voiceId: 'voice-a',
      loadMs: loadMs,
      firstSynthMs: firstMs,
      steadySynthMs: steadyMs,
      audioSecs: audioSecs,
      sampleRate: 22050,
      rssMb: rssMb,
      text: VoiceBench.kText,
      speed: 0.58,
    );

void main() {
  group('自然人声基准', () {
    test('RTF 计算与 0.5 淘汰线', () {
      final ok = _result(steadyMs: 400, audioSecs: 1.0);
      expect(ok.rtf, closeTo(0.4, 1e-9));
      expect(ok.pass, isTrue);

      final slow = _result(steadyMs: 600, audioSecs: 1.0);
      expect(slow.rtf, closeTo(0.6, 1e-9));
      expect(slow.pass, isFalse);

      final zero = _result(audioSecs: 0);
      expect(zero.rtf.isInfinite, isTrue);
      expect(zero.pass, isFalse);
    });

    test('冷/热首音与 JSON 口径', () {
      final r = _result(loadMs: 900, firstMs: 700, steadyMs: 400);
      expect(r.coldFirstAudioMs, 1600);
      expect(r.warmFirstAudioMs, 400);
      final j = r.toJson();
      expect(j['voice'], 'voice-a');
      expect(j['rtf'], 0.4);
      expect(j['verdict'], 'keep');
      expect(j['threshold'], 0.5);
      expect(_result(steadyMs: 900).toJson()['verdict'], 'drop');
    });

    test('run 采集：加载一次、合成两次，记录文本与语速', () async {
      final synth = _FakeSynth(22050); // 1.0s 音频
      final r = await VoiceBench.run(
        synth: synth,
        voiceId: 'voice-b',
        modelDir: '/models/voice-b',
        speed: 0.58,
      );
      expect(synth.initCalls, 1);
      expect(synth.dir, '/models/voice-b');
      expect(synth.synthCalls, 2);
      expect(synth.lastText, VoiceBench.kText);
      expect(synth.lastSpeed, 0.58);
      expect(r.voiceId, 'voice-b');
      expect(r.audioSecs, closeTo(1.0, 1e-9));
      expect(r.sampleRate, 22050);
      expect(r.loadMs, greaterThanOrEqualTo(0));
      expect(r.rtf, greaterThanOrEqualTo(0));
      expect(r.rssMb, greaterThanOrEqualTo(0));
    });

    test('writeResults 落盘 JSON', () async {
      final dir = await Directory.systemTemp.createTemp('voice_bench');
      final out = await VoiceBench.writeResults(
        [_result(), _result(steadyMs: 900)],
        dir: dir,
        clock: () => DateTime.utc(2026, 10, 26, 12),
      );
      final f = File(out);
      expect(f.existsSync(), isTrue);
      expect(f.path, '${dir.path}/voice_bench.json');
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(j['generatedAt'], '2026-10-26T12:00:00.000Z');
      expect(j['threshold'], 0.5);
      final rs = j['results'] as List;
      expect(rs.length, 2);
      expect((rs[0] as Map)['verdict'], 'keep');
      expect((rs[1] as Map)['verdict'], 'drop');
      await dir.delete(recursive: true);
    });
  });
}

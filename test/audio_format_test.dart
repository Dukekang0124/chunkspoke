import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/audio_format.dart';

/// §30.3-8「16 kHz 三处对齐」的守门测试：
///  - 行为侧：WAV 头解析（真实录音产物读回来的依据）；
///  - 结构侧：源码里不许再出现第二份采样率真源（裸 16000），
///    原生常量必须与 Dart 单一真源一致。
///
/// 说明：这里刻意读源码做断言，而不是「跑一遍录音」——单测环境没有麦克风。
/// 录真音属于 E2E/真机走查，不在本文件的证据范围内。

Uint8List _wav({
  int sampleRate = 16000,
  int channels = 1,
  int bits = 16,
  int dataBytes = 32000,
  String extraChunk = '',
}) {
  final body = BytesBuilder();
  void u32(int v) => body.add(
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) => body.add(
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());

  body.add('WAVE'.codeUnits);
  // fmt chunk：16 字节 PCM 格式块。
  body.add('fmt '.codeUnits);
  u32(16);
  u16(1); // PCM
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * channels * (bits ~/ 8)); // byteRate
  u16(channels * (bits ~/ 8)); // blockAlign
  u16(bits);
  // 可选的填充块（验证奇数长度 padding 处理）
  if (extraChunk.isNotEmpty) {
    final bytes = extraChunk.codeUnits;
    body.add('LIST'.codeUnits);
    u32(bytes.length);
    body.add(bytes);
    if (bytes.length.isOdd) body.addByte(0); // RIFF 奇数块要补 1 字节
  }
  // data chunk：按声明长度真的放满，保证时长换算与真实文件一致。
  body.add('data'.codeUnits);
  u32(dataBytes);
  body.add(Uint8List(dataBytes));
  final rest = body.takeBytes();

  final out = BytesBuilder();
  out.add('RIFF'.codeUnits);
  out.add((ByteData(4)..setUint32(0, 4 + rest.length, Endian.little))
      .buffer
      .asUint8List());
  out.add(rest);
  return out.takeBytes();
}

void main() {
  group('WavInfo 解析', () {
    test('采集格式（16k/单声道/16bit）解析正确，时长按采样率折算', () {
      final info = parseWavHeader(_wav(dataBytes: 32000))!;
      expect(info.sampleRate, 16000);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      expect(info.dataBytes, 32000);
      // 32000 字节 / (16000 × 1 × 2 字节) = 1.0 秒
      expect(info.durationSec, closeTo(1.0, 1e-9));
      expect(info.isCaptureFormat, isTrue);
    });

    test('非采集格式要能识别出来（而不是被当成 16k 静默放过）', () {
      final info = parseWavHeader(
          _wav(sampleRate: 44100, channels: 2, dataBytes: 176400))!;
      expect(info.sampleRate, 44100);
      expect(info.channels, 2);
      expect(info.isCaptureFormat, isFalse);
    });

    test('fmt 前有奇数长度填充块也能定位到 data', () {
      final info = parseWavHeader(_wav(extraChunk: 'abc'))!; // 3 字节 + 1 字节 pad
      expect(info.sampleRate, 16000);
      expect(info.dataBytes, 32000);
    });

    test('坏头/空数据返回 null，不抛异常', () {
      expect(parseWavHeader(Uint8List(0)), isNull);
      expect(parseWavHeader(Uint8List.fromList('not a wav'.codeUnits)), isNull);
      final truncated = _wav().sublist(0, 20);
      expect(parseWavHeader(Uint8List.fromList(truncated)), isNull);
    });
  });

  group('§30.3-8 单一真源守门', () {
    File src(String p) => File(p);

    test('Dart 服务层不许再出现裸 16000', () {
      // 先剥掉注释：注释里提到数字不算第二份真源。
      String stripComments(String s) => s
          .split('\n')
          .map((l) {
            final i = l.indexOf('//');
            return i >= 0 ? l.substring(0, i) : l;
          })
          .join('\n');

      for (final p in [
        'lib/services/speech.dart',
        'lib/services/vosk_engine.dart',
        'lib/services/recording.dart',
        'lib/services/audio_format.dart',
      ]) {
        final text = stripComments(src(p).readAsStringSync());
        // audio_format.dart 自己就是真源，允许一次定义。
        final allowed = p.endsWith('audio_format.dart') ? 1 : 0;
        final hits = '16000'.allMatches(text).length;
        expect(hits, allowed, reason: '$p 里 16000 出现 $hits 次（应 $allowed 次）');
      }
    });

    test('原生 CAPTURE_RATE 与 Dart 单一真源一致', () {
      final kt = src('android/app/src/main/kotlin/com/chunkspoke/app/MainActivity.kt')
          .readAsStringSync();
      final m = RegExp(r'const val CAPTURE_RATE\s*=\s*(\d+)').firstMatch(kt);
      expect(m, isNotNull, reason: 'MainActivity.kt 必须定义 CAPTURE_RATE');
      expect(int.parse(m!.group(1)!), kCaptureSampleRate);
      // 预卷窗口也必须与 Dart 侧同值，避免「原生 400ms / 文档 300ms」这类漂移。
      final pr = RegExp(r'const val PRE_ROLL_MS\s*=\s*(\d+)').firstMatch(kt);
      expect(pr, isNotNull, reason: 'MainActivity.kt 必须定义 PRE_ROLL_MS');
      expect(int.parse(pr!.group(1)!), kPreRollMs);
    });

    test('原生采集链路具备 §30.3-1/2 的关键接线', () {
      final kt = src('android/app/src/main/kotlin/com/chunkspoke/app/MainActivity.kt')
          .readAsStringSync();
      expect(kt.contains('VOICE_RECOGNITION'), isTrue,
          reason: '§30.3-1 必须用 VOICE_RECOGNITION，不用 DEFAULT/MIC');
      expect(kt.contains('"arm"'), isTrue);
      expect(kt.contains('"disarm"'), isTrue);
      expect(kt.contains('drainRingTo('), isTrue, reason: '预卷缓冲必须回灌进 WAV');
    });
  });
}

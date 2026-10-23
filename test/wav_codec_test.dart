import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/wav_codec.dart';

/// 构造任意声道/位深/附加块的 WAV，验证解析不依赖「16-bit 单声道」假设。
Uint8List _wav({
  required int sampleRate,
  required int channels,
  required int bits,
  required int frames,
  List<List<int>> leadingChunks = const [],
}) {
  final blockAlign = channels * bits ~/ 8;
  final byteRate = sampleRate * blockAlign;
  final dataBytes = frames * blockAlign;

  final chunks = <List<int>>[
    ...leadingChunks,
    [
      ..._ascii('fmt '),
      ...[16, 0, 0, 0],
      ...[1, 0], // PCM
      ...[channels & 0xff, channels >> 8],
      ..._u32(sampleRate),
      ..._u32(byteRate),
      ...[blockAlign & 0xff, blockAlign >> 8],
      ...[bits & 0xff, bits >> 8],
    ],
    [..._ascii('data'), ..._u32(dataBytes)],
  ];

  final body = <int>[];
  for (final chunk in chunks) {
    body.addAll(chunk);
    if (chunk.length.isOdd) body.add(0); // chunk 偶数字节对齐
  }
  body.addAll(List.filled(dataBytes, 0));

  return Uint8List.fromList([
    ..._ascii('RIFF'),
    ..._u32(4 + body.length),
    ..._ascii('WAVE'),
    ...body,
  ]);
}

List<int> _ascii(String s) => [for (final c in s.codeUnits) c];
List<int> _u32(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  group('WAV 头时长解析', () {
    test('16-bit 单声道 8000Hz：0.5 秒', () {
      final bytes = _wav(
          sampleRate: 8000, channels: 1, bits: 16, frames: 4000);
      expect(wavDurationSecondsFromHeader(bytes), closeTo(0.5, 1e-9));
    });

    test('24-bit 立体声 44100Hz：按 byteRate 计算，不受位深影响', () {
      final bytes = _wav(
          sampleRate: 44100, channels: 2, bits: 24, frames: 22050);
      expect(wavDurationSecondsFromHeader(bytes), closeTo(0.5, 1e-9));
    });

    test('fmt 与 data 之间存在奇数长度块（需按偶数字节对齐）', () {
      final listChunk = [
        ..._ascii('LIST'),
        ...[3, 0, 0, 0],
        1, 2, 3, // 3 字节 → 尾部 1 字节 padding
      ];
      final bytes = _wav(
        sampleRate: 16000,
        channels: 1,
        bits: 16,
        frames: 8000,
        leadingChunks: [listChunk],
      );
      expect(wavDurationSecondsFromHeader(bytes), closeTo(0.5, 1e-9));
    });

    test('编码器产物（encodeWav）时长自洽', () {
      final samples = Float32List(11025);
      final bytes = encodeWav(samples, 22050);
      expect(wavDurationSecondsFromHeader(bytes), closeTo(0.5, 1e-9));
      expect(wavSeconds(samples, 22050), closeTo(0.5, 1e-9));
    });

    test('头部残缺/魔数不符返回 null，不猜时长', () {
      expect(wavDurationSecondsFromHeader(Uint8List(0)), isNull);
      expect(
          wavDurationSecondsFromHeader(
              Uint8List.fromList(_ascii('RIFFxxxxWAVE'))),
          isNull);
      final full =
          _wav(sampleRate: 8000, channels: 1, bits: 16, frames: 4000);
      expect(
          wavDurationSecondsFromHeader(Uint8List.sublistView(full, 0, 30)),
          isNull);
    });

    test('读取文件头：只读前 64KB 也能算出长文件时长', () async {
      final dir = await Directory.systemTemp.createTemp('wav_codec');
      final bytes = _wav(
          sampleRate: 8000, channels: 1, bits: 16, frames: 80000); // 10s
      final file = File('${dir.path}/long.wav');
      await file.writeAsBytes(bytes);
      expect(bytes.length, greaterThan(65536));
      expect(await readWavDurationSeconds(file), closeTo(10, 1e-9));
      expect(await readWavDurationSeconds(File('${dir.path}/missing.wav')),
          isNull);
      await dir.delete(recursive: true);
    });
  });
}

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Float32 [-1,1] 单声道采样 → 16-bit PCM WAV（MediaPlayer 直接可读）。
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final dataBytes = samples.length * 2;
  final out = Uint8List(44 + dataBytes);
  final bd = ByteData.sublistView(out);
  void tag(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out[offset + i] = s.codeUnitAt(i);
    }
  }

  tag(0, 'RIFF');
  bd.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, 1, Endian.little); // mono
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  bd.setUint16(32, 2, Endian.little); // block align
  bd.setUint16(34, 16, Endian.little); // bits per sample
  tag(36, 'data');
  bd.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    bd.setInt16(44 + i * 2, v, Endian.little);
  }
  return out;
}

Future<File> writeWavFile(
    File target, Float32List samples, int sampleRate) async {
  await target.parent.create(recursive: true);
  await target.writeAsBytes(encodeWav(samples, sampleRate), flush: true);
  return target;
}

/// 波形时长（秒），用于审计对账。
double wavSeconds(Float32List samples, int sampleRate) =>
    sampleRate <= 0 ? 0 : samples.length / sampleRate;

/// 峰值与 RMS：供取证脚本判断是否静音/削波，不做播放决策。
({double peak, double rms}) wavLevels(Float32List samples) {
  if (samples.isEmpty) return (peak: 0, rms: 0);
  var sum = 0.0;
  var peak = 0.0;
  for (final s in samples) {
    sum += s * s;
    peak = max(peak, s.abs());
  }
  return (peak: peak, rms: sqrt(sum / samples.length));
}

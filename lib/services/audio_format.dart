import 'dart:typed_data';

/// 采集链路格式的**单一真源**（§30.3-8：录制 → 送识别 → 评测三处采样率必须同源）。
///
/// 真源链：
///  - 原生 `MainActivity.CAPTURE_RATE` = 本文件 [kCaptureSampleRate]（Kotlin 侧写 WAV 头）；
///  - 识别 `vosk_engine.dart` 建识别器时传本常量；
///  - 评测 `speech.dart` 的 Azure 头 `samplerate=` 用本常量；
///  - `test/audio_format_test.dart` 有一条「源码里不许再出现裸 16000」的守门断言。
///
/// 改这里必须同步 `MainActivity.kt` 的 `CAPTURE_RATE`（守门测试会红）。
const int kCaptureSampleRate = 16000;

/// 句首预卷（毫秒）：按下即起采，最多把按下到「开始录音」之间的 [kPreRollMs] 回灌进 WAV。
/// 取值区间 300–500（§30.3-2），默认 400；与原生 `PRE_ROLL_MS` 同值。
const int kPreRollMs = 400;

/// 端点静音窗（毫秒）：连续静音超过它才自动停。§30.3-2 要求「1200 起调」，
/// 放宽值必须由基准集选（#248 回收样本后定标），**不许拍脑袋**——本轮保持 1200。
const int kSilenceWindowMs = 1200;

/// 端点/电平的「有声音」阈值（0..1 峰值）：低于它视为静音。
/// 与 §30.3-9 音量条共用同一阈值，保证「波形在动」与「不算静音」口径一致。
const double kSilenceThreshold = 0.06;

/// WAV（PCM）头解析结果。只解析常规 44 字节头（本 App 自己写的就是这种）。
class WavInfo {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataBytes;

  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataBytes,
  });

  /// 时长（秒）：dataBytes / (采样率 × 声道 × 位深/8)。
  double get durationSec {
    final perSec = sampleRate * channels * (bitsPerSample ~/ 8);
    return perSec <= 0 ? 0 : dataBytes / perSec;
  }

  bool get isCaptureFormat =>
      sampleRate == kCaptureSampleRate && channels == 1 && bitsPerSample == 16;

  @override
  String toString() =>
      'WavInfo($sampleRate Hz, $channels ch, $bitsPerSample bit, $dataBytes B)';
}

/// 解析 WAV 头。非法/截断返回 null（调用方据此走「录音不可用」兜底，不许崩）。
///
/// 用按块遍历而不是硬编码偏移：`fmt ` 块长度在不同写入器里可以不是 16，
/// 硬编码 44 字节偏移在别人的 WAV 上会读出垃圾值。
WavInfo? parseWavHeader(Uint8List bytes) {
  if (bytes.length < 44) return null;
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;
  if (String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') return null;

  int? rate, channels, bits, dataBytes;
  var i = 12;
  while (i + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(i, i + 4));
    final size = _le32(bytes, i + 4);
    final body = i + 8;
    if (size < 0) return null;
    if (id == 'fmt ') {
      if (body + 16 > bytes.length) return null;
      channels = _le16(bytes, body + 2);
      rate = _le32(bytes, body + 4);
      bits = _le16(bytes, body + 14);
    } else if (id == 'data') {
      // 写头时 data 长度可能还没回填（0 或超长），以实际文件为准取小值。
      final remain = bytes.length - body;
      dataBytes = size <= 0 || size > remain ? remain : size;
      break;
    }
    // 块按偶数字节对齐（RIFF 规范），奇数长度补 1 字节。
    i = body + size + (size.isOdd ? 1 : 0);
  }
  if (rate == null || channels == null || bits == null) return null;
  return WavInfo(
    sampleRate: rate,
    channels: channels,
    bitsPerSample: bits,
    dataBytes: dataBytes ?? (bytes.length - 44),
  );
}

int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

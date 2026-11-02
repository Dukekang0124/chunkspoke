/// 发音/慢速读速度的单一源（指令 ASR-200 §二）。
///
/// **语义（实测，不是猜）**：sherpa-onnx VITS 的 `speed` 是语速倍率——
/// 数值越小越慢，0.58 为标准档；它不是 length_scale，1.2/1.3 反而更快。
///
/// **校准**（2026-11-02，模型 `hd-voice-piper-en-us-medium` /
/// `ljspeech-medium-2`，58,873,277 B，sherpa-onnx 1.13.8，17 词标定句，
/// 每档 15 次取均值）：
///
/// | speed | 时长 | 语速 | 相对标准 |
/// |-------|------|------|----------|
/// | 0.41  | 10.28 s | ≈99 wpm  | 0.747x |
/// | 0.58  | 7.68 s  | ≈132 wpm | 1.000x |
/// | 0.76  | 6.09 s  | ≈168 wpm | 1.261x |
///
/// F0 中位 200–210 Hz，不随 speed 系统偏移（音高不变）。
/// 目标 0.75 / 1.0 / 1.25，误差 −0.4% / 0 / +0.9%。
///
/// **禁止在别处再写 speed 数值**：`HdVoiceService.kSpeed` 已废除，
/// 浸泡层与朗读必须都从这里取档。
class VoiceSpeed {
  const VoiceSpeed._();

  /// 慢档（目标 0.75x）的 VITS 合成 speed。
  static const double hdSlow = 0.41;

  /// 标准档（1.0x）的 VITS 合成 speed；也是历史标定锚点。
  static const double hdNormal = 0.58;

  /// 快档（目标 1.25x）的 VITS 合成 speed。
  static const double hdFast = 0.76;

  /// 播放倍率（0.75 / 1.0 / 1.25）→ 高清合成 speed。
  ///
  /// 三档吸附：非三档值就近归类，调用方不能造出第四档。
  static double hdForRate(double rate) {
    if (rate < 0.875) return hdSlow;
    if (rate < 1.125) return hdNormal;
    return hdFast;
  }

  /// 系统 TTS 基准 rate（flutter_tts 口径；标准档 0.22）。
  static const double systemBase = 0.22;

  /// 播放倍率 → 系统引擎 rate。
  ///
  /// 只喂合成（setSpeechRate 一层），播放端不再乘倍率——
  /// 旧版「合成 0.165 再 ×0.75 ≈0.56x」的复合控速必须消失。
  static double systemForRate(double rate) => systemBase * rate;
}

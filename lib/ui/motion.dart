import 'package:flutter/services.dart';

/// B7：省电模式探测（原生 PowerManager.isPowerSaveMode，失败回退 false）。
class PowerService {
  static const MethodChannel _ch = MethodChannel('chunkspoke/power');
  static Future<bool> isPowerSaveMode() async {
    try {
      return await _ch.invokeMethod('isPowerSaveMode') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// B7：动效/触感降级策略（纯逻辑，可单测）。
///   - 尊重系统「减弱动画」（MediaQuery.disableAnimations）；
///   - 省电模式自动降级（粒子减半 / 关屏幕震动）。
class MotionPolicy {
  final bool reduceMotion; // 系统「减弱动画」
  final bool lowPower; // 省电模式
  const MotionPolicy({this.reduceMotion = false, this.lowPower = false});

  /// 是否降级（任一触发即降级）。
  bool get reduce => reduceMotion || lowPower;

  /// 粒子数量：降级减半（省电/减弱动画时）。
  int particles(int base) => reduce ? (base ~/ 2) : base;

  /// 屏幕震动：省电模式关闭（跟随系统/省电）。
  bool get hapticsOn => !lowPower;

  /// 装饰性动画（彩带等）：减弱动画时关闭。
  bool get confettiOn => !reduceMotion;
}

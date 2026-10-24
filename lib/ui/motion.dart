import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
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

  /// 动画是否播放（reduce 时一律直接切换，不放动画）。
  bool get animates => !reduce;

  /// 粒子数量：降级减半（省电/减弱动画时）。
  int particles(int base) => reduce ? (base ~/ 2) : base;

  /// 屏幕震动：省电模式关闭（跟随系统/省电）。
  bool get hapticsOn => !lowPower;

  /// 装饰性动画（彩带等）：减弱动画时关闭。
  bool get confettiOn => !reduceMotion;

  /// 时长闸：降级时返回 [Duration.zero]，隐式动画即「直接切换」。
  Duration dur(int ms) => reduce ? Duration.zero : Duration(milliseconds: ms);

  /// 触感闸：所有 HapticFeedback 调用统一走这里。
  void haptic(void Function() fire) {
    if (hapticsOn) fire();
  }

  void tap() => haptic(HapticFeedback.lightImpact);
  void success() => haptic(HapticFeedback.mediumImpact);
  void wrong() => haptic(HapticFeedback.mediumImpact);
}

/// M1：全局动效闸门服务——省电模式在启动与回前台时刷新，供 [Motion.of] 读取。
class MotionService extends ChangeNotifier with WidgetsBindingObserver {
  MotionService({Future<bool> Function()? powerProbe})
      : _probe = powerProbe ?? PowerService.isPowerSaveMode {
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  final Future<bool> Function() _probe;
  bool _lowPower = false;
  bool get lowPower => _lowPower;

  Future<void> refresh() async {
    try {
      final v = await _probe();
      if (v != _lowPower) {
        _lowPower = v;
        notifyListeners();
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

/// M1：动效点唯一的策略入口。此前 13 处动效各自读 MediaQuery 或根本不读，
/// 现统一经此闸，保证「系统开启减弱动画 → 全 app 直接切换」。
class Motion {
  /// [listen] 为 false 时省电模式变化不触发重建（动效在触发瞬间取值已足够）；
  /// 需要随省电实时改样的组件传 true。
  ///
  /// 未挂 [MotionService] 的场景（启动失败兜底页、单测直接 pump 局部 widget）
  /// 退回「只看系统减弱动画」，不抛异常。
  static MotionPolicy of(BuildContext context, {bool listen = false}) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    MotionService? svc;
    try {
      svc = Provider.of<MotionService>(context, listen: listen);
    } catch (_) {
      svc = null;
    }
    return MotionPolicy(reduceMotion: reduce, lowPower: svc?.lowPower ?? false);
  }
}

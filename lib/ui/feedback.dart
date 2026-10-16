import 'package:flutter/services.dart';

/// 最小反馈：对=轻快系统音；错=中等振动（抖动感）。不引入音频依赖，
/// 配合绿框/抖动视觉，满足「作答即对/错即时反馈」。
void chimeCorrect() => SystemSound.play(SystemSoundType.click);
void buzzWrong() => HapticFeedback.mediumImpact();

import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

/// M1（#12）：统一底部浮层入口——入场/退场参数集中一处，11 个浮层共用。
///
/// 参数口径（`ui-motion` v0.21 · 12 底部弹窗 + foundations 时长分级）：
///   - 进场 400ms（面板级 300–450ms 带内）ease-out；
///   - 退场 300ms ease-in（比进场快，符合「退场 ease-in」）；
///   - 系统「减弱动画」或省电 → 时长归零，直接切换。
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = true,
  bool enableDrag = true,
  bool showDragHandle = false,
  bool isDismissible = true,
  double? maxHeightRatio,
  ShapeBorder? shape,
}) {
  final policy = Motion.of(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: backgroundColor ?? kCard,
    isScrollControlled: isScrollControlled,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    showDragHandle: showDragHandle,
    shape: shape,
    // 未显式给比例时保持 Material 原默认（9/16），避免收敛入口顺手改了浮层高度上限。
    scrollControlDisabledMaxHeightRatio: maxHeightRatio ?? 9.0 / 16.0,
    sheetAnimationStyle: AnimationStyle(
      duration: policy.dur(400),
      reverseDuration: policy.dur(300),
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    ),
    builder: builder,
  );
}

/// 浮层内的标准标题行（收敛各处手写标题）。
class AppSheetTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const AppSheetTitle(this.title, {this.subtitle, super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

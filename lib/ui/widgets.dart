import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/loaders.dart';
import 'theme.dart';
import 'labels.dart';

/// 词块视觉芯片：颜色 + 形状双重编码。纯展示，拖拽/点击由外层包裹。
class ChunkTile extends StatelessWidget {
  final String text;
  final String type;
  final bool selected;
  final VoidCallback? onTap;
  final EdgeInsets? margin;
  const ChunkTile(this.text, this.type,
      {this.selected = false, this.onTap, this.margin, super.key});

  @override
  Widget build(BuildContext context) {
    final color = chunkColor(type);
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? color.withOpacity(0.35) : color.withOpacity(0.16),
        border: Border.all(
          color: type == 'timeplace'
              ? color
              : (selected ? color : color.withOpacity(0.5)),
          width: type == 'timeplace' ? 1 : (selected ? 2 : 1),
        ),
        borderRadius: chunkRadius(type),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: chunkFontSize(type),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 长按中文逃生舱：禁用系统菜单（用普通 Text），长按弹出中文卡，3.5s 自动消失并计入提示率。
class CnText extends StatelessWidget {
  final String text;
  final String cn;
  final TextStyle? style;
  const CnText(this.text, this.cn, {this.style, super.key});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onLongPress: () => showCnCard(context, cn),
        child: Text(text, style: style),
      );
}

void showCnCard(BuildContext context, String cn) {
  try {
    Provider.of<ProgressService>(context, listen: false).incHint();
  } catch (_) {}
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  var removed = false;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      left: 24,
      right: 24,
      bottom: 90,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A2E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(cn, style: const TextStyle(color: Colors.white, fontSize: 16)),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 3500), () {
    if (!removed) {
      removed = true;
      entry.remove();
    }
  });
}

/// 场景卡占位（Phase 1 无真实图片资源，用渐变 + 主题名渲染，避免缺图崩溃）。
class SceneCard extends StatelessWidget {
  final String theme;
  const SceneCard(this.theme, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        height: 130,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [kPrimary, Color(0xFF8B5CF6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(sceneCn(theme),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(theme,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      );
}

/// 录音态实时电平条：条高只由真实采集电平（0..1）驱动，非自由动画。
/// 说话时整排抬起并跳动 = 采集正常；全程平贴底部不动 = 采集故障（一眼可判）。
class LevelMeter extends StatelessWidget {
  final double level; // 0..1 实时峰值/音量
  const LevelMeter({required this.level, super.key});

  @override
  Widget build(BuildContext context) {
    final l = level.clamp(0.0, 1.0);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(24, (i) {
        // 稳定权重：各条高度不同；电平为 0 时全部回落成一条平线。
        final w = 0.45 + 0.55 * (0.5 + 0.5 * sin(i * pi / 6));
        final h = 8.0 + l * 48.0 * w;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 4,
          height: h,
          decoration: BoxDecoration(
            color: kPrimary.withOpacity(0.45 + l * 0.55 * w),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

/// 掌握度环（Phase 1 用整体完成度；四维点亮在 Phase 3）。
class MasteryRing extends StatelessWidget {
  final double fraction;
  final double size;
  const MasteryRing(this.fraction, {this.size = 34, super.key});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: fraction,
              strokeWidth: 4,
              color: kUnlocked,
              backgroundColor: kLocked,
            ),
            Text('${(fraction * 100).toInt()}',
                style: const TextStyle(fontSize: 10, color: Colors.white)),
          ],
        ),
      );
}

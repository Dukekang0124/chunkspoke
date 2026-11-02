import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/theme_provider.dart';
import 'theme.dart';

/// 外观与主题卡片（1.7.0 · 任务书 §7）。
///
/// 放在 `ui/` 而不是塞进 settings.dart：设置页已经 1900+ 行，卡片单独成文
/// 才能在单测里脱离数据库直接验证「点色板 → 全 App 换色」。
///
/// 口径：
/// 1. 7 个 48px 圆形色板，上半显示底色、下半显示主色（双色预览），
///    选中态加主题主色描边；
/// 2. 深色/浅色两个模式键——每套主题都配了浅深两套色值；
/// 3. 点选即时生效（[ThemeProvider] 内部整树重建）并写库，重启保持。
class ThemeCard extends StatelessWidget {
  const ThemeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Provider.of<ThemeProvider>(context);
    return Container(
      key: const ValueKey('theme-card'),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('外观与主题',
              style: TextStyle(color: kText, fontWeight: FontWeight.w600)),
          Text('切换后即时生效，重启后保留（词块形状编码不变，只换色）',
              style: TextStyle(color: kTextMuted, fontSize: 12)),
          const SizedBox(height: 12),
          SizedBox(
            height: 74,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final theme in appThemes)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _Swatch(
                      theme: theme,
                      selected: theme.id == t.themeId,
                      dark: t.isDark,
                      onTap: () => t.setTheme(theme.id),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _ModeChip(
                keyName: 'theme-mode-dark',
                label: '深色',
                active: t.isDark,
                onTap: () => t.setDark(true),
              ),
              const SizedBox(width: 8),
              _ModeChip(
                keyName: 'theme-mode-light',
                label: '浅色',
                active: !t.isDark,
                onTap: () => t.setDark(false),
              ),
              const Spacer(),
              Text(t.currentTheme.label,
                  style: TextStyle(color: kTextFaint, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.theme,
    required this.selected,
    required this.dark,
    required this.onTap,
  });

  final AppTheme theme;
  final bool selected;
  final bool dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = theme.paletteFor(dark ? Brightness.dark : Brightness.light);
    return Semantics(
      button: true,
      selected: selected,
      label: '主题 ${theme.label}',
      child: GestureDetector(
        key: ValueKey('theme-swatch-${theme.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 56,
          child: Column(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: p.bg,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? kPrimary : p.borderStrong,
                    width: selected ? 2.5 : 1,
                  ),
                ),
                child: ClipOval(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(height: 24, width: 48, color: p.primary),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(theme.label.substring(0, 2),
                  style: TextStyle(
                      color: selected ? kPrimary : kTextFaint, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.keyName,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String keyName;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      child: GestureDetector(
        key: ValueKey(keyName),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: active ? kPrimaryTint : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: active ? kPrimary : kBorderStrong),
          ),
          child: Text(label,
              style: TextStyle(
                  color: active ? kPrimary : kTextMuted, fontSize: 12)),
        ),
      ),
    );
  }
}

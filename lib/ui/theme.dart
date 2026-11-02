import 'package:flutter/material.dart';

/// 7 套主题 × 浅/深双模式。
///
/// 设计约束：
/// 1. 词块的「颜色 + 圆角 + 字号」双重编码必须保留 —— 换主题只换色，不动形状。
/// 2. 所有页面只允许引用 kXxx 令牌（本文件），不允许再写 Colors.white54 之类的散值，
///    否则浅色主题会出现白字白底。
/// 3. 令牌是运行期 getter：切换主题时由 ThemeProvider 调用 [applyPalette] 并整树
///    重建，因此不要把令牌放进 const 表达式。
class AppPalette {
  const AppPalette({
    required this.id,
    required this.label,
    required this.audience,
    required this.brightness,
    required this.bg,
    required this.card,
    required this.cardAlt,
    required this.primary,
    required this.onPrimary,
    required this.primaryDeep,
    required this.secondary,
    required this.success,
    required this.error,
    required this.warning,
    required this.locked,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textFaint,
    required this.border,
    required this.borderSoft,
    required this.borderStrong,
    required this.info,
    required this.accentViolet,
    required this.primaryTint,
    required this.errorTint,
    required this.infoTint,
    required this.shadow,
  });

  final String id;
  final String label;
  final String audience; // neutral / female / male
  final Brightness brightness;

  final Color bg;
  final Color card;
  final Color cardAlt;
  final Color primary;
  final Color onPrimary;

  /// 渐变副色：深色主题=主色压深，浅色主题=主色淡洗（卡上压的是深色正文）。
  final Color primaryDeep;
  final Color secondary;
  final Color success;
  final Color error;
  final Color warning;
  final Color locked;

  final Color text; // 主文字
  final Color textSecondary; // 次要文字（原 white70）
  final Color textMuted; // 说明文字（原 white54）
  final Color textFaint; // 弱提示（原 white38/white30）

  final Color border; // 常规描边/分割线（原 white12）
  final Color borderSoft; // 更弱的底色/描边（原 white10）
  final Color borderStrong; // 强调描边（原 white24）

  final Color info;
  final Color accentViolet;
  final Color primaryTint;
  final Color errorTint;
  final Color infoTint;
  final Color shadow;
}

class AppTheme {
  const AppTheme({
    required this.id,
    required this.label,
    required this.audience,
    required this.light,
    required this.dark,
  });

  final String id;
  final String label;
  final String audience;
  final AppPalette light;
  final AppPalette dark;

  AppPalette paletteFor(Brightness b) =>
      b == Brightness.light ? light : dark;
}

// ---------------------------------------------------------------------------
// 色板定义
// ---------------------------------------------------------------------------

const AppPalette _defaultDark = AppPalette(
  id: 'default',
  label: '墨蓝琥珀',
  audience: 'neutral',
  brightness: Brightness.dark,
  bg: Color(0xFF0F0F1A),
  card: Color(0xFF1A1B2E),
  cardAlt: Color(0xFF22233A),
  primary: Color(0xFFFFB84D),
  onPrimary: Color(0xDD000000),
  primaryDeep: Color(0xFF241A06),
  secondary: Color(0xFF6B7B8C),
  success: Color(0xFF34C77B),
  error: Color(0xFFFF6B6B),
  warning: Color(0xFFFFD54F),
  locked: Color(0xFF3A3A52),
  text: Color(0xFFFFFFFF),
  textSecondary: Color(0xB3FFFFFF),
  textMuted: Color(0x8AFFFFFF),
  textFaint: Color(0x61FFFFFF),
  border: Color(0x1FFFFFFF),
  borderSoft: Color(0x14FFFFFF),
  borderStrong: Color(0x3DFFFFFF),
  info: Color(0xFF7FB4FF),
  accentViolet: Color(0xFF8B5CF6),
  primaryTint: Color(0x22FFB84D),
  errorTint: Color(0x22FF6B6B),
  infoTint: Color(0x3364B5F6),
  shadow: Color(0x8A000000),
);

const AppPalette _defaultLight = AppPalette(
  id: 'default',
  label: '墨蓝琥珀',
  audience: 'neutral',
  brightness: Brightness.light,
  bg: Color(0xFFF5F6F8),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFEEF1F5),
  primary: Color(0xFFA86A12),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFFF5E7CF),
  secondary: Color(0xFF1E3A5F),
  success: Color(0xFF1B8A52),
  error: Color(0xFFC43D3D),
  warning: Color(0xFF9A5B00),
  locked: Color(0xFFD5D9E0),
  text: Color(0xFF1A2332),
  textSecondary: Color(0xFF475569),
  textMuted: Color(0xFF64748B),
  textFaint: Color(0xFF94A3B8),
  border: Color(0xFFE2E8F0),
  borderSoft: Color(0xFFEEF2F6),
  borderStrong: Color(0xFFCBD5E1),
  info: Color(0xFF2563EB),
  accentViolet: Color(0xFF7C3AED),
  primaryTint: Color(0x1AA86A12),
  errorTint: Color(0x1AC43D3D),
  infoTint: Color(0x1A2563EB),
  shadow: Color(0x26000000),
);

const AppPalette _nudeRoseDark = AppPalette(
  id: 'nude_rose',
  label: '奶咖玫瑰',
  audience: 'female',
  brightness: Brightness.dark,
  bg: Color(0xFF2B2320),
  card: Color(0xFF3A312C),
  cardAlt: Color(0xFF453A34),
  primary: Color(0xFFD99A8C),
  onPrimary: Color(0xFF2B2320),
  primaryDeep: Color(0xFF4A2E28),
  secondary: Color(0xFFB8A28F),
  success: Color(0xFF63C79A),
  error: Color(0xFFE58A8A),
  warning: Color(0xFFE0B36A),
  locked: Color(0xFF5A4C44),
  text: Color(0xFFF5EDE5),
  textSecondary: Color(0xCCC9B7A9),
  textMuted: Color(0xA6B09C8C),
  textFaint: Color(0x80917D6E),
  border: Color(0x2EF5EDE5),
  borderSoft: Color(0x1AF5EDE5),
  borderStrong: Color(0x47F5EDE5),
  info: Color(0xFF8FB4D9),
  accentViolet: Color(0xFFC2A1C2),
  primaryTint: Color(0x22D99A8C),
  errorTint: Color(0x22E58A8A),
  infoTint: Color(0x338FB4D9),
  shadow: Color(0x8A000000),
);

const AppPalette _nudeRoseLight = AppPalette(
  id: 'nude_rose',
  label: '奶咖玫瑰',
  audience: 'female',
  brightness: Brightness.light,
  bg: Color(0xFFF7F3EF),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFFBF7F4),
  primary: Color(0xFFB36F60),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFFF6E5E0),
  secondary: Color(0xFF8A7B6E),
  success: Color(0xFF2F7D5B),
  error: Color(0xFFB84C4C),
  warning: Color(0xFF9A6B2F),
  locked: Color(0xFFE0D6CE),
  text: Color(0xFF3D3229),
  textSecondary: Color(0xFF6B5C4F),
  textMuted: Color(0xFF8A7B6E),
  textFaint: Color(0xFFA69686),
  border: Color(0xFFE8DED6),
  borderSoft: Color(0xFFF2EBE5),
  borderStrong: Color(0xFFD8C9BD),
  info: Color(0xFF4F6D8C),
  accentViolet: Color(0xFF8E6B8E),
  primaryTint: Color(0x1AB36F60),
  errorTint: Color(0x1AB84C4C),
  infoTint: Color(0x1A4F6D8C),
  shadow: Color(0x26000000),
);

const AppPalette _sageDark = AppPalette(
  id: 'sage',
  label: '莫兰迪灰绿',
  audience: 'female',
  brightness: Brightness.dark,
  bg: Color(0xFF1E2220),
  card: Color(0xFF2A2F2C),
  cardAlt: Color(0xFF343A36),
  primary: Color(0xFF9DB09D),
  onPrimary: Color(0xFF1E2220),
  primaryDeep: Color(0xFF2F3B31),
  secondary: Color(0xFFB5A8A0),
  success: Color(0xFF6FBF95),
  error: Color(0xFFD98A8A),
  warning: Color(0xFFD8B070),
  locked: Color(0xFF47504A),
  text: Color(0xFFE8EDE8),
  textSecondary: Color(0xCCD2DAD2),
  textMuted: Color(0xA6B3BCB4),
  textFaint: Color(0x8097A098),
  border: Color(0x2EE8EDE8),
  borderSoft: Color(0x1AE8EDE8),
  borderStrong: Color(0x47E8EDE8),
  info: Color(0xFF8FB0CC),
  accentViolet: Color(0xFFB9A3C4),
  primaryTint: Color(0x229DB09D),
  errorTint: Color(0x22D98A8A),
  infoTint: Color(0x338FB0CC),
  shadow: Color(0x8A000000),
);

const AppPalette _sageLight = AppPalette(
  id: 'sage',
  label: '莫兰迪灰绿',
  audience: 'female',
  brightness: Brightness.light,
  bg: Color(0xFFF4F4F1),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFF8F8F5),
  primary: Color(0xFF5F7360),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFFE8EDE6),
  secondary: Color(0xFF7A8B7A),
  success: Color(0xFF2F7D5B),
  error: Color(0xFFB84C4C),
  warning: Color(0xFF8A6B2F),
  locked: Color(0xFFDDE1DB),
  text: Color(0xFF33383A),
  textSecondary: Color(0xFF5C6366),
  textMuted: Color(0xFF71787A),
  textFaint: Color(0xFFA0A6A7),
  border: Color(0xFFE2E4E0),
  borderSoft: Color(0xFFEDEFEA),
  borderStrong: Color(0xFFCDD2CC),
  info: Color(0xFF4F6D8C),
  accentViolet: Color(0xFF8A7396),
  primaryTint: Color(0x1A5F7360),
  errorTint: Color(0x1AB84C4C),
  infoTint: Color(0x1A4F6D8C),
  shadow: Color(0x26000000),
);

const AppPalette _plumDark = AppPalette(
  id: 'plum',
  label: '雾玫瑰灰紫',
  audience: 'female',
  brightness: Brightness.dark,
  bg: Color(0xFF241E22),
  card: Color(0xFF322A2F),
  cardAlt: Color(0xFF3D343A),
  primary: Color(0xFFC49BAE),
  onPrimary: Color(0xFF241E22),
  primaryDeep: Color(0xFF46303A),
  secondary: Color(0xFFC9B8C0),
  success: Color(0xFF6FBF95),
  error: Color(0xFFD98A8A),
  warning: Color(0xFFD8B070),
  locked: Color(0xFF4F444A),
  text: Color(0xFFEFE8EC),
  textSecondary: Color(0xCCD8CBD1),
  textMuted: Color(0xA6B9A9B1),
  textFaint: Color(0x809A8A93),
  border: Color(0x2EEFE8EC),
  borderSoft: Color(0x1AEFE8EC),
  borderStrong: Color(0x47EFE8EC),
  info: Color(0xFF93AED0),
  accentViolet: Color(0xFFC4A3C9),
  primaryTint: Color(0x22C49BAE),
  errorTint: Color(0x22D98A8A),
  infoTint: Color(0x3393AED0),
  shadow: Color(0x8A000000),
);

const AppPalette _plumLight = AppPalette(
  id: 'plum',
  label: '雾玫瑰灰紫',
  audience: 'female',
  brightness: Brightness.light,
  bg: Color(0xFFF5F0F2),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFFAF6F8),
  primary: Color(0xFF96697B),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFFF1E4EA),
  secondary: Color(0xFF8C7B85),
  success: Color(0xFF2F7D5B),
  error: Color(0xFFB84C4C),
  warning: Color(0xFF8A6B2F),
  locked: Color(0xFFE2D8DE),
  text: Color(0xFF3A2E35),
  textSecondary: Color(0xFF64545D),
  textMuted: Color(0xFF8C7B85),
  textFaint: Color(0xFFAB9BA4),
  border: Color(0xFFE9DEE4),
  borderSoft: Color(0xFFF3EBF0),
  borderStrong: Color(0xFFD8C8D0),
  info: Color(0xFF526D8C),
  accentViolet: Color(0xFF89619A),
  primaryTint: Color(0x1A96697B),
  errorTint: Color(0x1AB84C4C),
  infoTint: Color(0x1A526D8C),
  shadow: Color(0x26000000),
);

const AppPalette _oceanDark = AppPalette(
  id: 'ocean',
  label: '深海蓝',
  audience: 'male',
  brightness: Brightness.dark,
  bg: Color(0xFF0D1622),
  card: Color(0xFF162435),
  cardAlt: Color(0xFF1D2E43),
  primary: Color(0xFF4A7FBF),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFF0A1B2E),
  secondary: Color(0xFF4A6B8A),
  // 本板 onPrimary 是白字，成功色必须压深到能托住白字（原 #34C77B 白字只有 2.2:1）
  success: Color(0xFF1E9A5C),
  error: Color(0xFFFF6B6B),
  warning: Color(0xFFFFD54F),
  locked: Color(0xFF31445A),
  text: Color(0xFFE8EEF5),
  textSecondary: Color(0xCCB9C9D9),
  textMuted: Color(0xA69BB0C6),
  textFaint: Color(0x807F95AC),
  border: Color(0x2EE8EEF5),
  borderSoft: Color(0x1AE8EEF5),
  borderStrong: Color(0x47E8EEF5),
  info: Color(0xFF7FB4FF),
  accentViolet: Color(0xFF8B9CF6),
  primaryTint: Color(0x224A7FBF),
  errorTint: Color(0x22FF6B6B),
  infoTint: Color(0x337FB4FF),
  shadow: Color(0x8A000000),
);

const AppPalette _oceanLight = AppPalette(
  id: 'ocean',
  label: '深海蓝',
  audience: 'male',
  brightness: Brightness.light,
  bg: Color(0xFFF2F5F8),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFECF1F7),
  primary: Color(0xFF1E3A5F),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFFE5EBF2),
  secondary: Color(0xFF4A6B8A),
  success: Color(0xFF1B8A52),
  error: Color(0xFFC43D3D),
  warning: Color(0xFF9A5B00),
  locked: Color(0xFFD3DDE7),
  text: Color(0xFF1A2332),
  textSecondary: Color(0xFF44607E),
  textMuted: Color(0xFF6B7B8C),
  textFaint: Color(0xFF93A5B8),
  border: Color(0xFFDFE6EE),
  borderSoft: Color(0xFFEDF2F7),
  borderStrong: Color(0xFFC8D4E0),
  info: Color(0xFF2563EB),
  accentViolet: Color(0xFF7C6BD6),
  primaryTint: Color(0x1A1E3A5F),
  errorTint: Color(0x1AC43D3D),
  infoTint: Color(0x1A2563EB),
  shadow: Color(0x26000000),
);

const AppPalette _forestDark = AppPalette(
  id: 'forest',
  label: '墨绿',
  audience: 'male',
  brightness: Brightness.dark,
  bg: Color(0xFF101A15),
  card: Color(0xFF1A2820),
  cardAlt: Color(0xFF223228),
  primary: Color(0xFF5A9A78),
  onPrimary: Color(0xFF08120D),
  primaryDeep: Color(0xFF0B1F16),
  secondary: Color(0xFF5A7A68),
  success: Color(0xFF34C77B),
  error: Color(0xFFFF6B6B),
  warning: Color(0xFFFFD54F),
  locked: Color(0xFF33493C),
  text: Color(0xFFE8F0EA),
  textSecondary: Color(0xCCBBCDC2),
  textMuted: Color(0xA69DB5A7),
  textFaint: Color(0x80829B8B),
  border: Color(0x2EE8F0EA),
  borderSoft: Color(0x1AE8F0EA),
  borderStrong: Color(0x47E8F0EA),
  info: Color(0xFF7FB4FF),
  accentViolet: Color(0xFF9B8BE0),
  primaryTint: Color(0x225A9A78),
  errorTint: Color(0x22FF6B6B),
  infoTint: Color(0x337FB4FF),
  shadow: Color(0x8A000000),
);

const AppPalette _forestLight = AppPalette(
  id: 'forest',
  label: '墨绿',
  audience: 'male',
  brightness: Brightness.light,
  bg: Color(0xFFF3F5F2),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFEDF2EE),
  primary: Color(0xFF2F4F3E),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFFE4EDE6),
  secondary: Color(0xFF5A7A68),
  success: Color(0xFF1B8A52),
  error: Color(0xFFC43D3D),
  warning: Color(0xFF8A6B2F),
  locked: Color(0xFFD4DDD6),
  text: Color(0xFF1E2A24),
  textSecondary: Color(0xFF4A5E51),
  textMuted: Color(0xFF6B7B70),
  textFaint: Color(0xFF94A298),
  border: Color(0xFFE0E6E1),
  borderSoft: Color(0xFFEEF2EF),
  borderStrong: Color(0xFFC9D3CB),
  info: Color(0xFF2563EB),
  accentViolet: Color(0xFF7C6BD6),
  primaryTint: Color(0x1A2F4F3E),
  errorTint: Color(0x1AC43D3D),
  infoTint: Color(0x1A2563EB),
  shadow: Color(0x26000000),
);

const AppPalette _charcoalDark = AppPalette(
  id: 'charcoal',
  label: '炭灰极简',
  audience: 'male',
  brightness: Brightness.dark,
  bg: Color(0xFF14161A),
  card: Color(0xFF1F2329),
  cardAlt: Color(0xFF282D34),
  primary: Color(0xFF8A93A3),
  onPrimary: Color(0xFF101216),
  primaryDeep: Color(0xFF2A2F36),
  secondary: Color(0xFF6B7280),
  success: Color(0xFF34C77B),
  error: Color(0xFFFF6B6B),
  warning: Color(0xFFFFD54F),
  locked: Color(0xFF3C424B),
  text: Color(0xFFE8EBEF),
  textSecondary: Color(0xCCBCC2CB),
  textMuted: Color(0xA69AA1AC),
  textFaint: Color(0x807C848F),
  border: Color(0x2EE8EBEF),
  borderSoft: Color(0x1AE8EBEF),
  borderStrong: Color(0x47E8EBEF),
  info: Color(0xFF7FB4FF),
  accentViolet: Color(0xFF9B8BE0),
  primaryTint: Color(0x228A93A3),
  errorTint: Color(0x22FF6B6B),
  infoTint: Color(0x337FB4FF),
  shadow: Color(0x8A000000),
);

const AppPalette _charcoalLight = AppPalette(
  id: 'charcoal',
  label: '炭灰极简',
  audience: 'male',
  brightness: Brightness.light,
  bg: Color(0xFFF5F5F6),
  card: Color(0xFFFFFFFF),
  cardAlt: Color(0xFFF0F1F2),
  primary: Color(0xFF3A3F47),
  onPrimary: Color(0xFFFFFFFF),
  primaryDeep: Color(0xFFE8EAEE),
  secondary: Color(0xFF6B7280),
  success: Color(0xFF1B8A52),
  error: Color(0xFFC43D3D),
  warning: Color(0xFF8A6B2F),
  locked: Color(0xFFD8DBDF),
  text: Color(0xFF1F2329),
  textSecondary: Color(0xFF555B65),
  textMuted: Color(0xFF7A818B),
  textFaint: Color(0xFF9AA1AA),
  border: Color(0xFFE4E6E9),
  borderSoft: Color(0xFFEFF1F3),
  borderStrong: Color(0xFFD0D4D9),
  info: Color(0xFF2563EB),
  accentViolet: Color(0xFF7C6BD6),
  primaryTint: Color(0x1A3A3F47),
  errorTint: Color(0x1AC43D3D),
  infoTint: Color(0x1A2563EB),
  shadow: Color(0x26000000),
);

const List<AppTheme> appThemes = [
  AppTheme(
      id: 'default',
      label: '墨蓝琥珀',
      audience: 'neutral',
      light: _defaultLight,
      dark: _defaultDark),
  AppTheme(
      id: 'nude_rose',
      label: '奶咖玫瑰',
      audience: 'female',
      light: _nudeRoseLight,
      dark: _nudeRoseDark),
  AppTheme(
      id: 'sage',
      label: '莫兰迪灰绿',
      audience: 'female',
      light: _sageLight,
      dark: _sageDark),
  AppTheme(
      id: 'plum',
      label: '雾玫瑰灰紫',
      audience: 'female',
      light: _plumLight,
      dark: _plumDark),
  AppTheme(
      id: 'ocean',
      label: '深海蓝',
      audience: 'male',
      light: _oceanLight,
      dark: _oceanDark),
  AppTheme(
      id: 'forest',
      label: '墨绿',
      audience: 'male',
      light: _forestLight,
      dark: _forestDark),
  AppTheme(
      id: 'charcoal',
      label: '炭灰极简',
      audience: 'male',
      light: _charcoalLight,
      dark: _charcoalDark),
];

AppTheme themeById(String? id) {
  // 兼容任务书里的旧 id（default_dark / nude_rose_light …）。
  final base = (id ?? '')
      .replaceAll('_dark', '')
      .replaceAll('_light', '')
      .trim();
  for (final t in appThemes) {
    if (t.id == base) return t;
  }
  return appThemes.first;
}

Brightness brightnessFromId(String? id) {
  if ((id ?? '').endsWith('_light')) return Brightness.light;
  return Brightness.dark;
}

/// 当前生效色板。切换主题时由 ThemeProvider 写入，页面只读。
AppPalette _active = appThemes.first.dark;

AppPalette get activePalette => _active;

void applyPalette(AppPalette p) {
  _active = p;
}

// ---------------------------------------------------------------------------
// 令牌（页面唯一允许引用的颜色入口）
// ---------------------------------------------------------------------------

Color get kBg => _active.bg;
Color get kCard => _active.card;
Color get kCardAlt => _active.cardAlt;
Color get kPrimary => _active.primary;
Color get kOnPrimary => _active.onPrimary;
Color get kPrimaryDeep => _active.primaryDeep;
Color get kSecondary => _active.secondary;
Color get kUnlocked => _active.success;
Color get kSuccess => _active.success;
Color get kError => _active.error;
Color get kWarning => _active.warning;
Color get kLocked => _active.locked;

Color get kText => _active.text;
Color get kTextSecondary => _active.textSecondary;
Color get kTextMuted => _active.textMuted;
Color get kTextFaint => _active.textFaint;

Color get kBorder => _active.border;
Color get kBorderSoft => _active.borderSoft;
Color get kBorderStrong => _active.borderStrong;

Color get kInfo => _active.info;
Color get kAccentViolet => _active.accentViolet;
Color get kPrimaryTint => _active.primaryTint;
Color get kErrorTint => _active.errorTint;
Color get kInfoTint => _active.infoTint;
Color get kWarningTint => _active.warning
    .withValues(alpha: _active.brightness == Brightness.dark ? 0.25 : 0.12);
Color get kShadow => _active.shadow;

/// 固定语义色（CEFR 徽标、撒花等）在浅色下压暗，保证白底可读；深色保持原样。
Color adaptiveAccent(Color c) =>
    _active.brightness == Brightness.dark
        ? c
        : Color.lerp(c, Colors.black, 0.32)!;

// 旧代码里少量语义色，统一收口到令牌，避免主题切换后失配。
Color get kAccentCyan => _active.info;
Color get kAccentPurple => _active.accentViolet;
Color get kSuccessAlt => _active.success;

/// 词块类型 → 视觉色（与 ChunkTile 形状编码配合，双重编码）。
Color chunkColor(String type) {
  switch (type) {
    case 'content':
      return kPrimary;
    case 'function':
      return kUnlocked;
    case 'connector':
      return kTextSecondary;
    case 'timeplace':
      return kError;
    default:
      return kText;
  }
}

/// 词块类型 → 圆角（形状编码，主题无关）。
BorderRadius chunkRadius(String type) {
  switch (type) {
    case 'function':
      return BorderRadius.circular(999);
    case 'timeplace':
      return BorderRadius.circular(2);
    case 'connector':
      return BorderRadius.circular(6);
    default:
      return BorderRadius.circular(12);
  }
}

/// 词块类型 → 字号。
double chunkFontSize(String type) {
  switch (type) {
    case 'timeplace':
      return 13;
    case 'connector':
      return 14;
    default:
      return 16;
  }
}

/// 从指定色板构建 ThemeData；MaterialApp 的 light/darkTheme 都走这里。
ThemeData buildAppTheme(AppPalette p) {
  final isDark = p.brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.primary,
    onPrimary: p.onPrimary,
    secondary: p.secondary,
    onSecondary: p.onPrimary,
    error: p.error,
    onError: isDark ? Colors.black : Colors.white,
    surface: p.card,
    onSurface: p.text,
    surfaceContainerHighest: p.cardAlt,
    outline: p.borderStrong,
    outlineVariant: p.border,
    shadow: p.shadow,
  );
  final base = isDark ? ThemeData.dark() : ThemeData.light();
  return base.copyWith(
    brightness: p.brightness,
    scaffoldBackgroundColor: p.bg,
    primaryColor: p.primary,
    colorScheme: scheme,
    canvasColor: p.card,
    cardColor: p.card,
    dividerColor: p.border,
    shadowColor: p.shadow,
    splashColor: p.primaryTint,
    highlightColor: p.borderSoft,
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      elevation: 0,
      iconTheme: IconThemeData(color: p.textSecondary),
      titleTextStyle: TextStyle(
          color: p.text, fontSize: 20, fontWeight: FontWeight.bold),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(p.primary),
        foregroundColor: WidgetStateProperty.all(p.onPrimary),
        shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(foregroundColor: WidgetStateProperty.all(p.primary)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(p.primary),
        side: WidgetStateProperty.all(BorderSide(color: p.borderStrong)),
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1),
    iconTheme: IconThemeData(color: p.textSecondary),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark ? p.cardAlt : p.text,
      contentTextStyle: TextStyle(color: isDark ? p.text : p.card),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      titleTextStyle:
          TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700),
      contentTextStyle: TextStyle(color: p.textSecondary, fontSize: 14),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.card),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.primary,
      selectionColor: p.primaryTint,
      selectionHandleColor: p.primary,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.primary : p.textFaint),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.primaryTint : p.border),
    ),
    progressIndicatorTheme:
        ProgressIndicatorThemeData(color: p.primary, linearTrackColor: p.border),
    textTheme: base.textTheme.apply(
      bodyColor: p.text,
      displayColor: p.text,
      decorationColor: p.text,
    ),
    listTileTheme: ListTileThemeData(
      textColor: p.text,
      iconColor: p.textSecondary,
    ),
  );
}

/// 兼容旧调用点（测试、启动失败兜底）：默认深色主题。
ThemeData get darkTheme => buildAppTheme(appThemes.first.dark);

ThemeData get lightTheme => buildAppTheme(appThemes.first.light);

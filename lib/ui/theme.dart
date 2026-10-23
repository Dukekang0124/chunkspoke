import 'package:flutter/material.dart';

// M5 色彩令牌
const Color kBg = Color(0xFF0F0F1A); // 背景
const Color kCard = Color(0xFF1A1B2E); // 卡片
const Color kPrimary = Color(0xFFFFB84D); // 主强调（琥珀）
const Color kUnlocked = Color(0xFF34C77B); // 成功
const Color kError = Color(0xFFFF6B6B); // 错误（仅用于描边）
const Color kLocked = Color(0xFF3A3A52);
const Color kText = Colors.white;

/// 词块类型 → 视觉色（与 ChunkTile 形状编码配合，双重编码）。
Color chunkColor(String type) {
  switch (type) {
    case 'content':
      return kPrimary;
    case 'function':
      return kUnlocked;
    case 'connector':
      return Colors.white70;
    case 'timeplace':
      return kError;
    default:
      return kText;
  }
}

/// 词块类型 → 圆角（形状编码）。
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

ThemeData darkTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: kBg,
  primaryColor: kPrimary,
  colorScheme: const ColorScheme.dark(
    primary: kPrimary,
    secondary: kUnlocked,
    surface: kCard,
    error: kError,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: kBg,
    elevation: 0,
    iconTheme: IconThemeData(color: Colors.white70),
    titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.all(kPrimary),
      foregroundColor: WidgetStateProperty.all(Colors.black87),
      shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
  ),
);

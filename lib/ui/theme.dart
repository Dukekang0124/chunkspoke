import 'package:flutter/material.dart';

// 全局颜色（继承 v1.0）
const Color kBg = Color(0xFF0F0F1A);
const Color kPrimary = Color(0xFF6366F1);
const Color kUnlocked = Color(0xFF22C55E);
const Color kLocked = Color(0xFF4B5563);

// 词块类型 → 颜色（四色双重编码 · 颜色层）
const Map<String, Color> kChunkColor = {
  'content': Color(0xFF10B981),
  'function': Color(0xFF3B82F6),
  'connector': Color(0xFF8B5CF6),
  'timeplace': Color(0xFFF59E0B),
};

Color chunkColor(String type) => kChunkColor[type] ?? kPrimary;

// 词块类型 → 形状/圆角（四色双重编码 · 形状层）
BorderRadius chunkRadius(String type) {
  switch (type) {
    case 'content':
      return BorderRadius.circular(999); // 胶囊全圆角
    case 'function':
      return BorderRadius.circular(4); // 切角矩形（近似小圆角）
    case 'connector':
      return BorderRadius.circular(8); // 半圆角，整体小一号
    case 'timeplace':
      return BorderRadius.circular(10); // 标准圆角 + 描边
    default:
      return BorderRadius.circular(10);
  }
}

// 词块字号（内容词块最大，连接词块小一号）
double chunkFontSize(String type) {
  switch (type) {
    case 'content':
      return 20;
    case 'function':
      return 17;
    case 'connector':
      return 15;
    case 'timeplace':
      return 17;
    default:
      return 17;
  }
}

final ThemeData darkTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: kBg,
  primaryColor: kPrimary,
  colorScheme: const ColorScheme.dark().copyWith(
    primary: kPrimary,
    surface: Color(0xFF1A1A2E),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: kBg,
    elevation: 0,
    centerTitle: true,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(color: Colors.white),
    bodyLarge: TextStyle(color: Colors.white),
  ),
  useMaterial3: true,
);

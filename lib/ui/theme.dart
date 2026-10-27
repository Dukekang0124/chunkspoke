import 'package:flutter/material.dart';

// 与 App 同源的颜色令牌（值复制自 D:\cs_build\lib\ui\theme.dart，不 import App 文件）
const Color kBg = Color(0xFF0F0F1A);
const Color kCard = Color(0xFF1A1B2E);
const Color kPrimary = Color(0xFFFFB84D);
const Color kUnlocked = Color(0xFF34C77B);
const Color kError = Color(0xFFFF6B6B);
const Color kLocked = Color(0xFF3A3A52);
const Color kText = Colors.white;

// 词块类型视觉映射（与 App 同一套形状编码）
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

ThemeData buildWebTheme() => ThemeData(
      brightness: Brightness.dark,
      // 本地子集字体：CanvasKit 缺字形时会去 fonts.gstatic.com 拉 Noto，国内网络不可达
      fontFamily: 'NotoSansSC',
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
        // 这里会整体替换标题区的 TextStyle，必须显式带上字体，否则回退到平台默认字体
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          fontFamily: 'NotoSansSC',
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.all(kPrimary),
          foregroundColor: WidgetStateProperty.all(Colors.black87),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );

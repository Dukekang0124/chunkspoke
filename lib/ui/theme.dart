import 'package:flutter/material.dart';

// M5 色彩令牌
const Color kBg = Color(0xFF0F0F1A); // 背景
const Color kCard = Color(0xFF1A1B2E); // 卡片
const Color kPrimary = Color(0xFFFFB84D); // 主强调（琥珀）
const Color kUnlocked = Color(0xFF34C77B); // 成功
const Color kError = Color(0xFFFF6B6B); // 错误（仅用于描边）
const Color kLocked = Color(0xFF3A3A52);
const Color kText = Colors.white;

ThemeData darkTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: kBg,
  primaryColor: kPrimary,
  colorScheme: ColorScheme.dark(
    primary: kPrimary,
    secondary: kUnlocked,
    background: kBg,
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
      backgroundColor: MaterialStateProperty.all(kPrimary),
      foregroundColor: MaterialStateProperty.all(Colors.black87),
      shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
  ),
);

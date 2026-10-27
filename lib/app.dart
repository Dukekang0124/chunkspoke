import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'app/router.dart';
import 'app/session.dart';
import 'ui/theme.dart';

/// 中文单语：显式 locale，否则引擎按 navigator.language 把 `<html lang>` 改成 en-US。
/// 同时必须给 zh 的 Material/Cupertino/Widgets 本地化代理，否则 TextField、
/// 选择菜单等 Material 组件拿不到 MaterialLocalizations 会直接构建失败。
const List<Locale> kWebSupportedLocales = [Locale('zh', 'CN')];
const List<LocalizationsDelegate<dynamic>> kWebLocalizationsDelegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

class ChunkSpokeWebApp extends StatefulWidget {
  const ChunkSpokeWebApp({super.key});

  @override
  State<ChunkSpokeWebApp> createState() => _ChunkSpokeWebAppState();
}

class _ChunkSpokeWebAppState extends State<ChunkSpokeWebApp> {
  late final AppSession _session;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _session = AppSession();
    _router = buildRouter(_session);
    unawaited(_session.bootstrap());
  }

  @override
  void dispose() {
    _router.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ChunkSpoke 网页版',
      debugShowCheckedModeBanner: false,
      // 中文单语产品：显式 locale，否则引擎按 navigator.language 把 <html lang> 改成 en-US。
      // 同时必须给 zh 的 Material/Cupertino/Widgets 本地化代理，否则 TextField、
      // 选择菜单等 Material 组件拿不到 MaterialLocalizations 会直接构建失败。
      locale: const Locale('zh', 'CN'),
      supportedLocales: kWebSupportedLocales,
      localizationsDelegates: kWebLocalizationsDelegates,
      theme: buildWebTheme(),
      routerConfig: _router,
    );
  }
}

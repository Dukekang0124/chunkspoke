import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ui/theme.dart';

/// 主题选择与持久化。
///
/// 为什么需要「整树重建」：本项目的历史代码使用全局颜色令牌（kBg/kText/…）
/// 而不是 Theme.of(context)，大量组件还是 const。只调用 notifyListeners 时，
/// 没有监听主题的 const 子树不会重画，切换后会出现半新半旧的界面。
/// 因此每次切换都对 rootElement 做一次标记重建，保留导航栈（不像换 key 那样
/// 把用户从设置页踢回首页）。
///
/// 存储走 ProgressService（SQLite kv），不新增 shared_preferences 原生依赖；
/// 读/写以闭包注入，单测可直接用内存实现。
class ThemeProvider extends ChangeNotifier {
  ThemeProvider({
    String? initialId,
    String? initialMode,
    Future<void> Function(String id)? persistId,
    Future<void> Function(String mode)? persistMode,
  })  : _persistId = persistId,
        _persistMode = persistMode {
    final theme = themeById(initialId);
    _themeId = theme.id;
    // 兼容任务书写法的 id（nude_rose_light / ocean_dark）：id 里带模式时以 id 为准。
    if (initialMode == null && initialId != null) {
      _brightness = brightnessFromId(initialId);
    } else {
      _brightness = initialMode == 'light' ? Brightness.light : Brightness.dark;
    }
    applyPalette(theme.paletteFor(_brightness));
  }

  final Future<void> Function(String id)? _persistId;
  final Future<void> Function(String mode)? _persistMode;

  late String _themeId;
  late Brightness _brightness;

  String get themeId => _themeId;
  Brightness get brightness => _brightness;
  bool get isDark => _brightness == Brightness.dark;

  AppTheme get currentTheme => themeById(_themeId);
  AppPalette get palette => currentTheme.paletteFor(_brightness);

  ThemeData get lightThemeData =>
      buildAppTheme(currentTheme.paletteFor(Brightness.light));
  ThemeData get darkThemeData =>
      buildAppTheme(currentTheme.paletteFor(Brightness.dark));
  ThemeMode get themeMode =>
      isDark ? ThemeMode.dark : ThemeMode.light;

  Future<void> setTheme(String id) async {
    final next = themeById(id);
    if (next.id == _themeId) return;
    _themeId = next.id;
    _commit();
    await _persistId?.call(_themeId);
  }

  Future<void> setBrightness(Brightness b) async {
    if (b == _brightness) return;
    _brightness = b;
    _commit();
    await _persistMode?.call(isDark ? 'dark' : 'light');
  }

  Future<void> setDark(bool dark) =>
      setBrightness(dark ? Brightness.dark : Brightness.light);

  void _commit() {
    applyPalette(palette);
    notifyListeners();
    _rebuildAll();
  }

  void _rebuildAll() {
    void run() {
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) return;
      void visit(Element e) {
        if (!e.mounted) return;
        e.markNeedsBuild();
        e.visitChildren(visit);
      }

      root.visitChildren(visit);
      WidgetsBinding.instance.scheduleFrame();
    }

    // 点击回调里立刻标记（下一帧就重画）；万一处在帧回调阶段则推到帧尾，
    // 避免 markNeedsBuild 在 build 过程中抛异常。
    switch (WidgetsBinding.instance.schedulerPhase) {
      case SchedulerPhase.idle:
      case SchedulerPhase.postFrameCallbacks:
        run();
      default:
        WidgetsBinding.instance.addPostFrameCallback((_) => run());
    }
  }
}

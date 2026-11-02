import 'package:chunkspoke_flutter/services/theme_provider.dart';
import 'package:chunkspoke_flutter/ui/theme.dart';
import 'package:chunkspoke_flutter/ui/theme_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 对比度计算：直接用 Flutter 自带的 computeLuminance，避免自造轮子取错通道量程。
/// 半透明文字要先按底色合成，否则 computeLuminance 只看 RGB、忽略 alpha，
/// 会把「60% 白压在深底上」算成纯白，对比度虚高。
Color _blend(Color bg, Color fg) => Color.lerp(bg, fg, fg.a)!;

double _contrast(Color a, Color b) {
  final l1 = _blend(b, a).computeLuminance(), l2 = b.computeLuminance();
  final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

/// 故意不监听主题、且用 const 构造的探针组件：
/// 用来证明「切主题后整树重建」真的把这些组件也重画了。
class _Probe extends StatelessWidget {
  const _Probe();
  @override
  Widget build(BuildContext context) => ColoredBox(
        color: kBg,
        child: Text('probe', style: TextStyle(color: kText)),
      );
}

Color _probeBg(WidgetTester tester) => tester
    .widget<ColoredBox>(find
        .descendant(of: find.byType(_Probe), matching: find.byType(ColoredBox)))
    .color;

Color _probeFg(WidgetTester tester) =>
    tester.widget<Text>(find.text('probe')).style!.color!;

/// 与真机 main.dart 同构：MaterialApp 挂 theme/darkTheme/themeMode。
class _TestApp extends StatelessWidget {
  const _TestApp({required this.home});
  final Widget home;
  @override
  Widget build(BuildContext context) {
    final t = Provider.of<ThemeProvider>(context);
    return MaterialApp(
      theme: t.lightThemeData,
      darkTheme: t.darkThemeData,
      themeMode: t.themeMode,
      home: home,
    );
  }
}

const List<String> _allIds = [
  'default',
  'nude_rose',
  'sage',
  'plum',
  'ocean',
  'forest',
  'charcoal',
];

void main() {
  setUp(() => applyPalette(appThemes.first.dark));
  tearDown(() => applyPalette(appThemes.first.dark));

  group('色板定义（7 套 × 浅/深）', () {
    test('正好 7 套、id 唯一、浅深齐全', () {
      expect(appThemes.map((t) => t.id).toList(), _allIds);
      for (final t in appThemes) {
        expect(t.light.brightness, Brightness.light);
        expect(t.dark.brightness, Brightness.dark);
      }
    });

    test('每套色板的令牌都有实际不透明取值，且底色≠卡色', () {
      for (final t in appThemes) {
        for (final p in [t.light, t.dark]) {
          for (final c in [
            p.bg, p.card, p.cardAlt, p.primary, p.onPrimary, p.text,
            p.textSecondary, p.textMuted, p.textFaint, p.borderStrong,
            p.info, p.success, p.error, p.warning,
          ]) {
            expect(c.a, greaterThan(0.0),
                reason: '${p.label}/${p.brightness.name} 存在缺失或透明色');
          }
          expect(p.bg, isNot(p.card), reason: '${p.label} 底色与卡色相同');
        }
      }
    });

    test('浅色主题无「白字白底」：文字对比度达标', () {
      for (final t in appThemes) {
        for (final p in [t.light, t.dark]) {
          final tag = '${p.label}·${p.brightness.name}';
          expect(_contrast(p.text, p.bg), greaterThanOrEqualTo(4.5),
              reason: '$tag 主文字对比不足');
          expect(_contrast(p.text, p.card), greaterThanOrEqualTo(4.5),
              reason: '$tag 主文字在卡片上对比不足');
          expect(_contrast(p.textSecondary, p.bg), greaterThanOrEqualTo(3.0),
              reason: '$tag 次要文字对比不足');
          expect(_contrast(p.textMuted, p.bg), greaterThanOrEqualTo(3.0),
              reason: '$tag 说明文字对比不足');
          expect(_contrast(p.onPrimary, p.primary), greaterThanOrEqualTo(3.0),
              reason: '$tag 主按钮前景对比不足');
          expect(_contrast(p.onPrimary, p.success),
              greaterThanOrEqualTo(2.6),
              reason: '$tag 成功色底上的按钮文字对比不足');
          expect(_contrast(p.primary, p.bg), greaterThanOrEqualTo(2.2),
              reason: '$tag 主色在底色上不可见');
        }
      }
    });

    test('四色词块：颜色跟着主题走，形状/字号不跟（双重编码保留）', () {
      const types = ['content', 'function', 'connector', 'timeplace', 'other'];
      final shapes = [for (final t in types) chunkRadius(t).topLeft.x];
      final fonts = [for (final t in types) chunkFontSize(t)];
      applyPalette(appThemes.first.dark);
      expect([for (final t in types) chunkColor(t)],
          [kPrimary, kUnlocked, kTextSecondary, kError, kText]);
      applyPalette(appThemes[4].light); // 深海蓝浅色
      expect([for (final t in types) chunkColor(t)],
          [kPrimary, kUnlocked, kTextSecondary, kError, kText]);
      expect(chunkColor('content'), isNot(const Color(0xFFFFB84D)),
          reason: '浅色主题下主色仍是默认深色琥珀 = 没跟随主题');
      expect([for (final t in types) chunkRadius(t).topLeft.x], shapes,
          reason: '形状编码不得随主题变化');
      expect([for (final t in types) chunkFontSize(t)], fonts);
    });

    test('token getter 永远等于 activePalette 对应字段（无缓存脏值）', () {
      for (final t in appThemes) {
        for (final p in [t.light, t.dark]) {
          applyPalette(p);
          expect(kBg, p.bg);
          expect(kCard, p.card);
          expect(kPrimary, p.primary);
          expect(kText, p.text);
          expect(kTextSecondary, p.textSecondary);
          expect(kTextMuted, p.textMuted);
          expect(kUnlocked, p.success);
          expect(kError, p.error);
          expect(kBorder, p.border);
          expect(kInfo, p.info);
        }
      }
    });
  });

  group('ThemeProvider', () {
    test('缺省 = 墨蓝琥珀深色（升级前后观感一致）', () {
      final p = ThemeProvider();
      expect(p.themeId, 'default');
      expect(p.isDark, isTrue);
      expect(p.palette.bg, const Color(0xFF0F0F1A));
      expect(p.palette.primary, const Color(0xFFFFB84D));
      expect(p.themeMode, ThemeMode.dark);
      expect(activePalette, p.palette);
    });

    test('兼容任务书旧 id（default_dark / nude_rose_light）', () {
      expect(ThemeProvider(initialId: 'default_dark').themeId, 'default');
      final rose = ThemeProvider(initialId: 'nude_rose_light');
      expect(rose.themeId, 'nude_rose');
      expect(rose.isDark, isFalse);
      expect(rose.palette.bg, const Color(0xFFF7F3EF));
      expect(activePalette.bg, const Color(0xFFF7F3EF));
    });

    test('脏 id / 空值回落默认深色，不抛异常', () {
      expect(ThemeProvider(initialId: 'not_a_theme').themeId, 'default');
      expect(ThemeProvider(initialMode: 'garbage').isDark, isTrue);
    });

    test('切主题：令牌即刻生效 + 通知一次 + 持久化 app_theme_id', () async {
      final saved = <String>[];
      final p = ThemeProvider(persistId: (id) async => saved.add(id));
      var notified = 0;
      p.addListener(() => notified++);
      await p.setTheme('ocean');
      expect(p.themeId, 'ocean');
      expect(notified, 1);
      expect(kBg, const Color(0xFF0D1622));
      expect(saved, ['ocean']);
    });

    test('深浅切换：取对应色板并写回 app_theme_mode', () async {
      final modes = <String>[];
      final p =
          ThemeProvider(initialId: 'forest', persistMode: (m) async => modes.add(m));
      expect(p.palette.bg, const Color(0xFF101A15));
      await p.setDark(false);
      expect(p.palette.bg, const Color(0xFFF3F5F2));
      expect(p.themeMode, ThemeMode.light);
      expect(modes, ['light']);
    });

    test('同值重复设置不重复通知（不做无谓整树重建）', () async {
      final p = ThemeProvider();
      var notified = 0;
      p.addListener(() => notified++);
      await p.setTheme('default');
      await p.setDark(true);
      expect(notified, 0);
    });

    test('lightThemeData / darkThemeData 与当前主题配对，不串色', () {
      final p = ThemeProvider(initialId: 'plum');
      expect(p.lightThemeData.scaffoldBackgroundColor, const Color(0xFFF5F0F2));
      expect(p.darkThemeData.scaffoldBackgroundColor, const Color(0xFF241E22));
      expect(p.darkThemeData.colorScheme.primary, const Color(0xFFC49BAE));
      expect(p.lightThemeData.brightness, Brightness.light);
    });

    test('重启恢复：读回上次 id + mode', () {
      final restored = ThemeProvider(initialId: 'sage', initialMode: 'light');
      expect(restored.themeId, 'sage');
      expect(restored.isDark, isFalse);
      expect(kBg, const Color(0xFFF4F4F1));
    });
  });

  group('端到端：切主题后 const 组件也跟着重画', () {
    testWidgets('探针组件背景/文字色随主题变化', (tester) async {
      final p = ThemeProvider();
      await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>.value(
        value: p,
        child: const _TestApp(home: Scaffold(body: _Probe())),
      ));
      Color bg() => _probeBg(tester);
      Color fg() => _probeFg(tester);
      expect(bg(), const Color(0xFF0F0F1A));
      expect(fg(), Colors.white);

      await p.setTheme('ocean');
      await p.setDark(false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(bg(), const Color(0xFFF2F5F8));
      expect(fg(), const Color(0xFF1A2332));
      expect(tester.takeException(), isNull);
    });

    testWidgets('7 套主题 × 浅深逐个切一遍都不报错', (tester) async {
      final p = ThemeProvider();
      await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>.value(
        value: p,
        child: const _TestApp(home: Scaffold(body: _Probe())),
      ));
      for (final id in _allIds) {
        for (final dark in [true, false]) {
          await p.setTheme(id);
          await p.setDark(dark);
          await tester.pump();
          final t = themeById(id);
          expect(_probeBg(tester),
              t.paletteFor(dark ? Brightness.dark : Brightness.light).bg,
              reason: '$id ${dark ? 'dark' : 'light'} 背景未跟随');
        }
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('设置页「外观与主题」卡片（真组件）', () {
    Future<ThemeProvider> host(WidgetTester tester,
        {ThemeProvider? provider}) async {
      final p = provider ?? ThemeProvider();
      await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>.value(
        value: p,
        child: MaterialApp(
          theme: p.lightThemeData,
          darkTheme: p.darkThemeData,
          themeMode: p.themeMode,
          home: const Scaffold(
              body: SingleChildScrollView(child: ThemeCard())),
        ),
      ));
      return p;
    }

    testWidgets('正好 7 个色板、id 与色板表一致', (tester) async {
      await host(tester);
      expect(find.byKey(const ValueKey('theme-card')), findsOneWidget);
      for (final id in _allIds) {
        expect(find.byKey(ValueKey('theme-swatch-$id')), findsOneWidget,
            reason: '色板 $id 缺失');
      }
      expect(find.byKey(const ValueKey('theme-swatch-banana')), findsNothing);
    });

    testWidgets('色板是 48px 圆 + 双色预览（底色 + 主色）', (tester) async {
      await host(tester);
      final box = tester.getSize(find
          .descendant(
              of: find.byKey(const ValueKey('theme-swatch-ocean')),
              matching: find.byType(Container))
          .first);
      expect(box, const Size(48, 48));
    });

    testWidgets('点色板 → 即时切换并持久化 id', (tester) async {
      final saved = <String>[];
      final p = ThemeProvider(persistId: (id) async => saved.add(id));
      await host(tester, provider: p);
      await tester.tap(find.byKey(const ValueKey('theme-swatch-sage')));
      await tester.pump();
      expect(p.themeId, 'sage');
      expect(saved, ['sage']);
      expect(kBg, const Color(0xFF1E2220));
    });

    testWidgets('深色 / 浅色两个模式键都可用', (tester) async {
      final saved = <String>[];
      final p = ThemeProvider(persistMode: (m) async => saved.add(m));
      await host(tester, provider: p);
      await tester.tap(find.byKey(const ValueKey('theme-mode-light')));
      await tester.pump();
      expect(p.isDark, isFalse);
      expect(saved, ['light']);
      await tester.tap(find.byKey(const ValueKey('theme-mode-dark')));
      await tester.pump();
      expect(p.isDark, isTrue);
      expect(saved, ['light', 'dark']);
    });

    testWidgets('选中态用主题主色描边，未选中用中性描边', (tester) async {
      final p = ThemeProvider(initialId: 'nude_rose');
      await host(tester, provider: p);
      Border frame(String id) {
        final c = tester
            .widgetList<Container>(find.descendant(
                of: find.byKey(ValueKey('theme-swatch-$id')),
                matching: find.byType(Container)))
            .first;
        return (c.decoration! as BoxDecoration).border! as Border;
      }

      expect(frame('nude_rose').top.color, kPrimary);
      expect(frame('nude_rose').top.width,
          greaterThan(frame('ocean').top.width));
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/pronunciation_score.dart';
import 'package:chunkspoke_flutter/ui/pron_result_card.dart';
import 'package:chunkspoke_flutter/ui/theme.dart';

/// 发音评测结果卡三档配色（1.5.9）。模拟器无法说话，逐词着色改由本用例直接
/// 渲染 `PronResultCard` 断言颜色，避免「看截图猜颜色」。
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(backgroundColor: kBg, body: child),
      );

  /// 取某个词 chip 的文字颜色。
  Color colorOf(WidgetTester tester, String word) =>
      tester.widget<Text>(find.text(word)).style!.color!;

  testWidgets('三档着色：绿=实词命中 / 黄=虚词或近似 / 红=实词说错', (tester) async {
    // 目标 "i want to go home"；识别里漏掉了虚词 to。
    final r = scorePronunciation(
      target: 'i want to go home',
      recognized: 'i want go home',
    );
    await tester.pumpWidget(host(PronResultCard(result: r)));

    expect(colorOf(tester, 'want'), kUnlocked);
    expect(colorOf(tester, 'go'), kUnlocked);
    expect(colorOf(tester, 'to'), kPrimary, reason: '虚词漏说落黄档，不判错');
    expect(find.textContaining('绿 4 · 黄 1 · 红 0'), findsOneWidget);
  });

  testWidgets('实词说错标红且整句判「再练一次」', (tester) async {
    final r = scorePronunciation(
      target: 'my name is lily',
      recognized: 'my name is lucy',
    );
    await tester.pumpWidget(host(PronResultCard(result: r)));

    expect(colorOf(tester, 'lily'), kError);
    expect(r.passed, isFalse);
    expect(find.textContaining('再练一次'), findsOneWidget);
    expect(find.textContaining('红 1'), findsOneWidget);
  });

  testWidgets('满分显示「通过 · 清楚」与整体分', (tester) async {
    final r = scorePronunciation(
      target: 'thank you so much',
      recognized: 'thank you so much',
    );
    await tester.pumpWidget(host(PronResultCard(result: r)));

    expect(find.text('100'), findsOneWidget);
    expect(find.textContaining('通过 · 清楚'), findsOneWidget);
    expect(find.textContaining('绿 4 · 黄 0 · 红 0'), findsOneWidget);
  });

  testWidgets('没听到：显示提示卡而非分数', (tester) async {
    final r = scorePronunciation(target: 'good morning', recognized: '');
    await tester.pumpWidget(host(PronResultCard(result: r)));

    expect(find.text('没听到声音'), findsOneWidget);
    expect(find.textContaining('分'), findsNothing);
  });
}

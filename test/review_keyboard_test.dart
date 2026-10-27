import 'package:chunkspoke_web/app/session.dart';
import 'package:chunkspoke_web/screens/review_screen.dart';
import 'package:chunkspoke_web/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('键盘流：空格翻面 / 1-3 自评计数 / Enter 下一个', (tester) async {
    final session = AppSession();
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWebTheme(),
        home: ReviewScreen(session: session),
      ),
    );
    await tester.pump();

    expect(find.text('get up'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('起床；站起来'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pump();
    expect(session.reviewedToday.value, 1);
    expect(find.textContaining('本次已评 1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('on the way to work'), findsOneWidget);
    expect(find.textContaining('本次已评 1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pump();
    expect(session.reviewedToday.value, 2);
  });
}

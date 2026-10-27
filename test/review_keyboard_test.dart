import 'package:chunkspoke_web/app/session.dart';
import 'package:chunkspoke_web/data/content.dart';
import 'package:chunkspoke_web/data/vocab.dart';
import 'package:chunkspoke_web/screens/review_screen.dart';
import 'package:chunkspoke_web/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内容包走真实资产（需要真实 IO），所以用 runAsync 载入一次后注入会话。
Future<ContentBundle> _bundle(WidgetTester tester) async =>
    (await tester.runAsync(ContentBundle.load))!;

/// 桌面尺寸 + Scaffold（应用里由 AppWebShell 提供 Material 与宽度）。
Future<void> _pumpReview(WidgetTester tester, AppSession session) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildWebTheme(),
      home: Scaffold(body: ReviewScreen(session: session)),
    ),
  );
}

Future<AppSession> _sessionWithDueChunk(WidgetTester tester) async {
  var now = DateTime(2026, 10, 27, 9);
  final session = AppSession(
    clock: () => now,
    preloadedContent: await _bundle(tester),
  );
  await session.bootstrap();
  final chunk = session.content!.chunks.first;
  await session.learnChunk(chunk);
  now = now.add(const Duration(days: 1, minutes: 1));
  return session;
}

void main() {
  testWidgets('键盘流：空格翻面 / 3 通过计数 / Enter 收尾', (tester) async {
    final session = await _sessionWithDueChunk(tester);
    addTearDown(session.dispose);
    final chunk = session.content!.chunks.first;
    expect(session.dueChunks().map((r) => r.id), [chunk.id]);

    await _pumpReview(tester, session);
    await tester.pump();

    expect(find.text(chunk.text), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text(chunk.meaningCN), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pumpAndSettle();
    expect(session.reviewedToday.value, 1);
    expect(find.textContaining('本次 1'), findsOneWidget);
    expect(session.chunks[chunk.id]!.reviewStage, 1);
    expect(session.chunks[chunk.id]!.assetState, AssetState.consolidated);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('这一轮清完了'), findsOneWidget);
  });

  testWidgets('零数据空态指引 → 去新学 → Enter 记为已认识', (tester) async {
    final session = AppSession(
      clock: () => DateTime(2026, 10, 27, 9),
      preloadedContent: await _bundle(tester),
    );
    addTearDown(session.dispose);
    await session.bootstrap();

    await _pumpReview(tester, session);
    await tester.pumpAndSettle();

    expect(find.text('今天没有到期词块'), findsOneWidget);
    expect(find.textContaining('先去「新学」认识 1 块'), findsOneWidget);

    await tester.tap(find.text('去新学'));
    await tester.pumpAndSettle();

    final first = session.newChunks().first;
    expect(find.text(first.text), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final row = session.chunks[first.id]!;
    expect(row.assetState, AssetState.consolidating);
    expect(row.reviewStage, 0);
    expect(row.dueDate, greaterThan(0));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/level.dart';
import 'package:chunkspoke_flutter/services/session_report.dart';

/// P0 回归：会话战报页同时驱动「彩带」与「徽章」两个 AnimationController。
/// 挂 SingleTickerProviderStateMixin 时，建第二个 ticker 即抛错 → 每次通关必崩。
void main() {
  final level = Level(
    id: 'A',
    theme: 'Greetings',
    sceneImage: '',
    chunks: [
      Chunk.fromJson({
        'id': 'a01',
        'text': 'Good morning',
        'type': 'content',
        'meaningCN': '早上好'
      })
    ],
  );

  final next = Level(
    id: 'B',
    theme: 'Asking for things',
    sceneImage: '',
    chunks: [
      Chunk.fromJson({
        'id': 'b01',
        'text': "I'd like",
        'type': 'function',
        'meaningCN': '我想要'
      })
    ],
  );

  Future<void> pumpCompletion(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompletionView(
          level: level,
          dims: const [true, false, true, false],
          report: const SessionReport(
              newMastered: 3,
              spoken: 7,
              maxCombo: 4,
              completed: 3,
              starChunks: 2),
          nextReview: '10月21日',
          nextScene: next,
          nextUnlocked: true,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('战报页双动画共存不崩，且展示真实达成星与战报', (tester) async {
    await pumpCompletion(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('关卡完成！'), findsOneWidget);
    expect(find.text('本次战报'), findsOneWidget);
    expect(find.text('本次完成'), findsOneWidget);
    expect(find.text('3 块'), findsOneWidget);
    expect(find.text('四星全绿'), findsOneWidget);
    expect(find.text('2 块'), findsOneWidget);
    expect(find.text('下次复习'), findsOneWidget);
    expect(find.text('10月21日'), findsOneWidget);
    expect(find.text('下一场景已解锁：索取东西'), findsOneWidget);
    expect(find.text('继续学习：索取东西'), findsOneWidget);
    expect(find.text('返回地图'), findsOneWidget);

    // 诚实星制：dims 只有第 1、3 项达成 → 2 亮 2 灰。
    expect(find.byIcon(Icons.star), findsNWidgets(2));
    expect(find.byIcon(Icons.star_border), findsNWidgets(2));
  });

  testWidgets('下一场景未达 80% 时不渲染解锁横幅，改为差额提示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompletionView(
          level: level,
          dims: const [true, false, false, false],
          report: const SessionReport(),
          nextScene: next,
          nextUnlocked: false,
          nextMissing: 1,
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('下一场景已解锁'), findsNothing);
    expect(find.textContaining('再达标 1 块解锁「索取东西」'), findsOneWidget);
    expect(find.textContaining('继续学习'), findsNothing);
    expect(find.text('再练一遍本场景'), findsOneWidget);
    expect(find.text('返回地图'), findsOneWidget);
  });

  testWidgets('最后一关无下一场景时不渲染解锁横幅', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompletionView(
          level: level,
          dims: const [true, true, true, true],
          report: const SessionReport(),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('下一场景已解锁'), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/pronunciation_screen.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';

/// 发音评测入口冒烟：选句列表 → 进入跟读页（不点录音，不碰平台通道）。
class _FakeTtsAdapter implements TtsAdapter {
  @override
  Future<String?> getDefaultEngine() async => null;
  @override
  Future<List<String>> getEngines() async => const [];
  @override
  Future<bool> isLanguageAvailable(String lang) async => true;
  @override
  Future<bool> setLanguage(String lang) async => true;
  @override
  Future<void> setEngine(String engine) async {}
  @override
  Future<void> setSpeechRate(double rate) async {}
  @override
  Future<void> setPitch(double pitch) async {}
  @override
  Future<int> speak(String text) async => 1;
  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('选一句 → 进入跟读页；三档说明在列表底部', (tester) async {
    final content = ContentPack(version: 'test', levels: [
      Level(
        id: 'l1',
        theme: '打招呼',
        sceneImage: '',
        chunks: const [],
        sentences: [
          TargetSentence(
              id: 's1',
              text: 'good morning',
              meaningCN: '早上好',
              chunkIds: const []),
        ],
      ),
    ]);
    final tts = TtsService(adapter: _FakeTtsAdapter());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ContentPack>.value(value: content),
          Provider<TtsService>.value(value: tts),
        ],
        child: const MaterialApp(home: PronunciationScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('发音评测'), findsOneWidget);
    expect(find.text('打招呼'), findsOneWidget);
    expect(find.text('good morning'), findsOneWidget);
    expect(find.text('早上好'), findsOneWidget);
    expect(find.textContaining('绿=说对了'), findsOneWidget);

    await tester.tap(find.text('good morning'));
    await tester.pump();

    expect(find.text('跟读这一句'), findsOneWidget);
    expect(find.text('听示范'), findsOneWidget);
    expect(find.text('换一句'), findsOneWidget);
    expect(find.text('点一下开始跟读'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);

    // 换一句回到列表。
    await tester.tap(find.text('换一句'));
    await tester.pump();
    expect(find.text('打招呼'), findsOneWidget);
  });
}

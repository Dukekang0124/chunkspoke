import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/learning_flow.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/speech.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';
import 'package:chunkspoke_flutter/steps/substitute_step.dart';

class _FakeTts implements TtsAdapter {
  @override
  Future<String?> getDefaultEngine() async => 'fake-tts';
  @override
  Future<List<String>> getEngines() async => const ['fake-tts'];
  @override
  Future<bool> isLanguageAvailable(String lang) async => lang == 'en-US';
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

class _FakeTranscriber implements Transcriber {
  _FakeTranscriber(this.text);

  final String text;

  @override
  Future<bool> init() async => true;
  @override
  bool get isReady => true;
  @override
  bool get failed => false;
  @override
  Future<VoskResult> transcribe(String wavPath, List<String> phrases) async =>
      VoskResult(text, 1.0);
}

Chunk _chunk(String id, String text) =>
    Chunk.fromJson({'id': id, 'text': text, 'type': 'content', 'meaningCN': ''});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const permCh = MethodChannel('flutter.baseflow.com/permissions/methods');
  const pathCh = MethodChannel('plugins.flutter.io/path_provider');
  const recCh = MethodChannel('chunkspoke/recorder');

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permCh, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return 1; // granted
        case 'requestPermissions':
          return <int, int>{1: 1};
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(pathCh, (call) async {
      if (call.method == 'getTemporaryDirectory') return '/tmp';
      return null;
    });
    messenger.setMockMethodCallHandler(recCh, (call) async {
      if (call.method == 'stop') return '/tmp/fake.wav';
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permCh, null);
    messenger.setMockMethodCallHandler(pathCh, null);
    messenger.setMockMethodCallHandler(recCh, null);
    SpeechService.debugTranscriberOverride = null;
  });

  testWidgets('定向替换识别通过 → 进入成功态并可提交', (tester) async {
    SpeechService.debugTranscriberOverride =
        _FakeTranscriber('Good evening, everyone.');

    final chunk = _chunk('a01', 'Good morning');
    final other = _chunk('a02', 'Good evening');
    final level = Level(
      id: 'A',
      theme: 'Greetings',
      sceneImage: '',
      chunks: [chunk, other],
      sentences: [
        TargetSentence(
            id: 's1',
            text: 'Good morning, everyone.',
            meaningCN: '大家早上好',
            chunkIds: ['a01']),
      ],
    );
    final plan = buildSubstitutionPlan(
        chunk: chunk, sentence: level.sentences.first, allChunks: level.chunks);
    expect(plan.isFallback, isFalse);
    expect(plan.replacement, 'Good evening');

    int? passedWith;
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<TtsService>.value(value: TtsService(adapter: _FakeTts())),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SubstituteStep(
            chunk: chunk,
            level: level,
            plan: plan,
            onPass: (acc) => passedWith = acc,
            onSkip: () {},
          ),
        ),
      ),
    ));

    // 等权限与识别引擎初始化落地（真实异步 → 需要多帧）。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('开口说这句').evaluate().isNotEmpty) break;
    }
    expect(find.text('开口说这句'), findsOneWidget);

    await tester.tap(find.text('开口说这句'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在录音 · 说完点停止'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    // 至少 0.4s 录音等待 + 识别。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('替换成功，句子说完整了'), findsOneWidget);
    expect(find.text('完成替换 · 下一步'), findsOneWidget);
    expect(find.text('开口说这句'), findsNothing);

    await tester.tap(find.text('完成替换 · 下一步'));
    await tester.pump();
    expect(passedWith, 100);
  });

  testWidgets('定向替换识别不到替换词 → 保留重试入口并给友好提示', (tester) async {
    SpeechService.debugTranscriberOverride =
        _FakeTranscriber('Good morning, everyone.');

    final chunk = _chunk('a01', 'Good morning');
    final other = _chunk('a02', 'Good evening');
    final level = Level(
      id: 'A',
      theme: 'Greetings',
      sceneImage: '',
      chunks: [chunk, other],
      sentences: [
        TargetSentence(
            id: 's1',
            text: 'Good morning, everyone.',
            meaningCN: '大家早上好',
            chunkIds: ['a01']),
      ],
    );
    final plan = buildSubstitutionPlan(
        chunk: chunk, sentence: level.sentences.first, allChunks: level.chunks);

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<TtsService>.value(value: TtsService(adapter: _FakeTts())),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SubstituteStep(
            chunk: chunk,
            level: level,
            plan: plan,
            onPass: (_) {},
            onSkip: () {},
          ),
        ),
      ),
    ));

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('开口说这句').evaluate().isNotEmpty) break;
    }
    await tester.tap(find.text('开口说这句'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('替换的「Good evening」还没听到'), findsOneWidget);
    expect(find.text('开口说这句'), findsOneWidget);
    expect(find.text('完成替换 · 下一步'), findsNothing);
  });
}

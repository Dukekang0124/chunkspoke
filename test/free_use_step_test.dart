import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/speech.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';
import 'package:chunkspoke_flutter/steps/free_use_step.dart';

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
  @override
  Future<VoskResult> transcribeOpen(String wavPath) =>
      transcribe(wavPath, const []);
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

  testWidgets('ASR-233：第6步空转写 → 机器自证卡可直接确认通过', (tester) async {
    SpeechService.debugTranscriberOverride = _FakeTranscriber('');

    // 真实 IO（sqflite ffi）必须放在 runAsync 里，否则会被 fake async 挂住。
    late ProgressService progress;
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      progress = ProgressService(db: AppDatabase(path: ':memory:'));
      await progress.init();
    });

    final chunk = _chunk('a01', 'Good morning');
    final level = Level(
      id: 'A',
      theme: 'Greetings',
      sceneImage: '',
      chunks: [chunk],
      sentences: [
        TargetSentence(
            id: 's1',
            text: 'Good morning, everyone.',
            meaningCN: '大家早上好',
            chunkIds: ['a01']),
      ],
    );

    int? passedWith;
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<TtsService>.value(value: TtsService(adapter: _FakeTts())),
        Provider<ProgressService>.value(value: progress),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: FreeUseStep(
            chunk: chunk,
            level: level,
            referenceText: 'I said good morning to my neighbor.',
            onPass: (acc) => passedWith = acc,
            onSkip: () {},
          ),
        ),
      ),
    ));

    // 等识别引擎就绪（按钮从禁用变可用）。
    OutlinedButton? mic;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final f = find.widgetWithText(OutlinedButton, '说出来');
      if (f.evaluate().isNotEmpty) {
        mic = tester.widget<OutlinedButton>(f);
        if (mic.onPressed != null) break;
      }
    }
    expect(mic?.onPressed, isNotNull, reason: '识别引擎没准备好');

    await tester.tap(find.text('说出来'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('说完点这里'), findsOneWidget);

    await tester.tap(find.text('说完点这里'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));

    // 空转写 ⇒ 机器没把握：卡片是一级出口，且「录过音」就能自证（与第 4/5 步一致）。
    expect(find.byKey(const Key('machineUnsureCard')), findsOneWidget);
    expect(find.text('这台机器没把握，不是给你判错'), findsOneWidget);
    final cardButton = find.widgetWithText(
        FilledButton, '就是这句，算我说过（不计发音分）');
    expect(cardButton, findsOneWidget);
    expect(tester.widget<FilledButton>(cardButton).onPressed, isNotNull,
        reason: '录到过音频却把自证按钮禁用了 = 死胡同');
    expect(find.text('完成这一块'), findsNothing);

    await tester.tap(cardButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('machineUnsureCard')), findsNothing);
    expect(find.text('完成这一块'), findsOneWidget);
    await tester.tap(find.text('完成这一块'));
    await tester.pump();
    expect(passedWith, 100);
  });
}

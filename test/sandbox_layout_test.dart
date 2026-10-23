import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/free_build_screen.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/speech.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';

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

/// 只注入「识别出的文本」；录音、判定、落库、UI 全走真实链路。
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
  Future<VoskResult> transcribeOpen(String wavPath) => transcribe(wavPath, const []);
}

/// 压测夹具：N 个块，分两个场景（A 打招呼 / B 机场），表面形态互不相同。
List<Chunk> _pool(int n) => [
      for (var i = 0; i < n; i++)
        Chunk.fromJson({
          'id': '${i % 2 == 0 ? 'a' : 'b'}$i',
          'text': 'word$i here',
          'type': 'content',
          'meaningCN': '释义$i',
        }),
    ];

ContentPack _pack(List<Chunk> pool) => ContentPack(version: 'test', levels: [
      Level(
        id: 'A',
        theme: '打招呼',
        sceneImage: '',
        chunks: pool.where((c) => c.id.startsWith('a')).toList(),
        sentences: const [],
      ),
      Level(
        id: 'B',
        theme: '机场',
        sceneImage: '',
        chunks: pool.where((c) => c.id.startsWith('b')).toList(),
        sentences: const [],
      ),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const permCh = MethodChannel('flutter.baseflow.com/permissions/methods');
  const pathCh = MethodChannel('plugins.flutter.io/path_provider');
  const recCh = MethodChannel('chunkspoke/recorder');
  const levelCh = MethodChannel('chunkspoke/recorder_level');

  late Directory dir;
  late AppDatabase db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sandbox_layout');
    db = AppDatabase(path: '${dir.path}/t.db');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permCh, (call) async {
      switch (call.method) {
        case 'checkPermissionStatus':
          return 1;
        case 'requestPermissions':
          return <int, int>{1: 1};
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(pathCh,
        (call) async => call.method == 'getTemporaryDirectory' ? '/tmp' : null);
    messenger.setMockMethodCallHandler(
        recCh, (call) async => call.method == 'stop' ? '/tmp/fake.wav' : null);
    // 电平是 EventChannel：不 mock 会在 listen/cancel 时抛 MissingPluginException。
    messenger.setMockMethodCallHandler(levelCh, (call) async => null);
    // 没有注入桩时，_prepare 会去 init() 真实 Vosk 引擎——测试环境里它永远回不来。
    SpeechService.debugTranscriberOverride = _FakeTranscriber('');
  });

  tearDown(() async {
    SpeechService.debugTranscriberOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permCh, null);
    messenger.setMockMethodCallHandler(pathCh, null);
    messenger.setMockMethodCallHandler(recCh, null);
    messenger.setMockMethodCallHandler(levelCh, null);
    await (await db.db).close();
  });

  Future<ProgressService> service() async {
    final p = ProgressService(db: db);
    await p.init();
    return p;
  }

  /// 沙盒首启要查库（真实 I/O）：fake-async 的 pump 推不动它，必须 runAsync + 真实延时轮询。
  Future<void> pumpSandbox(
      WidgetTester tester, List<Chunk> pool, ProgressService p,
      {ContentPack? pack}) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 调用方已在 runAsync 里（不能再嵌套），这里直接泵帧等真实 I/O 落地。
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ProgressService>.value(value: p),
        Provider<ContentPack>.value(value: pack ?? _pack(pool)),
        Provider<TtsService>.value(value: TtsService(adapter: _FakeTts())),
      ],
      child: MaterialApp(home: FreeBuildScreen(learnedChunks: pool)),
    ));
    // 全量回归是多 isolate 并跑的，真实 I/O 会被拖慢：预算给足，渲染出来就立刻返回。
    for (var i = 0; i < 600; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      if (find.byKey(const Key('sandboxPool')).evaluate().isNotEmpty) return;
    }
    fail('块池没渲染出来：沙盒首启（含 allRows 查询）超时');
  }

  Rect rect(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(Key(key)));

  Map<String, Rect> skeleton(WidgetTester tester) => {
        'card': rect(tester, 'sandboxSentenceCard'),
        'feedback': rect(tester, 'sandboxFeedbackSlot'),
        'filter': rect(tester, 'sandboxFilterBar'),
        'dock': rect(tester, 'sandboxDock'),
        'pool': rect(tester, 'sandboxPool'),
      };

  Future<void> settle(WidgetTester tester, bool Function() done,
      {int rounds = 200}) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
      if (done()) return;
    }
  }

  testWidgets('200 块与 20 块：三区骨架完全一致，mic 固定在拇指区', (tester) async {
    await tester.runAsync(() async {
      final p1 = await service();
      await pumpSandbox(tester, _pool(20), p1);
      final small = skeleton(tester);
      final micSmall = tester.getRect(find.byKey(const Key('sandboxMic')));

      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final p2 = await service();
      await pumpSandbox(tester, _pool(200), p2);
      final big = skeleton(tester);
      final micBig = tester.getRect(find.byKey(const Key('sandboxMic')));

      for (final k in small.keys) {
        expect(big[k], small[k], reason: '$k 在 200 块时位置/尺寸变了');
      }
      expect(micBig, micSmall, reason: 'mic 被块池顶走了');
      final screen = tester.getRect(find.byType(Scaffold));
      expect(micBig.bottom <= screen.bottom + 0.5, isTrue,
          reason: 'mic 必须完整落在屏幕内');
      expect(micBig.top > screen.top + screen.height / 2, isTrue,
          reason: 'mic 应固定在屏幕下半部（拇指区）');
    });
  });

  testWidgets('块池是唯一滚动区：滚动只动池，其余三区纹丝不动', (tester) async {
    await tester.runAsync(() async {
      final p = await service();
      await pumpSandbox(tester, _pool(200), p);
      final sk = skeleton(tester);
      final before = {
        for (final k in ['card', 'filter', 'dock']) k: sk[k]!
      };
      expect(find.text('word0 here'), findsOneWidget);
      expect(find.text('word198 here'), findsNothing);

      for (var i = 0;
          i < 30 && find.text('word198 here').evaluate().isEmpty;
          i++) {
        await tester.drag(
            find.byKey(const Key('sandboxPool')), const Offset(0, -600));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await tester.pump();
      }

      final after = skeleton(tester);
      for (final e in before.entries) {
        expect(after[e.key], e.value, reason: '${e.key} 被滚动带偏了');
      }
      expect(find.text('word198 here'), findsOneWidget);
      expect(find.text('word0 here'), findsNothing); // 首块已回收 = 真虚拟化
    });
  });

  testWidgets('虚拟化生效：200 块时同屏渲染的块数远小于总量', (tester) async {
    await tester.runAsync(() async {
      final p = await service();
      await pumpSandbox(tester, _pool(200), p);
      final rendered = find.textContaining('here').evaluate().length;
      expect(rendered, greaterThan(0));
      expect(rendered, lessThan(60),
          reason: '块池不该把 200 块一次性铺进 widget 树（当前渲染 $rendered）');
    });
  });

  testWidgets('搜索即时过滤（英文与中文释义双匹配）', (tester) async {
    await tester.runAsync(() async {
      final p = await service();
      await pumpSandbox(tester, _pool(200), p);

      await tester.enterText(find.byKey(const Key('sandboxSearch')), 'word199');
      await tester.pump();
      expect(find.text('word199 here'), findsOneWidget);
      expect(find.text('word0 here'), findsNothing);

      await tester.enterText(find.byKey(const Key('sandboxSearch')), '释义199');
      await tester.pump();
      expect(find.text('word199 here'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('sandboxSearch')), '不存在的词');
      await tester.pump();
      expect(find.textContaining('这个筛选下没有词块'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('sandboxSearch')), '');
      await tester.pump();
      expect(find.text('word0 here'), findsOneWidget);
    });
  });

  testWidgets('场景标签筛选：只看一个场景', (tester) async {
    await tester.runAsync(() async {
      final pool = _pool(200);
      final p = await service();
      await pumpSandbox(tester, pool, p);
      final bCount = pool.where((c) => c.id.startsWith('b')).length;
      final tag = find.text('机场 · $bCount');
      await tester.ensureVisible(tag);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await tester.pump();
      await tester.tap(tag, warnIfMissed: false);
      await tester.pump();
      expect(find.text('word1 here'), findsOneWidget); // b1 在机场
      expect(find.text('word0 here'), findsNothing); // a0 被筛掉
      // 分组标题用人能读的场景名，不是 schema 里的 id
      expect(find.text('机场'), findsWidgets);
      expect(find.text('B'), findsNothing);
    });
  });

  testWidgets('空句：mic 置灰不可用，点它只给提示', (tester) async {
    await tester.runAsync(() async {
      final p = await service();
      await pumpSandbox(tester, _pool(20), p);
      expect(find.text('先挑块拼一句'), findsWidgets); // 句子卡 + 底栏各一处
      final box = tester.widget<Container>(find
          .descendant(
              of: find.byKey(const Key('sandboxMic')),
              matching: find.byType(Container))
          .first);
      expect((box.decoration as BoxDecoration).color, const Color(0xFF3A3A52));

      await tester.tap(find.byKey(const Key('sandboxMic')));
      await tester.pump();
      expect(find.text('正在聆听… 再点一下停止'), findsNothing); // 没开始录音
    });
  });

  testWidgets('拼句 → 开口 → 通过即自动存入我的句子，标题计数更新', (tester) async {
    await tester.runAsync(() async {
      final pool = _pool(20);
      final p = await service();
      SpeechService.debugTranscriberOverride =
          _FakeTranscriber('word0 here word2 here');
      await pumpSandbox(tester, pool, p);

      await tester.tap(find.text('word0 here').first);
      await tester.pump();
      await tester.tap(find.text('word2 here').first);
      await tester.pump();
      expect(find.text('word0 here word2 here'), findsWidgets);

      await tester.tap(find.byKey(const Key('sandboxMic')));
      await settle(
          tester, () => find.text('正在聆听… 再点一下停止').evaluate().isNotEmpty);
      await tester.tap(find.byKey(const Key('sandboxMic')));
      await settle(tester, () => find.text('通过！已存入我的句子').evaluate().isNotEmpty);
      // 计数要等写库落地才更新（并行回归下这一步会慢一拍），先等它再断言。
      await settle(
          tester, () => find.text('自由造句沙盒 · 1 句').evaluate().isNotEmpty);

      expect(find.text('通过！已存入我的句子'), findsOneWidget);
      expect(find.text('自由造句沙盒 · 1 句'), findsOneWidget);
      // B5：界面原文行必须等于 ASR 原始输出（一字不改）。
      expect(find.text('你说：word0 here word2 here'), findsOneWidget);
      expect(find.byKey(const Key('sandboxAsrRaw')), findsOneWidget);
      expect(p.sandbox.sentences.single.text, 'Word0 here word2 here.');
      expect(p.sandbox.stats.visits, 1);
      expect(p.freeBuildCount, 1);
    });
  });

  testWidgets('B5：垃圾识别（同词堆叠）→ 原文照上屏，判没听清，不入库', (tester) async {
    await tester.runAsync(() async {
      final pool = _pool(20);
      final p = await service();
      SpeechService.debugTranscriberOverride =
          _FakeTranscriber('coffee coffee coffee');
      await pumpSandbox(tester, pool, p);

      await tester.tap(find.text('word0 here').first);
      await tester.pump();
      await tester.tap(find.text('word2 here').first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sandboxMic')));
      await settle(
          tester, () => find.text('正在聆听… 再点一下停止').evaluate().isNotEmpty);
      await tester.tap(find.byKey(const Key('sandboxMic')));
      await settle(
          tester, () => find.text('⚠ 没听清，再说一遍').evaluate().isNotEmpty);

      expect(find.text('⚠ 没听清，再说一遍'), findsOneWidget);
      expect(find.text('你说：coffee coffee coffee'), findsOneWidget);
      expect(p.sandbox.sentences, isEmpty);
      expect(p.freeBuildCount, 0);
    });
  });

  testWidgets('串联：一句含 ≥2 个已掌握块 → 计数 +1 并在反馈里说明', (tester) async {
    await tester.runAsync(() async {
      final pool = _pool(20);
      final p = await service();
      final store = ChunkProgressStore(db, clock: () => p.now);
      for (final id in ['a0', 'a2']) {
        await store.applyEvent(id, ChunkEvent.assembleCorrect);
        await store.applyEvent(id, ChunkEvent.dragCorrect);
        await store.applyEvent(id, ChunkEvent.accuracyPass, accuracy: 100);
        await store.applyEvent(id, ChunkEvent.speakSuccess,
            accuracy: 100, fourStarsGreen: true, enforceFourStars: true);
        for (var i = 0; i < 4; i++) {
          await store.applyEvent(id, ChunkEvent.speakSuccess,
              accuracy: 100, review: true);
        }
      }
      SpeechService.debugTranscriberOverride =
          _FakeTranscriber('word0 here word2 here');
      await pumpSandbox(tester, pool, p);

      await tester.tap(find.text('word0 here').first);
      await tester.pump();
      await tester.tap(find.text('word2 here').first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sandboxMic')));
      await settle(
          tester, () => find.text('正在聆听… 再点一下停止').evaluate().isNotEmpty);
      await tester.tap(find.byKey(const Key('sandboxMic')));
      await settle(
          tester, () => find.textContaining('串联 +1').evaluate().isNotEmpty);

      expect(find.text('已存入我的句子 · 串联 +1'), findsOneWidget);
      expect(p.sandbox.stats.chainCount, 1);
      expect(p.sandbox.sentences.single.chain, isTrue);
    });
  });

  testWidgets('我的句子抽屉：重听 / 重录 / 删除，标题计数跟着变', (tester) async {
    await tester.runAsync(() async {
      final pool = _pool(20);
      final p = await service();
      await p.sandbox.addSentence([pool[0], pool[2]], {});
      await pumpSandbox(tester, pool, p);
      expect(find.text('自由造句沙盒 · 1 句'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sandboxMySentences')));
      // 底部弹层有入场动画：不推时钟会一直停在屏幕下方外，点不到。
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('我的句子'), findsOneWidget);
      expect(find.text('1 句'), findsOneWidget);
      expect(find.byIcon(Icons.volume_up), findsWidgets); // 重听
      expect(find.byIcon(Icons.mic), findsWidgets); // 重录

      final del = find.byIcon(Icons.delete_outline);
      await tester.tap(del);
      // 删除要写库（真实 I/O）→ 泵帧等它落地，同时推进弹层重建。
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
        if (find.textContaining('还没有通过的句子').evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('还没有通过的句子'), findsOneWidget);
      expect(p.sandbox.sentences, isEmpty);
      expect(find.text('自由造句沙盒 · 0 句'), findsOneWidget);
    });
  });

  testWidgets('底栏推荐横条：点一句就把组成块填进句子卡', (tester) async {
    await tester.runAsync(() async {
      final pool = _pool(20);
      final p = await service();
      final pack = ContentPack(version: 'test', levels: [
        Level(
          id: 'A',
          theme: '打招呼',
          sceneImage: '',
          chunks: pool.where((c) => c.id.startsWith('a')).toList(),
          sentences: [
            TargetSentence(
                id: 's1',
                text: 'word0 here word2 here',
                meaningCN: '',
                chunkIds: const ['a0', 'a2']),
          ],
        ),
        Level(
          id: 'B',
          theme: '机场',
          sceneImage: '',
          chunks: pool.where((c) => c.id.startsWith('b')).toList(),
        ),
      ]);
      await pumpSandbox(tester, pool, p, pack: pack);
      expect(
          find.descendant(
              of: find.byKey(const Key('sandboxRecommend')),
              matching: find.text('word0 here word2 here')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('sandboxSentenceCard')),
              matching: find.text('从下面挑块拼一句')),
          findsOneWidget);

      await tester.tap(find.text('word0 here word2 here'));
      await tester.pump();
      expect(
          find.descendant(
              of: find.byKey(const Key('sandboxSentenceCard')),
              matching: find.text('word0 here word2 here')),
          findsOneWidget);
    });
  });

  testWidgets('长按 chip 出试听+释义浮层；需重修块带琥珀微标', (tester) async {
    await tester.runAsync(() async {
      final pool = _pool(20);
      final p = await service();
      final store = ChunkProgressStore(db, clock: () => p.now);
      await store.applyEvent('a2', ChunkEvent.assembleCorrect);
      await store.applyEvent('a2', ChunkEvent.dragCorrect);
      await store.applyEvent('a2', ChunkEvent.accuracyPass, accuracy: 100);
      await store.applyEvent('a2', ChunkEvent.speakSuccess, accuracy: 100);
      await store.applyEvent('a2', ChunkEvent.speakFail,
          accuracy: 0, review: true); // 复习失败 → 需重修
      await pumpSandbox(tester, pool, p);
      expect(find.byIcon(Icons.autorenew), findsWidgets); // 琥珀微标

      final c = tester.getCenter(find.text('word2 here').first);
      final g = await tester.startGesture(c);
      await Future<void>.delayed(const Duration(milliseconds: 1200)); // 超过长按阈值
      await tester.pump();
      await g.up();
      await settle(tester, () => find.text('试听').evaluate().isNotEmpty);
      expect(find.text('试听'), findsOneWidget);
      expect(find.text('· 释义2'), findsOneWidget);
      expect(find.text('需重修'), findsOneWidget);
    });
  });
}

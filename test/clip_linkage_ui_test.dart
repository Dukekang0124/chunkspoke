import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/screens/clip_chunk_screen.dart';
import 'package:chunkspoke_flutter/screens/library.dart';
import 'package:chunkspoke_flutter/screens/listening_home_screen.dart';
import 'package:chunkspoke_flutter/services/clip_linkage.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// 1.10.0 词块联动的端到端 UI 钉测（真库真读，不 mock 派生层）：
///  · 归档页：词块数/句数/阈值进度、词块卡与原句上下文、未达标不给播放按钮；
///  · 磨耳朵播单：词块×2 + 原句×1 的轮次从同一份归档派生；
///  · 词块库入口：卡片出现并带同一个数，点进去就是归档页。
///
/// 不测发声：TTS 是平台通道，单测里只验证「播单形状」，实际出声归模拟器 E2E。

Level _level() => Level(
      id: 'L1',
      theme: 'Keep',
      sceneImage: '',
      chunks: [
        Chunk.fromJson({
          'id': 'k1',
          'text': 'Good morning',
          'type': 'content',
          'meaningCN': '',
        }),
      ],
    );

/// 五句可学英文句子（都带例句），外加一句中文和一句单词条目作为噪声。
const String _csv = 'front,back,module_name,example\n'
    '"look forward to","期待","日常","I look forward to the weekend."\n'
    '"take care of","照顾","日常","Please take care of yourself."\n'
    '"be able to","能够","日常","She was able to solve it."\n'
    '"make sure","确保","工作","We will make sure it works."\n'
    '"turn off","关掉","工作","He turned off the light."\n'
    '"咖啡","coffee","点单",""\n'
    '"plate","盘子","点单",""\n';

Widget _app(ProgressService progress, Widget home) => MultiProvider(
      providers: [
        Provider<ProgressService>.value(value: progress),
        Provider<ContentPack>.value(
            value: ContentPack(version: 'test', levels: [_level()])),
        Provider<ListeningPack>.value(value: ListeningPack(
            version: 1, generatedAt: '', articles: const [])),
        Provider<TtsService>.value(value: TtsService()),
      ],
      child: MaterialApp(home: home),
    );

Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int tries = 100}) async {
  for (var i = 0; i < tries; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('等待超时：$finder');
}

Future<ProgressService> _seed(
    {int threshold = kClipThresholdDefault, String? csv}) async {
  final dir = await Directory.systemTemp.createTemp('clip_ui');
  final progress = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
  await progress.init();
  final store = UserPackageStore(progress.database);
  final v = parseAndValidateUserPackage(csv ?? _csv);
  expect(v.ok, isTrue, reason: v.firstErrorText);
  final r = await store.importValidation(v, allowed: true);
  expect(r.ok, isTrue, reason: r.note);
  if (threshold != kClipThresholdDefault) {
    await saveClipThreshold(progress.database, threshold);
  }
  return progress;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('归档页：5 句 5 块 · 原句上下文 · 未达标不给播放', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _seed();
      await tester.pumpWidget(_app(progress, const ClipChunkScreen()));
      await _pumpUntil(tester, find.byKey(const Key('clip_archive_summary')));

      // 五个词块都在（键 = 规范形），且各自带原句。
      for (final key in [
        'look forward to',
        'take care of',
        'be able to',
        'make sure',
        'turn off',
      ]) {
        expect(find.byKey(Key('clip_chunk_$key')), findsOneWidget,
            reason: '缺少词块卡：$key');
      }
      expect(find.text('“I look forward to the weekend.”'), findsOneWidget);
      expect(find.text('“Please take care of yourself.”'), findsOneWidget);
      expect(find.text('“She was able to solve it.”'), findsOneWidget);
      expect(find.text('“We will make sure it works.”'), findsOneWidget);
      expect(find.text('“He turned off the light.”'), findsOneWidget);

      // 中文与单词条目不参与。
      expect(find.text('咖啡'), findsNothing);
      expect(find.text('plate'), findsNothing);

      // 默认阈值 10：5 句未达标，不出现播放按钮，进度文案如实。
      expect(find.textContaining('还差 5 句到 10 句'), findsOneWidget);
      expect(find.byKey(const Key('clip_archive_go_listen')), findsNothing);
      final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('clip_archive_progress')));
      expect(bar.value, closeTo(0.5, 0.001));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('阈值调到 5 → 出现「去磨耳朵」→ 播单 = 词块×2 + 原句×1',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _seed(threshold: 5);
      await tester.pumpWidget(_app(progress, const ClipChunkScreen()));
      await _pumpUntil(tester, find.byKey(const Key('clip_archive_summary')));

      expect(find.textContaining('已联动磨耳朵'), findsOneWidget);
      final btn = find.byKey(const Key('clip_archive_go_listen'));
      expect(btn, findsOneWidget);

      await tester.tap(btn);
      await _pumpUntil(tester, find.byKey(const Key('clip_listen_screen')));

      // 5 个词块 → 5 个轮次，每轮「念两遍 + 原句一遍」。
      for (var i = 0; i < 5; i++) {
        expect(find.byKey(Key('clip_listen_round_$i')), findsOneWidget);
      }
      expect(find.byKey(const Key('clip_listen_round_5')), findsNothing);
      expect(find.text('词块 · 念两遍'), findsOneWidget);
      expect(find.textContaining('每个词块念两遍'), findsOneWidget);
      expect(find.textContaining('不改学习进度、不排复习'), findsOneWidget);
      expect(find.text('词块 1 / 5'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('词块库入口卡：读同一份归档，点进去是归档页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _seed(threshold: 5);
      await tester.pumpWidget(
          _app(progress, const Scaffold(body: LibraryScreen())));
      await _pumpUntil(tester, find.byKey(const Key('library_clip_card')));

      expect(find.text('我的词块'), findsWidgets);
      expect(find.text('5 个'), findsOneWidget);
      expect(find.textContaining('已联动磨耳朵'), findsOneWidget);

      await tester.tap(find.byKey(const Key('library_clip_card')));
      await _pumpUntil(tester, find.byKey(const Key('clip_archive_summary')));
      expect(find.byKey(const Key('clip_archive_go_listen')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('磨耳朵首页：达标后出现词块联动入口，点「按词块顺序听」进播单',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _seed(threshold: 5);
      await tester.pumpWidget(
          _app(progress, const Scaffold(body: ListeningHomeScreen())));
      await _pumpUntil(tester, find.byKey(const Key('listening_clip_linkage')));

      expect(find.text('我的词块 · 可以听了'), findsOneWidget);
      expect(find.textContaining('5 句 → 5 个词块'), findsOneWidget);
      final play = find.byKey(const Key('listening_clip_play'));
      expect(play, findsOneWidget);

      await tester.tap(play);
      await _pumpUntil(tester, find.byKey(const Key('clip_listen_screen')));
      expect(find.text('词块 1 / 5'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('空归档 × 零句子：引导粘贴，不说「还差 N 句」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('clip_empty');
      final progress =
          ProgressService(db: AppDatabase(path: '${dir.path}/e.db'));
      await progress.init();
      await tester.pumpWidget(_app(progress, const ClipChunkScreen()));
      await _pumpUntil(tester, find.byKey(const Key('clip_archive_empty_none')));

      expect(find.text('还没有可学的词块'), findsOneWidget);
      expect(find.textContaining('还没有扫到英文句子'), findsOneWidget);
      expect(find.textContaining('还差 0 句'), findsNothing);
      expect(find.byKey(const Key('clip_archive_empty_unmatched')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  // 1.10.1：用户粘贴了 10 句、一个词块都没认出来。修复前只显示「还差 10 句」，
  // 让人以为再攒几句就行；现在必须说清「扫了 10 句、0 句认出词块」。
  const String unmatchedCsv = 'front,back,module_name\n'
      '"The barista smiles and asks what size I want.",,"日常"\n'
      '"Everyone seems calm except me.",,"日常"\n'
      '"I check my phone and see that I am late.",,"日常"\n'
      '"The machine is loud and the room smells wonderful.",,"日常"\n';

  testWidgets('空归档 × 已扫 4 句未认出：如实报数，不催「还差」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _seed(csv: unmatchedCsv);
      await tester.pumpWidget(_app(progress, const ClipChunkScreen()));
      await _pumpUntil(
          tester, find.byKey(const Key('clip_archive_empty_unmatched')));

      expect(find.text('扫了 4 句，暂时没认出词块'), findsOneWidget);
      expect(find.textContaining('已扫描 4 句英文，其中 0 句认出了可学词块'),
          findsOneWidget);
      expect(find.textContaining('联动进度还没开始'), findsOneWidget);
      expect(find.textContaining('还差 10 句到 10 句'), findsNothing);
      expect(find.byKey(const Key('clip_archive_empty_none')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('混合归档：认出 5 句 / 扫了 9 句，多出的计数单独显示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _seed(
          csv: '$_csv"Everyone seems calm except me.",,"日常"\n');
      await tester.pumpWidget(_app(progress, const ClipChunkScreen()));
      await _pumpUntil(tester, find.byKey(const Key('clip_archive_summary')));

      expect(find.textContaining('已扫描 6 句英文，其中 5 句认出了可学词块'),
          findsOneWidget);
      expect(find.text('句已扫描'), findsOneWidget);
      expect(find.textContaining('另有 1 句里没有我认得的可学词块'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  test('设置页阈值必须走唯一保存口并列出全部档位（源码闸）', () {
    // 去掉行注释再查：文档注释里可以写 kv 键，代码里不许自己动手。
    final src = File('lib/screens/settings.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(src.contains(kClipThresholdKvKey), isFalse,
        reason: '设置页不许自己拼 kv 键，必须走 saveClipThreshold');
    expect(src.contains('saveClipThreshold('), isTrue);
    expect(src.contains("key: const ValueKey('settings_clip_threshold')"),
        isTrue);
    expect(src.contains('for (final v in kClipThresholdOptions)'), isTrue,
        reason: '档位必须来自单源常量，不许在 UI 里再抄一份');
    expect(src.contains('关闭只是不再往磨耳朵推词块播单'), isTrue,
        reason: '关闭的后果必须说清：只是不推播单，归档和记录都还在');
  });
}

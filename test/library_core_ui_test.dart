import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/screens/library.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

Chunk _chunk(String id, String text, String tier, String func, int rank) =>
    Chunk.fromJson({
      'id': id,
      'text': text,
      'type': '固定搭配',
      'semantic': 'content',
      'meaningCN': '$text 的释义',
      'tier': tier,
      'funcCat': func,
      'freqRank': rank,
      'sources': ['pack:level/L1'],
    });

Level _level() => Level(
      id: 'L1',
      theme: 'Greetings',
      sceneImage: '',
      chunks: [
        _chunk('t0a', 'Good morning', 'T0', '寒暄开场', 5),
        _chunk('t1a', 'Could you help me', 'T1', '请求协助', 0),
        _chunk('t2a', 'No problem', 'T2', '应答回应', 88),
      ],
    );

Widget _app(ProgressService progress, ContentPack content) => MultiProvider(
      providers: [
        Provider<ProgressService>.value(value: progress),
        Provider<ContentPack>.value(value: content),
        Provider<ListeningPack>.value(
            value: ListeningPack(version: 1, generatedAt: '', articles: const [])),
      ],
      child: const MaterialApp(home: Scaffold(body: LibraryScreen())),
    );

/// 真实 SQLite I/O 在 fake-async 下等不到，只能 runAsync 轮询重绘。
Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int tries = 100}) async {
  for (var i = 0; i < tries; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('等待超时：$finder');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('核心库 UI：T0/T1/T2 chips + 功能八类筛选 + 徽标与频表排名',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('n2_library_ui');
      final db = AppDatabase(path: '${dir.path}/t.db');
      final progress = ProgressService(db: db);
      await progress.init();
      for (final id in ['t0a', 't1a', 't2a']) {
        await db.upsertChunk(ChunkRow(
          chunkKey: id,
          level: ChunkLevel.l4,
          dueDate: DateTime.now().millisecondsSinceEpoch + 86400000,
          failCount: 0,
          lastScore: 90,
          reviewStage: 1,
          assetState: ChunkAssetState.consolidating,
        ));
      }
      final content = ContentPack(version: 'test', levels: [_level()]);

      await tester.pumpWidget(_app(progress, content));
      await _pumpUntil(tester, find.text('Good morning'));

      // 三档 chip 带计数；功能八类 chip 齐全。
      expect(find.byKey(const Key('library_filter_tier_T0')), findsOneWidget);
      expect(find.text('T0 1'), findsOneWidget);
      expect(find.text('T1 1'), findsOneWidget);
      expect(find.text('T2 1'), findsOneWidget);
      for (final f in [
        '寒暄开场',
        '应答回应',
        '观点立场',
        '请求协助',
        '确认澄清',
        '时间计划',
        '情绪评价',
        '委婉缓冲',
      ]) {
        expect(find.byKey(Key('library_filter_func_$f')), findsOneWidget);
      }
      expect(find.text('寒暄开场 1'), findsOneWidget);
      expect(find.text('请求协助 1'), findsOneWidget);

      // T0 块卡：tier 徽标 + 频表排名。
      expect(find.byKey(const Key('library_tier_t0a')), findsOneWidget);
      expect(find.text('频表 #5'), findsNothing);
      expect(find.textContaining('频表 #5'), findsOneWidget);
      expect(find.textContaining('频表 未收录'), findsOneWidget);
      expect(find.textContaining('频表 #88'), findsOneWidget);

      // 层级筛选：只看 T0。
      await tester.tap(find.byKey(const Key('library_filter_tier_T0')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Good morning'), findsOneWidget);
      expect(find.text('Could you help me'), findsNothing);
      expect(find.text('No problem'), findsNothing);

      // 回到全部层级，再按功能筛选只看「请求协助」。
      await tester.tap(find.byKey(const Key('library_filter_tier_全部')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('library_filter_func_请求协助')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Could you help me'), findsOneWidget);
      expect(find.text('Good morning'), findsNothing);
      expect(find.text('No problem'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

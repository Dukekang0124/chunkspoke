import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/map.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/scene_progression.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

Level _level(String id, String theme, int count) => Level(
      id: id,
      theme: theme,
      sceneImage: '',
      chunks: List.generate(
        count,
        (i) => Chunk.fromJson({
          'id': '${id.toLowerCase()}$i',
          'text': '$id chunk $i',
          'type': 'content',
          'meaningCN': '',
        }),
      ),
    );

/// 造一个「关卡轴 + 资产轴都到已掌握」的块：
/// 六步全绿完成学习，再走完 1/3/7/14 天复习档。
Future<void> _master(ChunkProgressStore store, String id) async {
  await store.applyEvent(id, ChunkEvent.assembleCorrect);
  await store.applyEvent(id, ChunkEvent.dragCorrect);
  await store.applyEvent(id, ChunkEvent.accuracyPass, accuracy: 90);
  await store.applyEvent(id, ChunkEvent.speakSuccess,
      accuracy: 95, fourStarsGreen: true, enforceFourStars: true);
  // 四档全走一遍：+1d（首到期）→ +3d → +7d → +14d → 已掌握（指令 N 修订）
  for (var i = 0; i < 4; i++) {
    await store.applyEvent(id, ChunkEvent.speakSuccess,
        accuracy: 95, review: true);
  }
}

Widget _app(ProgressService progress, ContentPack content, Key key) =>
    MultiProvider(
      providers: [
        Provider<ProgressService>.value(value: progress),
        Provider<ContentPack>.value(value: content),
      ],
      child: MaterialApp(home: MapScreen(key: key)),
    );

/// MapScreen 在 initState 里查真实 SQLite；fake-async 的 pump(Duration)
/// 只推进假时钟，等不到真实 I/O。此处在 runAsync 内用真实延时轮询重绘。
Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int tries = 100}) async {
  for (var i = 0; i < tries; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('等待超时：$finder');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('地图行可点击：锁定场景给出解锁差额', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // DB 是真实 I/O：必须跑在 runAsync，否则 fake-async 下 10 分钟超时。
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('b4_map_widget');
      final progress =
          ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
      await progress.init();
      final a = _level('A', 'Greetings', 12);
      final b = _level('B', 'Asking for things', 25);
      final content = ContentPack(version: 'test', levels: [a, b]);

      await tester.pumpWidget(_app(progress, content, const ValueKey('fresh')));
      // 等首帧真实查询落地（空库时文案与回退态相同，仍轮询一次保证时序）。
      await _pumpUntil(tester, find.text('已掌握 0 个词块'));

      // 新用户：主 CTA 指向唯一解锁场景 A。
      expect(find.text('继续学习：打招呼'), findsOneWidget);

      // 场景行是 InkWell（修复前是纯 Container，点了没反应）。
      final aInk = find
          .ancestor(of: find.text('打招呼'), matching: find.byType(InkWell))
          .first;
      expect(tester.widget<InkWell>(aInk).onTap, isNotNull);

      await tester.tap(find.text('索取东西'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('先完成「打招呼」：本场景达标 10/12 块解锁'),
          findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('A 掌握 10/12 → B 真解锁，主 CTA 目标切到 B', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('b4_map_unlocked');
      final progress =
          ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
      await progress.init();
      final a = _level('A', 'Greetings', 12);
      final b = _level('B', 'Asking for things', 25);
      final content = ContentPack(version: 'test', levels: [a, b]);
      for (var i = 0; i < 10; i++) {
        await _master(progress.chunkStore, 'a$i');
      }
      final keys = (await progress.chunkStore.allMasteredKeys()).toSet();
      expect(keys.length, 10);
      expect(progressionTarget(content.levels, keys)?.id, 'B');

      await tester
          .pumpWidget(_app(progress, content, const ValueKey('unlocked')));
      // 首帧是 FutureBuilder 空态；必须等真实查询返回后 UI 才是 10 块。
      await _pumpUntil(tester, find.text('已掌握 10 个词块'));

      expect(find.text('已掌握 10 个词块'), findsOneWidget);
      expect(find.text('继续学习：索取东西'), findsOneWidget);
      // 补练对象 A 仍有 2 块未掌握，但推进目标已经是 B。
      final bInk = find
          .ancestor(of: find.text('索取东西'), matching: find.byType(InkWell))
          .first;
      expect(tester.widget<InkWell>(bInk).onTap, isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('从场景返回地图后统计刷新（setState 不得返回 Future）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('b4_map_reload');
      final progress =
          ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
      await progress.init();
      final a = _level('A', 'Greetings', 12);
      final b = _level('B', 'Asking for things', 25);
      final content = ContentPack(version: 'test', levels: [a, b]);
      for (var i = 0; i < 11; i++) {
        await _master(progress.chunkStore, 'a$i');
      }

      await tester
          .pumpWidget(_app(progress, content, const ValueKey('reload')));
      await _pumpUntil(tester, find.text('已掌握 11 个词块'));

      // 进入 A：11/12 时停在断点门，不启动练习（无需 TTS）。
      await tester.tap(find.text('打招呼'));
      await _pumpUntil(tester, find.text('继续 · 第 12 块'));

      // 模拟会话内掌握最后一块。
      await _master(progress.chunkStore, 'a11');

      // 关闭关卡回到地图；修复前 setState 返回 Future 抛错，计数停在 11。
      await tester.tap(find.byIcon(Icons.close));
      await _pumpUntil(tester, find.text('已掌握 12 个词块'));
      expect(find.text('已掌握 12 个词块'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

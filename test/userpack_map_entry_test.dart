import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/map.dart';
import 'package:chunkspoke_flutter/screens/user_preview_screen.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';

/// ASR-223 v2 钉测：「我的模块」分区在地图里可达，点入即达只预览页。
///
/// v1 的缺口是「页面存在但没有导航入口」，本文件把这条钉死：
/// 入口在地图上、点得动、落地页首屏仍写着「只预览，不落库」。
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

Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int tries = 150}) async {
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

  test('红线：入口段只导航，不碰 store/进度（结构性零写入）', () {
    final src = File('lib/screens/map.dart').readAsStringSync();
    final start = src.indexOf('class _UserModuleSection');
    final end = src.indexOf('class _SceneRow');
    expect(start, greaterThan(0), reason: '「我的模块」入口段被删了');
    expect(end, greaterThan(start), reason: '找不到入口段结尾');
    final section = src.substring(start, end);
    for (final forbidden in [
      'progress',
      'Progress',
      'store',
      'Provider',
      'chunkStore',
      'await',
      'import',
      'userPackage',
    ]) {
      expect(section.contains(forbidden), isFalse,
          reason: '入口段出现了 $forbidden —— 它应该只负责跳转');
    }
    expect(section.contains('UserPreviewScreen'), isTrue);
  });

  testWidgets('地图有「我的模块」分区，点入即达预览页且首屏写明不落库',
      (tester) async {
    // 首屏可见性也是验收项：分区排在「今日卡 + 自由造句沙盒」之后、关卡列表之前。
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('v2_map_entry');
      final progress = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
      await progress.init();
      final content = ContentPack(
          version: 'test', levels: [_level('A', 'Greetings', 12)]);

      await tester
          .pumpWidget(MultiProvider(
        providers: [
          Provider<ProgressService>.value(value: progress),
          Provider<ContentPack>.value(value: content),
        ],
        child: const MaterialApp(home: MapScreen()),
      ));
      await _pumpUntil(tester, find.text('我的模块'));

      // 分区标题 + 导入入口都在地图上。
      expect(find.text('导入我自己的词块（CSV / JSON）'), findsOneWidget);
      expect(find.textContaining('只预览解析结果，不落库'), findsOneWidget);

      await tester.tap(find.text('导入我自己的词块（CSV / JSON）'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.byType(UserPreviewScreen), findsOneWidget);
      expect(find.text('我的模块 · 导入预览'), findsOneWidget);
      // 红线 4 在真实导航路径上仍然首屏可见。
      expect(find.textContaining('只预览，不落库'), findsWidgets);
      expect(find.text('把 CSV 或 JSON 的内容粘贴进来'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

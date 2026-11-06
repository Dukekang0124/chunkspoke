import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/map.dart';
import 'package:chunkspoke_flutter/screens/user_import_screen.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';

/// ASR-223 v2 / ASR-228 D3 钉测：地图「我的模块」分区可达导入器，且入口段只导航。
///
/// v1 的缺口是「页面存在但没有导航入口」，本文件把这条钉死；
/// D3 起入口指向落库版导入器（三入口 + 确认步），入口段本身仍然不许碰任何写路径。
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
      'Store',
      'Provider',
      'chunkStore',
      'await',
      'import ',
      'userPackage',
    ]) {
      expect(section.contains(forbidden), isFalse,
          reason: '入口段出现了 $forbidden —— 它应该只负责跳转');
    }
    expect(section.contains('UserImportScreen'), isTrue);
  });

  testWidgets('地图有「我的模块」分区，点入即达落库版导入器（三入口都在）',
      (tester) async {
    // 首屏可见性也是验收项：分区排在「自由造句沙盒」卡之后、关卡列表之前。
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('d3_map_entry');
      final progress =
          ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
      await progress.init();
      final content = ContentPack(
          version: 'test', levels: [_level('A', 'Greetings', 12)]);

      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<ProgressService>.value(value: progress),
          Provider<ContentPack>.value(value: content),
        ],
        child: const MaterialApp(home: MapScreen()),
      ));
      await _pumpUntil(tester, find.text('我的模块'));

      expect(find.text('导入我自己的词块（CSV / JSON）'), findsOneWidget);
      expect(find.textContaining('确认前不写入'), findsOneWidget);

      await tester.tap(find.text('导入我自己的词块（CSV / JSON）'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.byType(UserImportScreen), findsOneWidget);
      expect(find.text('我的模块 · 导入'), findsOneWidget);
      // 三入口 + 诚实文案都在首屏可达处。
      expect(find.text('从剪贴板粘贴'), findsOneWidget);
      expect(find.text('生成 CSV 模板文件'), findsOneWidget);
      expect(find.text('生成 JSON 模板文件'), findsOneWidget);
      expect(find.textContaining('本机文件'), findsOneWidget);
      expect(
          find.textContaining('未点「确认导入（将写入本机）」之前，不写入任何东西'),
          findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

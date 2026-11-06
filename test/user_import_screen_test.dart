import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/user_import_screen.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_files.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// ASR-228 · D3 落库件 1/3 的 UI 钉测：三入口都在、取消不写、确认才写、写完立刻对账。
Level _level(String id, int count) => Level(
      id: id,
      theme: 'Import $id',
      sceneImage: '',
      chunks: List.generate(
        count,
        (i) => Chunk.fromJson({
          'id': '${id.toLowerCase()}c$i',
          'text': 'chunk $i',
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

const _csv = 'front,back,module_name\n'
    '"a cup of coffee",一杯咖啡,点单\n'
    '"main course",主菜,餐厅\n';

void main() {
  late Directory tmp;
  late ProgressService progress;
  late ContentPack content;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('d3_import_ui');
    progress = ProgressService(db: AppDatabase(path: '${tmp.path}/t.db'));
    await progress.init();
    content = ContentPack(version: 'test', levels: [_level('A', 12)]);
  });

  Widget app(UserPackageFiles files) => MultiProvider(
        providers: [
          Provider<ProgressService>.value(value: progress),
          Provider<ContentPack>.value(value: content),
        ],
        child: MaterialApp(home: UserImportScreen(files: files)),
      );

  testWidgets('三入口 + 诚实文案在首屏；没确认前一行都不写', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = UserPackageFiles(dir: '${tmp.path}/user_packages');

    await tester.runAsync(() async {
      await tester.pumpWidget(app(files));
      await _pumpUntil(tester, find.text('我的模块 · 导入'));

      expect(find.text('从剪贴板粘贴'), findsOneWidget);
      expect(find.text('生成 CSV 模板文件'), findsOneWidget);
      expect(find.text('生成 JSON 模板文件'), findsOneWidget);
      expect(find.textContaining('本机文件'), findsOneWidget);

      await tester.tap(find.text('或直接填进下面输入框（CSV 模板）'));
      await tester.pump();
      // 输入框里现在是模板内容 → 解析。
      await tester.tap(find.text('解析并预览'));
      await tester.pump();
      expect(find.textContaining('校验通过'), findsOneWidget);
      expect(find.text('确认导入（将写入本机）'), findsOneWidget);
      // 文案与实装一致（ASR-228 装机腿抓到的冲突）：落库页不许再说「不占名额」。
      expect(find.textContaining('确认后即占用名额'), findsOneWidget);
      expect(find.textContaining('不占名额'), findsNothing);

      // 取消：一行都不写。
      await tester.tap(find.text('取消（不写入）'));
      await tester.pump();
      expect(await UserPackageStore(progress.database).userRowCount(), 0);
      expect(await UserPackageStore(progress.database).listPackages(), isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('确认导入 → 落库 + 官方计数不变 + 立刻跑一次对账', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = UserPackageFiles(dir: '${tmp.path}/user_packages');

    await tester.runAsync(() async {
      await tester.pumpWidget(app(files));
      await _pumpUntil(tester, find.text('我的模块 · 导入'));

      // 直接把内容打进输入框（等价于粘贴入口的落地态）。
      final field = find.byType(TextField);
      await tester.enterText(field, _csv);
      await tester.pump();
      await tester.tap(find.text('解析并预览'));
      await tester.pump();

      final officialBefore = (await progress.chunkStore.allMasteredKeys()).length;
      await tester.tap(find.text('确认导入（将写入本机）'));
      await _pumpUntil(tester, find.text('已写入本机'));

      final store = UserPackageStore(progress.database);
      expect(await store.userRowCount(), 2);
      expect((await store.listPackages()).length, 2);
      // 官方口径一字不变（排除在库层生效，UI 路径同样吃这条）。
      expect((await progress.chunkStore.allRows())
          .any((r) => isUserChunkKey(r.chunkKey)), isFalse);
      expect((await progress.chunkStore.allMasteredKeys()).length,
          officialBefore);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('模板入口写得出文件，文件入口读得回来', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = '${tmp.path}/user_packages';
    final files = UserPackageFiles(dir: dir);

    await tester.runAsync(() async {
      await tester.pumpWidget(app(files));
      await _pumpUntil(tester, find.text('我的模块 · 导入'));

      await tester.tap(find.text('生成 CSV 模板文件'));
      await _pumpUntil(tester, find.textContaining('chunkspoke-模板.csv'));

      final written = File('$dir${Platform.pathSeparator}chunkspoke-模板.csv');
      expect(await written.exists(), isTrue);
      expect((await written.readAsString()).contains('front,back,module_name'),
          isTrue);

      // 目录里放一份自定义表 → 重新扫描 → 读入 → 解析。
      await File('$dir${Platform.pathSeparator}我的词表.csv').writeAsString(_csv);
      await tester.tap(find.text('重新扫描'));
      await _pumpUntil(tester, find.text('我的词表.csv'));
      final row = find.ancestor(
          of: find.text('我的词表.csv'), matching: find.byType(ListTile));
      await tester.tap(find.descendant(of: row, matching: find.text('读入')));
      await _pumpUntil(tester, find.text('解析并预览'));
      await tester.tap(find.text('解析并预览'));
      await tester.pump();
      expect(find.textContaining('校验通过：2 块 · 2 个模块'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

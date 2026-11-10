import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/user_import_screen.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/license_state.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_files.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// 1.9.2 · 「添加我的英文本」的 UI 钉测：
/// 主路径是「粘贴 → 整理成句子 → 保存并开始学」；
/// 术语不进首屏；没保存前一行都不写；存完直接进六步。
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

/// 让折叠区展开动画走完，再点里面的按钮。
Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int tries = 200}) async {
  for (var i = 0; i < tries; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('等待超时：$finder');
}

/// 测试专用 TTS：不碰平台通道。
class _FakeTts implements TtsAdapter, TtsAwaitAdapter {
  @override
  Future<String?> getDefaultEngine() async => 'fake';
  @override
  Future<List<String>> getEngines() async => const ['fake'];
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
  @override
  Future<bool> speakAndWait(String text) async => true;
}

const _dialog = "A: How's it going?\nB: Pretty good, thanks.";

const _csv = 'front,back,module_name\n'
    '"a cup of coffee",一杯咖啡,点单\n'
    '"main course",主菜,餐厅\n';

void main() {
  late Directory tmp;
  late ProgressService progress;
  late ContentPack content;
  late LicenseState license;
  late TtsService tts;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('import_ui_v2');
    progress = ProgressService(db: AppDatabase(path: '${tmp.path}/t.db'));
    await progress.init();
    content = ContentPack(version: 'test', levels: [_level('A', 12)]);
    // 保存要过付费门；本文件测的是落库链路，用老用户身份放行。
    license = LicenseState(db: progress.database, legacyEligible: true);
    await license.load();
    tts = TtsService(adapter: _FakeTts());
  });

  Widget app(UserPackageFiles files) => MultiProvider(
        providers: [
          Provider<ProgressService>.value(value: progress),
          Provider<ContentPack>.value(value: content),
          ChangeNotifierProvider<LicenseState>.value(value: license),
          Provider<TtsService>.value(value: tts),
        ],
        child: MaterialApp(home: UserImportScreen(files: files)),
      );

  testWidgets('首屏说人话：粘贴 → 整理 → 保存；没保存前一行都不写', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = UserPackageFiles(dir: '${tmp.path}/user_packages');

    await tester.runAsync(() async {
      await tester.pumpWidget(app(files));
      await _pumpUntil(tester, find.text('添加我的英文本'));

      expect(find.text('把想学的英文粘进来'), findsOneWidget);
      expect(find.text('从剪贴板粘贴'), findsOneWidget);
      expect(find.text('这本叫什么'), findsOneWidget);
      expect(find.text('整理成句子'), findsOneWidget);
      // 技术词不进首屏：表格/文件收在折叠区里。
      expect(find.textContaining('CSV'), findsNothing);
      expect(find.textContaining('front'), findsNothing);

      await tester.enterText(find.byKey(const Key('userpkg_input')), _dialog);
      await tester.pump();
      await tester.tap(find.byKey(const Key('userpkg_parse')));
      await tester.pump();

      expect(find.textContaining('整理好了'), findsOneWidget);
      expect(find.text('保存并开始学'), findsOneWidget);
      expect(find.text('先不存'), findsOneWidget);

      // 先不存：一行都不写。
      await tester.tap(find.text('先不存'));
      await tester.pump();
      expect(await UserPackageStore(progress.database).userRowCount(), 0);
      expect(await UserPackageStore(progress.database).listPackages(), isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('保存并开始学 → 落库 + 官方计数不变 + 直接进六步', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final files = UserPackageFiles(dir: '${tmp.path}/user_packages');

    await tester.runAsync(() async {
      await tester.pumpWidget(app(files));
      await _pumpUntil(tester, find.text('添加我的英文本'));

      await tester.enterText(find.byKey(const Key('userpkg_input')), _dialog);
      await tester.pump();
      await tester.tap(find.byKey(const Key('userpkg_parse')));
      await tester.pump();

      final officialBefore =
          (await progress.chunkStore.allMasteredKeys()).length;
      await tester.tap(find.byKey(const Key('userpkg_save')));
      // 保存完直接开六步——不是回到详情页再点一次。
      await _pumpUntil(tester, find.textContaining('学习 · 我的英语本'));

      final store = UserPackageStore(progress.database);
      expect(await store.userRowCount(), 2);
      expect((await store.listPackages()).single.chunkCount, 2);
      // 官方口径一字不变（排除在库层生效，UI 路径同样吃这条）。
      expect((await progress.chunkStore.allRows())
          .any((r) => isUserChunkKey(r.chunkKey)), isFalse);
      expect((await progress.chunkStore.allMasteredKeys()).length,
          officialBefore);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('老文件入口：示例写得出来，文件读得回来', (tester) async {
    // 展开区 + 预览结果一起出现在长列表里，给足高度让它们都构建出来。
    await tester.binding.setSurfaceSize(const Size(900, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = '${tmp.path}/user_packages';
    final files = UserPackageFiles(dir: dir);

    await tester.runAsync(() async {
      await tester.pumpWidget(app(files));
      await _pumpUntil(tester, find.text('添加我的英文本'));

      await tester.tap(find.byKey(const Key('userpkg_advanced')));
      await _settle(tester);
      await tester.ensureVisible(find.text('下载示例表格（CSV）'));
      await tester.pump();
      await tester.tap(find.text('下载示例表格（CSV）'));
      await _pumpUntil(tester, find.textContaining('整理好了'));

      final written = File('$dir${Platform.pathSeparator}chunkspoke-模板.csv');
      expect(await written.exists(), isTrue);
      expect((await written.readAsString()).contains('front,back,module_name'),
          isTrue);

      // 目录里放一份自定义表 → 刷新 → 用这份 → 自动整理。
      await File('$dir${Platform.pathSeparator}我的词表.csv').writeAsString(_csv);
      await tester.tap(find.text('刷新'));
      await _pumpUntil(tester, find.text('我的词表.csv'));
      final row = find.ancestor(
          of: find.text('我的词表.csv'), matching: find.byType(ListTile));
      await tester.tap(find.descendant(of: row, matching: find.text('用这份')));
      await _pumpUntil(tester, find.textContaining('整理好了'));

      // 只是整理，没有保存。
      expect(await UserPackageStore(progress.database).userRowCount(), 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

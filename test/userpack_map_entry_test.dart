import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/map.dart';
import 'package:chunkspoke_flutter/screens/user_import_screen.dart';
import 'package:chunkspoke_flutter/screens/user_package_detail_screen.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// ASR-223 v2 / ASR-228 D3 / ASR-229 D4 件 3 钉测：
/// 地图「我的模块」分区 = 入口可达 + **只读不写** + 列出真包。
///
/// v1 的缺口是「页面存在但没有导航入口」；v2 补了入口但分区还是占位；
/// D4 把两条都钉死：分区必须真读包档案（不许退回占位），同时不许出现任何写路径。
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

/// 去注释后的源码：红线扫描只看代码，不能被文档注释里的 API 名字误伤。
String _code(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 「我的模块」分区本体（含它的 State 类，到 `_SceneRow` 为止）。
String _sectionSrc() {
  final src = File('lib/screens/map.dart').readAsStringSync();
  final start = src.indexOf('class _UserModuleSection');
  final end = src.indexOf('class _SceneRow');
  expect(start, greaterThan(0), reason: '「我的模块」分区被删了');
  expect(end, greaterThan(start), reason: '找不到分区结尾');
  return _code(src.substring(start, end));
}

Future<ProgressService> _service() async {
  final dir = await Directory.systemTemp.createTemp('d4_map_entry');
  final p = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
  await p.init();
  return p;
}

Future<void> _pumpMap(WidgetTester tester, ProgressService progress) async {
  final content =
      ContentPack(version: 'test', levels: [_level('A', 'Greetings', 12)]);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ProgressService>.value(value: progress),
      Provider<ContentPack>.value(value: content),
    ],
    child: const MaterialApp(home: MapScreen()),
  ));
  await _pumpUntil(tester, find.text('我的模块'));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('红线升级：分区只读不写（读包档案必须、任何写路径即红）', () {
    final section = _sectionSrc();
    // 写入出口 / 删包 / 断点 / 官方台账 API —— 分区一概不许出现。
    for (final forbidden in [
      'importValidation',
      'removePackage',
      'applyImportedRows',
      'setLearnResume',
      'clearLearnResume',
      'upsertChunksAndKv',
      'deleteChunksByKeys',
      'setKv',
      'resetChunks',
      'chunkStore',
    ]) {
      expect(section.contains(forbidden), isFalse,
          reason: '分区出现了写路径 $forbidden —— D4 的红线是「只读不写」');
    }
    // D4 件 3 的反向钉：不许退回 v2 的「纯占位分区」。
    // ASR-233：读的是盘点（inspect）而不是好包列表——坏档案也要在分区里看得见。
    for (final required in [
      'UserPackageStore',
      'inspect',
      'corruptCount',
      'DiagnosticsScreen', // 坏档案红牌必须给一条去诊断的路，不能只报错不给出口
      'UserPackageDetailScreen',
      'UserImportScreen',
    ]) {
      expect(section.contains(required), isTrue,
          reason: '分区缺了 $required —— 「我的模块」必须列真包，不能只放一个入口');
    }
  });

  testWidgets('未导入时分区给空态说明，点入口即达落库版导入器（三入口都在）',
      (tester) async {
    // 首屏可见性也是验收项：分区排在「自由造句沙盒」卡之后、关卡列表之前。
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _service();
      await _pumpMap(tester, progress);

      expect(find.text('导入我自己的词块（CSV / JSON）'), findsOneWidget);
      expect(find.textContaining('确认前不写入'), findsOneWidget);
      expect(find.textContaining('还没有导入过的包'), findsOneWidget);

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
      // ASR-229 §二·① 裁定：不加 SAF，就把「日常导入请用粘贴」写在文件入口上。
      expect(find.textContaining('这个入口是给已经从电脑'), findsOneWidget);
      expect(
          find.textContaining('未点「确认导入（将写入本机）」之前，不写入任何东西'),
          findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('已导入的包列在分区里，点进去是只读详情（删除讲级联、也讲不动什么）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _service();
      final store = UserPackageStore(progress.database);
      final v = parseAndValidateUserPackage('front,back,module_name\n'
          '"a cup of coffee",一杯咖啡,点单\n'
          '"the bill, please",买单,点单\n');
      expect(v.ok, isTrue, reason: v.firstErrorText);
      expect((await store.importValidation(v, allowed: true)).ok, isTrue);

      await _pumpMap(tester, progress);

      // 真包体出现在分区：模块名 + 块数 + 「不进官方口径」的一句话。
      expect(find.text('点单'), findsOneWidget);
      expect(find.textContaining('2 块 · '), findsOneWidget);
      expect(find.textContaining('不进官方已掌握数与复习排期'), findsOneWidget);
      expect(find.textContaining('还没有导入过的包'), findsNothing);
      expect(find.textContaining('本机 1/5 个包'), findsOneWidget);

      await tester.tap(find.text('点单'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await _pumpUntil(tester, find.byType(UserPackageDetailScreen));
      // 详情页不超实装：明说还不能走六步；删除按钮明写是级联的。
      await _pumpUntil(tester, find.textContaining('还不能像官方模块那样走六步学习'));
      expect(find.text('删除这个包（含级联清理）'), findsOneWidget);

      await tester.tap(find.text('删除这个包（含级联清理）'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await _pumpUntil(tester, find.textContaining('会一起清掉'));
      expect(find.textContaining('官方模块的已掌握数、复习排期、断点，以及其他自定义包'),
          findsOneWidget);
      expect(find.textContaining('同一份表随时可以再导回来'), findsOneWidget);

      // 只点进来看，不真的删：包还在。
      expect((await store.listPackages()).length, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  // ── ASR-233 A4：坏档案不许在分区里隐身 ────────────────────────────────
  testWidgets('一份档案坏掉：分区出红牌 + 好包照列，不谎称「还没有导入过的包」',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _service();
      final store = UserPackageStore(progress.database);
      for (final csv in [
        'front,back,module_name\n"a cup of coffee",一杯咖啡,点单\n',
        'front,back,module_name\n"central heating",集中供暖,家居\n',
      ]) {
        final v = parseAndValidateUserPackage(csv);
        expect(v.ok, isTrue, reason: v.firstErrorText);
        expect((await store.importValidation(v, allowed: true)).ok, isTrue);
      }
      // 把「家居」的档案打成不可解析（模拟半途写入/外部改动）。
      final home = (await store.listPackages())
          .firstWhere((r) => r.moduleName == '家居');
      await progress.database
          .setKv('${AppDatabase.kUserPkgKvPrefix}${home.moduleKey}', '{坏掉的档案');
      expect((await store.listPackages()).map((r) => r.moduleName), ['点单'],
          reason: '列表侧仍跳过坏档案（不炸 UI），但分区必须把这件事说出来');

      await _pumpMap(tester, progress);
      await _pumpUntil(tester, find.text('1 份包档案读不出来'));
      expect(find.text('点单'), findsOneWidget);
      expect(find.textContaining('还没有导入过的包'), findsNothing);
      expect(find.textContaining('重新导入同名模块即可修好'), findsOneWidget);
      expect(find.byKey(const Key('userCorruptNotice')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('唯一的包档案坏掉：红牌顶上空态，名额行不许谎报 0/5', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.runAsync(() async {
      final progress = await _service();
      final store = UserPackageStore(progress.database);
      final v = parseAndValidateUserPackage(
          'front,back,module_name\n"a cup of coffee",一杯咖啡,点单\n');
      expect((await store.importValidation(v, allowed: true)).ok, isTrue);
      final rec = (await store.listPackages()).single;
      await progress.database
          .setKv('${AppDatabase.kUserPkgKvPrefix}${rec.moduleKey}', 'not-json');

      await _pumpMap(tester, progress);
      await _pumpUntil(tester, find.text('1 份包档案读不出来'));
      expect(find.textContaining('还没有导入过的包'), findsNothing);
      expect(find.textContaining('本机 0/5 个包'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

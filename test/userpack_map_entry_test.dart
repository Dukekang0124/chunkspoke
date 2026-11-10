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

/// ASR-223 v2 / ASR-228 D3 / ASR-229 D4 件 3 / 1.9.2 钉测：
/// 地图「我的英语本」分区 = 入口可达 + **只读不写** + 列出真本子。
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

/// 「我的英语本」分区本体（含它的 State 类，到 `_SceneRow` 为止）。
String _sectionSrc() {
  final src = File('lib/screens/map.dart').readAsStringSync();
  final start = src.indexOf('class _UserModuleSection');
  final end = src.indexOf('class _SceneRow');
  expect(start, greaterThan(0), reason: '「我的英语本」分区被删了');
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
  await _pumpUntil(tester, find.text('我的英语本'));
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
          reason: '分区缺了 $required —— 「我的英语本」必须列真本子，不能只放一个入口');
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

      expect(find.text('把想学的英文存进来'), findsOneWidget);
      expect(find.textContaining('粘贴就能整理成能学的句子'), findsOneWidget);
      expect(find.textContaining('这里还是空的'), findsOneWidget);

      await tester.tap(find.text('把想学的英文存进来'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      expect(find.byType(UserImportScreen), findsOneWidget);
      expect(find.text('添加我的英文本'), findsOneWidget);
      // 主路径：粘贴 + 整理 + 保存；术语收进折叠区。
      expect(find.text('从剪贴板粘贴'), findsOneWidget);
      expect(find.text('整理成句子'), findsOneWidget);
      expect(find.textContaining('整理和预览不要钱'), findsOneWidget);
      expect(find.textContaining('CSV'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('已存的本子列在分区里，点进去能看到六步入口与级联删除说明', (tester) async {
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

      // 真本子出现在分区：名字 + 句数 + 「和官方分开记」的一句话。
      expect(find.text('点单'), findsOneWidget);
      expect(find.textContaining('2 句 · '), findsOneWidget);
      // 整行是「N 句 · X月X日存的 · 和官方内容分开记」；分区底部也有一句
      // 「你的英语本和官方内容分开记」，所以按带分隔符的那一行钉。
      expect(find.textContaining('· 和官方内容分开记'), findsOneWidget);
      expect(find.textContaining('这里还是空的'), findsNothing);
      expect(find.textContaining('手机上 1/5 本'), findsOneWidget);

      await tester.tap(find.text('点单'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await _pumpUntil(tester, find.byType(UserPackageDetailScreen));
      // ASR-234 更正：自定义本子已接入同一套六步闭环——详情页明说这一点，
      // 并给出唯一入口（「开始学 / 继续学」）；删除按钮仍明写会级联。
      await _pumpUntil(tester, find.textContaining('这些句子和官方内容用同一套练习'));
      expect(find.text('开始学'), findsOneWidget);
      expect(find.text('复习这本'), findsOneWidget);
      expect(find.textContaining('还不能像官方内容那样走六步'), findsNothing);
      expect(find.text('删掉这本'), findsOneWidget);

      await tester.tap(find.text('删掉这本'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await _pumpUntil(tester, find.textContaining('会一起删掉'));
      expect(find.textContaining('不会动：官方内容和学习记录，以及别的小本子。'),
          findsOneWidget);
      expect(find.textContaining('把内容重新粘一次就行'), findsOneWidget);

      // 只点进来看，不真的删：本子还在。
      expect((await store.listPackages()).length, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  // ── ASR-233 A4：坏档案不许在分区里隐身 ────────────────────────────────
  testWidgets('一份档案坏掉：分区出红牌 + 好本子照列，不谎称「这里还是空的」',
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
      await _pumpUntil(tester, find.text('有 1 本暂时打不开'));
      expect(find.text('点单'), findsOneWidget);
      expect(find.textContaining('这里还是空的'), findsNothing);
      expect(find.textContaining('用同一个名字重新存一次就能修好'), findsOneWidget);
      expect(find.byKey(const Key('userCorruptNotice')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('唯一的本子坏掉：红牌顶上空态，名额行不许谎报 0/5', (tester) async {
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
      await _pumpUntil(tester, find.text('有 1 本暂时打不开'));
      expect(find.textContaining('这里还是空的'), findsNothing);
      expect(find.textContaining('手机上 0/5 本'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

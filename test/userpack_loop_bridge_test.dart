import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/user_module_listening_screen.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/session.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';
import 'package:chunkspoke_flutter/services/user_text_parser.dart';
import 'package:chunkspoke_flutter/steps/practice_loop.dart';

/// ASR-234：自定义导入「三个入口 → 六步学习 → 词块库/磨耳朵」互通互链的钉死回归。
///
/// 每条都对着一个真实用户路径（不是假路径）：
///  1 粘贴入口：纯文本清单 → 模板骨架（只补 front，不自动翻译、不搅乱 CSV/JSON）；
///  2 合成场景：user 块装进与官方同款的 Level，id 全走 `user:` 命名空间；
///  3 六步落库：只写 user 行、不写断点 kv、不灌官方每日新学/掌握/到期；
///  4 定向替换：自定义包只用本包块做替代池，官方会话行为不变；
///  5 磨耳朵桥接：只朗读、零写库（渲染前后台账一字不动）。

const String _pastedList = '''1. how's it going?
2. I'm good, thanks.
3. Long time no see.
4. What's up?
5. See you around.
6. Take care.
7. Have a nice day.
8. Nice to meet you.
9. Let's keep in touch.
10. Catch you later.''';

const String _packageCsv = '''
front,back,module_name,example
how's it going?,最近怎么样,我的词表,How's it going today?
Take care.,保重,我的词表,
plate,盘子,我的词表,Wash the plate first.
''';

class _Fx {
  _Fx(this.db, this.p);
  final AppDatabase db;
  final ProgressService p;
}

Future<_Fx> _fx(String tag) async {
  final dir = await Directory.systemTemp.createTemp('userpack_bridge_$tag');
  final db = AppDatabase(path: '${dir.path}/t.db');
  final p = ProgressService(db: db);
  await p.init();
  return _Fx(db, p);
}

/// 走完六步的落库口径（与 PracticeLoop 完成块时一致；非锚定会话不传 alsoKv）。
Future<void> _learnChunk(ProgressService p, String key) async {
  await p.chunkStore.applyEvent(key, ChunkEvent.assembleCorrect);
  await p.chunkStore.applyEvent(key, ChunkEvent.dragCorrect);
  await p.chunkStore.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 90);
  await p.chunkStore.applyEvent(
    key,
    ChunkEvent.speakSuccess,
    accuracy: 95,
    fourStarsGreen: true,
    enforceFourStars: true,
  );
}

Future<UserPackageRecord> _importOne(AppDatabase db, String csv) async {
  final store = UserPackageStore(db);
  final r = await store.importValidation(parseAndValidateUserPackage(csv),
      allowed: true);
  expect(r.ok, isTrue, reason: r.note);
  return (await store.listPackages()).single;
}

/// 测试专用 TTS：不碰平台通道，speakAndWait 立即返回。
class _FakeTts implements TtsAdapter, TtsAwaitAdapter {
  int spoken = 0;
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
  Future<bool> speakAndWait(String text) async {
    spoken++;
    return true;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('粘贴入口：任意文本 → 认结构 → 同一个校验闸', () {
    test('编号清单：10 行全转出，编号剥掉，没写中文意思的如实留空', () {
      final plan = parsePastedUserText(_pastedList);
      expect(plan, isNotNull);
      expect(plan!.ok, isTrue);
      expect(plan.kindLabel, '一段英文');
      expect(plan.moduleName, kUserDefaultModuleName);
      expect(plan.entries.length, 10);
      expect(plan.pairedCount, 0);
      expect(plan.meaningMissing, 10);
      expect(plan.entries.first.front, "how's it going?");
      expect(plan.entries.first.back, '');
      expect(plan.entries.last.front, 'Catch you later.');
      expect(plan.notes.first, contains('整理成 10 句'));

      // 没写中文意思不是错误，更不会被静默翻译：空 back 直接过闸。
      expect(plan.validation.issues, isEmpty);
    });

    test('编号/项目符号只剥行首标记，小数、缩写、年份不被削', () {
      final plan = parsePastedUserText('3.14 is pi\n2.5 kg of rice\n2) second\n'
          '3、third\n- dash item\n• bullet item\n“quoted line”');
      expect(plan, isNotNull);
      final fronts = plan!.entries.map((e) => e.front).toList();
      expect(fronts, contains('3.14 is pi'));
      expect(fronts, contains('2.5 kg of rice'));
      expect(fronts, contains('second'));
      expect(fronts, contains('third'));
      expect(fronts, contains('dash item'));
      expect(fronts, contains('bullet item'));
      expect(fronts, contains('quoted line'));
    });

    test('对话：剥掉说话人、认出是一段对话，句子照常拆开', () {
      final plan = parsePastedUserText(
          'Tom: How are you today?\nLily: I am fine, thanks.\nTom: Shall we go?\nLily: Sure.');
      expect(plan, isNotNull);
      expect(plan!.ok, isTrue);
      expect(plan.kindLabel, '一段对话');
      expect(plan.entries.map((e) => e.front).toList(),
          ['How are you today?', 'I am fine, thanks.', 'Shall we go?', 'Sure.']);
      expect(plan.entries.every((e) => !e.front.contains(':')), isTrue);
    });

    test('中英对照：竖线 / 制表符 / 英文下一行中文，都直接当释义', () {
      final plan = parsePastedUserText(
          'how are you | 你好吗\nTake care.\t保重\nplate\n盘子\nIt is a nice day.\n今天天气不错。');
      expect(plan, isNotNull);
      expect(plan!.ok, isTrue);
      expect(plan.kindLabel, '中英对照');
      expect(plan.pairedCount, 4);
      expect(plan.meaningMissing, 0);
      final pairs = {for (final e in plan.entries) e.front: e.back};
      expect(pairs['how are you'], '你好吗');
      expect(pairs['Take care.'], '保重');
      expect(pairs['plate'], '盘子');
      expect(pairs['It is a nice day.'], '今天天气不错。');
    });

    test('一整段英文按句切开：小数点、缩写不乱切', () {
      final plan = parsePastedUserText(
          'I get up at 6.30 every morning. Mr. Smith drives me to school! Do you know why?');
      expect(plan, isNotNull);
      expect(plan!.entries.map((e) => e.front).toList(), [
        'I get up at 6.30 every morning.',
        'Mr. Smith drives me to school!',
        'Do you know why?',
      ]);
      expect(plan.kindLabel, '一段英文');
    });

    test('重复句合并计数；超过 200 句按上限截断并如实报数', () {
      final dup = parsePastedUserText('Hello.\nhello.\nHello.');
      expect(dup, isNotNull);
      expect(dup!.entries.length, 1);
      expect(dup.duplicates, 2);

      final raw = [for (var i = 1; i <= kUserPackageMaxChunks + 5; i++) '$i. word$i']
          .join('\n');
      final big = parsePastedUserText(raw);
      expect(big, isNotNull);
      expect(big!.entries.length, kUserPackageMaxChunks);
      expect(big.skipped, 5);
      expect(big.entries.last.front, 'word$kUserPackageMaxChunks');
    });

    test('没有英文 / 没有内容：给一句人话，而不是硬造条目', () {
      final cn = parsePastedUserText('今天天气不错。\n我们下午去公园吧。');
      expect(cn, isNotNull);
      expect(cn!.ok, isFalse);
      expect(cn.validation.firstErrorText, contains('没认出英文内容'));
      expect(cn.entries, isEmpty);
      expect(cn.droppedNonEnglish, 2);

      final empty = parsePastedUserText('   \n ');
      expect(empty, isNotNull);
      expect(empty!.ok, isFalse);
      expect(empty.validation.firstErrorText, contains('先把想学的英文粘贴进来'));
    });

    test('已经像表格 / JSON 的返回 null，交给表格入口，不硬切', () {
      expect(parsePastedUserText('front,back,module_name\nplate,盘子,餐饮点餐'), isNull);
      expect(parsePastedUserText('{"chunks": []}'), isNull);
      expect(parsePastedUserText('[{"front":"plate"}]'), isNull);
      expect(parsePastedUserText('a,b,c\nd,e,f'), isNull);
    });
  });

  group('粘贴 → 直接进六步（没有中文意思也照常能学）', () {
    test('粘进来的纯英文清单能保存，学的时候只是不显示翻译', () async {
      final f = await _fx('paste_e2e');
      final plan = parsePastedUserText(_pastedList);
      expect(plan, isNotNull);

      final store = UserPackageStore(f.db);
      final r = await store.importValidation(plan!.validation, allowed: true);
      expect(r.ok, isTrue, reason: r.note);
      expect(r.writtenChunks, 10);

      final rec = (await store.listPackages()).single;
      final level = PracticeSession.userModuleLevel(rec);
      expect(level.chunks.length, 10);
      expect(level.chunks.every((c) => c.meaningCN.isEmpty), isTrue);
      expect(level.chunks.every((c) => isUserChunkKey(c.id)), isTrue);
      expect(level.chunks.first.text, "how's it going?");
    });
  });

  group('自定义包 → 与官方同款的合成场景', () {
    test('Level 形状：id=moduleKey、块/句一律 user: 键、整句用 example 优先', () async {
      final f = await _fx('level');
      final rec = await _importOne(f.db, _packageCsv);
      final level = PracticeSession.userModuleLevel(rec);

      expect(level.id, rec.moduleKey);
      expect(isUserModuleKey(level.id), isTrue);
      expect(level.theme, rec.moduleName);
      expect(level.chunks.length, rec.entries.length);
      expect(level.sentences.length, rec.entries.length);

      for (var i = 0; i < rec.entries.length; i++) {
        final e = rec.entries[i];
        expect(level.chunks[i].id, e.chunkKey);
        expect(isUserChunkKey(level.chunks[i].id), isTrue);
        expect(level.chunks[i].text, e.front);
        expect(level.chunks[i].meaningCN, e.back);
        expect(level.sentences[i].chunkIds, [e.chunkKey]);
        expect(level.sentences[i].text, e.sentenceSourceText ?? e.front);
        // 定向替换没有官方搭档可用：单块包退化为原句复述，不伪造替换项。
        expect(level.chunks[i].sentence.swapSlotIndex, -1);
        expect(level.chunks[i].sentence.swapOptions, isEmpty);
        expect(level.chunks[i].sources.single, contains(rec.moduleName));
      }

      final withExample = rec.entries
          .firstWhere((e) => e.front == "how's it going?");
      final sentence =
          level.sentences[rec.entries.indexOf(withExample)].text;
      expect(sentence, 'How\'s it going today?');
    });
  });

  group('六步落库：只动 user 行，官方计数一字不动', () {
    test('学完 user 块后，官方每日新学/掌握/台账/断点/到期全不变', () async {
      final f = await _fx('counters');
      final rec = await _importOne(f.db, _packageCsv);
      final level = PracticeSession.userModuleLevel(rec);

      // 官方基线：一块已掌握 + 今日新学 1 + 某官方关卡的断点。
      await f.db.upsertChunk(const ChunkRow(
        chunkKey: 'sv01',
        level: ChunkLevel.mastered,
        dueDate: 0,
        failCount: 0,
        lastScore: 95,
        l2OneTry: 1,
        assetState: ChunkAssetState.mastered,
        firstLearnedAt: 1,
      ));
      await f.p.bumpDailyNew();
      await f.p.setLearnResume('official_scene', 'snap-keep');

      expect(f.p.dailyNewCount, 1);
      expect(await f.p.chunkStore.assetMasteredCount(), 1);
      final dueBefore = await f.db.dueChunks(DateTime.now().millisecondsSinceEpoch);

      // 学掉自定义包的前两块（与 PracticeLoop 六步落库同口径）。
      final keys = [for (final e in rec.entries) e.chunkKey];
      await _learnChunk(f.p, keys[0]);
      await _learnChunk(f.p, keys[1]);

      // 官方口径：计数、掌握数、台账、到期队列全部原样。
      expect(f.p.dailyNewCount, 1, reason: 'user 块不能灌进官方「今日新学」');
      expect(await f.p.chunkStore.assetMasteredCount(), 1);
      final officialRows = await f.p.chunkStore.allRows();
      expect(officialRows.map((r) => r.chunkKey), ['sv01']);
      expect(officialRows.single.assetState, ChunkAssetState.mastered);
      expect((await f.db.dueChunks(DateTime.now().millisecondsSinceEpoch))
          .map((r) => r.chunkKey), dueBefore.map((r) => r.chunkKey));

      // 断点：官方关卡原样，自定义会话不写任何 learnResume。
      expect(f.p.learnResume('official_scene'), 'snap-keep');
      expect(f.p.learnResume(level.id), isNull);
      expect(await f.db.getKv('learnResume_${level.id}'), isNull);

      // user 台账：前两块走完六步（资产轴=已巩固，进自己的 1 天复习档），第三块仍未开始。
      final userRows = {for (final r in await f.db.allUserChunks()) r.chunkKey: r};
      expect(userRows.length, 3);
      for (final k in keys.take(2)) {
        final row = userRows[k]!;
        expect(row.assetState, ChunkAssetState.consolidated);
        expect(ChunkProgressStore.isMastered(row), isTrue);
        expect(row.dueDate, greaterThan(0), reason: '学完要排进自己的复习阶梯');
      }
      expect(userRows[keys[2]]!.assetState, ChunkAssetState.learning);

      // 断点派生只认官方关卡：nextUnmasteredIndex 能在 user 包内正常续学。
      expect(await f.p.chunkStore.nextUnmasteredIndex(keys), 2);
    });

    test('官方关卡学完后照旧记账（对照：user 特判没有误伤官方路径）', () async {
      final f = await _fx('control');
      await f.db.upsertChunk(const ChunkRow(
        chunkKey: 'sv01',
        level: ChunkLevel.l1,
        dueDate: 0,
        failCount: 0,
        lastScore: 0,
        l2OneTry: -1,
        assetState: ChunkAssetState.learning,
      ));
      await _learnChunk(f.p, 'sv01');
      // onNewMastery 是刻意不阻塞学习的 fire-and-forget 钩子，等它落完缓存再断言。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(f.p.dailyNewCount, 1);
      expect(await f.p.chunkStore.assetMasteredCount(), 0,
          reason: '首轮六步只到「已巩固」，资产轴 mastered 要走完整复习阶梯');
      final row = (await f.db.allChunks()).single;
      expect(row.assetState, ChunkAssetState.consolidated);
      expect(ChunkProgressStore.isMastered(row), isTrue);
      expect(row.dueDate, greaterThan(0));
    });
  });

  group('定向替换替代池：用户包只用本包块', () {
    test('user_module 级只返回本包块；官方级仍用全量官方块池', () async {
      final f = await _fx('pool');
      final rec = await _importOne(f.db, _packageCsv);
      final userLevel = PracticeSession.userModuleLevel(rec);
      final official = [
        Chunk.fromJson({'id': 'sv01', 'text': 'good morning', 'type': 'content'}),
        Chunk.fromJson({'id': 'sv02', 'text': 'see you', 'type': 'content'}),
      ];

      final userPool =
          substitutionPoolFor(level: userLevel, allChunks: official);
      expect(identical(userPool, userLevel.chunks), isTrue);
      expect(userPool.map((c) => c.id), everyElement(startsWith('user:')));

      final officialLevel = Level(
          id: 'scene_sv', theme: 'Daily', sceneImage: '', chunks: official);
      final officialPool =
          substitutionPoolFor(level: officialLevel, allChunks: official);
      expect(identical(officialPool, official), isTrue);
      expect(officialPool.map((c) => c.id), ['sv01', 'sv02']);
    });
  });

  group('磨耳朵桥接：只朗读，零写库', () {
    testWidgets('页面渲染全部行与诚实文案；渲染前后台账/档案不变', (tester) async {
      // sqflite_ffi 走真实 I/O，widget 测试跑在 FakeAsync 里，必须用 runAsync
      // 才不会把「等真实线程」当成永不结束的 await。
      late _Fx f;
      late UserPackageRecord rec;
      late List<ChunkRow> rowsBefore;
      String? archiveBefore;
      await tester.runAsync(() async {
        f = await _fx('listen');
        rec = await _importOne(f.db, _packageCsv);
        rowsBefore = await f.db.allUserChunks();
        archiveBefore =
            await f.db.getKv('${AppDatabase.kUserPkgKvPrefix}${rec.moduleKey}');
      });

      final tts = TtsService(adapter: _FakeTts());
      await tester.pumpWidget(Provider<TtsService>.value(
        value: tts,
        child: MaterialApp(home: UserModuleListeningScreen(rec: rec)),
      ));
      // 这一页没有动画，单帧即可；不用 pumpAndSettle（曾因常驻帧调度空转到超时）。
      await tester.pump();

      expect(find.byKey(const Key('userlisten_current')), findsOneWidget);
      // 第一行是 example（整句优先），不是只有 front；主卡与行列表各出现一次。
      expect(find.text('How\'s it going today?'), findsNWidgets(2));
      expect(find.text('只念给你听，不改学习进度、不排复习，也不算进官方的数。'),
          findsOneWidget);
      for (var i = 0; i < rec.entries.length; i++) {
        expect(find.byKey(Key('userlisten_line_$i')), findsOneWidget);
      }

      // 结构性边界：这一页没有写库通道，台账与档案必须一字不动。
      await tester.runAsync(() async {
        final rowsAfter = await f.db.allUserChunks();
        expect(rowsAfter.length, rowsBefore.length);
        expect(rowsAfter.map((r) => r.assetState),
            everyElement(ChunkAssetState.learning));
        expect(
            await f.db.getKv('${AppDatabase.kUserPkgKvPrefix}${rec.moduleKey}'),
            archiveBefore);
        expect(await f.db.allChunks(), isEmpty);
      });
    });
  });
}

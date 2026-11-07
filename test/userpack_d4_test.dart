import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/self_check.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';
import 'package:chunkspoke_flutter/steps/l4_step.dart' show machineUncertain;

/// ASR-229 · D4 保障四件（自检扩区 / 卸载级联 / 地图分区列真包 / 低置信 UI）。
///
/// 一句话口径：**落库之后的事**——写进去的东西要看得见（分区）、算得清（自检）、
/// 删得干净（级联），并且机器没把握时不许把锅甩给用户（低置信 UI）。
/// 地图分区的 UI 钉测在 `test/userpack_map_entry_test.dart`，本文件管另外三件 + 判据真值表。
Level _level(String id, int count) => Level(
      id: id,
      theme: 'D4 $id',
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

late ProgressService _p;
late ContentPack _content;

Future<void> _freshDb() async {
  final dir = await Directory.systemTemp.createTemp('d4_guards');
  _p = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
  await _p.init();
  final d = await _p.database.db;
  await d.delete('chunks');
  await d.delete('kv');
  await d.delete('sessions');
  _content = ContentPack(version: 'test', levels: [_level('M', 8)]);
  _p.setChunkTiers(_content);
}

Future<UserPackageValidation> _validate(String text) =>
    Future.value(parseAndValidateUserPackage(text));

/// 去注释后的源码：结构闸只看代码，不能被注释里的说明文字误伤。
String _code(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 官方口径的一次性快照（级联删除前后必须逐字段相同）。
Future<Map<String, Object?>> _officialSnapshot() async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final db = _p.database;
  return {
    'mastered': (await db.allMasteredKeys()).length,
    'rows': (await db.allChunks()).length,
    'due': await db.countDueChunks(now),
    'assetCounts': (await db.assetStateCounts()).toString(),
    'assetMastered': await db.countAssetMastered(),
    'masteredKeys': (await db.allMasteredKeys()).join(','),
    'topFail': (await db.topFailChunks(5)).map((r) => r.chunkKey).join(','),
    'nextDue': await db.nextDueTimestamp(now),
    'earliestDue': await db.earliestDueTimestamp(),
    'resume': await _p.learnResumeFromDb('M'),
  };
}

const _csvTwoRows = 'front,back,module_name\n'
    '"a cup of coffee",一杯咖啡,点单\n'
    '"the bill, please",买单,点单\n';

const _csvOtherModule = 'front,back,module_name\n'
    '"central heating",集中供暖,家居\n';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ── D4 件 1：自检扩区（含坏档案的连坐项，不许静默跳过）────────────────
  group('自检扩区：我的模块', () {
    test('空库 = pass 一行，不制造假警', () async {
      await _freshDb();
      final inv = await UserPackageStore(_p.database).inspect();
      expect(inv.packageCount, 0);
      expect(inv.consistent, isTrue);
      final rows = SelfCheck.userPackageRows(inv);
      expect(rows, hasLength(1));
      expect(rows.single.state, CheckState.pass);
      expect(rows.single.value, contains('未导入任何自定义包'));
    });

    test('正常导入 = pass，并把「档案声明 / 台账行数」两个数并排打出来', () async {
      await _freshDb();
      final store = UserPackageStore(_p.database);
      await store.importValidation(await _validate(_csvTwoRows), allowed: true);
      final inv = await store.inspect();
      expect(inv.consistent, isTrue, reason: jsonEncode(inv.toJson()));
      expect(inv.packageCount, 1);
      expect(inv.declaredChunks, 2);
      expect(inv.userRowCount, 2);
      final row = SelfCheck.userPackageRows(inv).first;
      expect(row.state, CheckState.pass);
      expect(row.value, contains('1 个包'));
      expect(row.value, contains('档案声明 2 块'));
      expect(row.value, contains('台账 2 行'));
    });

    test('坏档案 = 列表跳过但自检必须判红，且它的行连坐成孤儿（连坐项）', () async {
      await _freshDb();
      final store = UserPackageStore(_p.database);
      await store.importValidation(await _validate(_csvTwoRows), allowed: true);
      // 手改档案：把 JSON 打成不可解析（模拟半途写入/外部改动）。
      final inv0 = await store.inspect();
      final key = inv0.packages.single.moduleKey;
      await _p.database.setKv('${AppDatabase.kUserPkgKvPrefix}$key', '{坏掉的档案');

      final list = await store.listPackages();
      expect(list, isEmpty, reason: '列表侧仍要跳过坏档案，不能炸 UI');

      final inv = await store.inspect();
      expect(inv.corruptCount, 1, reason: '但坏档案必须被数出来');
      expect(inv.strayRows, 2, reason: '档案读不出来 → 它声明的 2 行没人认领 = 连坐');
      expect(inv.consistent, isFalse);

      final rows = SelfCheck.userPackageRows(inv);
      expect(rows.first.state, CheckState.warn);
      expect(rows.any((r) => r.label == '坏档案' && r.state == CheckState.fail), isTrue,
          reason: '坏档案必须判红（fail），不许只是黄牌');
      expect(rows.firstWhere((r) => r.label == '坏档案').value, contains('重新导入'));
      expect(rows.any((r) => r.label == '台账有、档案无'), isTrue);
    });

    test('档案有、台账无（半截写入）→ 判红并给出差额', () async {
      await _freshDb();
      final store = UserPackageStore(_p.database);
      await store.importValidation(await _validate(_csvTwoRows), allowed: true);
      final inv0 = await store.inspect();
      // 直接删掉台账里的一行（档案仍然声明 2 块）：制造「档案有、台账无」。
      await _p.database.deleteChunksByKeys(
          [inv0.packages.single.entries.first.chunkKey]);

      final inv = await store.inspect();
      expect(inv.declaredChunks, 2);
      expect(inv.userRowCount, 1);
      expect(inv.missingRows, 1);
      expect(inv.consistent, isFalse);
      final rows = SelfCheck.userPackageRows(inv);
      final r = rows.firstWhere((x) => x.label == '档案有、台账无');
      expect(r.state, CheckState.fail);
      expect(r.value, contains('差 1'));
    });

    test('assemble 只在真的有内容时加「我的模块」区块（诊断页不出现空区）', () {
      const ok = UserPackageInventory(
          packages: [], corruptCount: 0, userRowCount: 0,
          declaredChunks: 0, missingRows: 0, strayRows: 0);
      final withOut = SelfCheck.assemble(
        at: DateTime(2026, 11, 6),
        audits: const [],
        engine: const [CheckRow('离线模型', '已就位', CheckState.pass)],
        packs: const [CheckRow('高清发音包', '未下载', CheckState.warn)],
        audio: const [CheckRow('音频缓存', '暂无', CheckState.warn)],
        update: const [CheckRow('本机版本', 'versionCode 1', CheckState.pass)],
        localVersion: 'test',
        localVersionCode: 1,
        user: SelfCheck.userPackageRows(ok),
      );
      expect(withOut.sections.any((s) => s.title == '我的模块'), isTrue);

      final plain = SelfCheck.assemble(
        at: DateTime(2026, 11, 6),
        audits: const [],
        engine: const [CheckRow('离线模型', '已就位', CheckState.pass)],
        packs: const [CheckRow('高清发音包', '未下载', CheckState.warn)],
        audio: const [CheckRow('音频缓存', '暂无', CheckState.warn)],
        update: const [CheckRow('本机版本', 'versionCode 1', CheckState.pass)],
        localVersion: 'test',
        localVersionCode: 1,
      );
      expect(plain.sections.any((s) => s.title == '我的模块'), isFalse);
    });
  });

  // ── D4 件 2：卸载级联（删包只清自己的东西，官方一字不动）──────────────
  group('卸载级联', () {
    test('删一个包：该包行 + 档案一起清；另一个包与官方口径分毫不动', () async {
      await _freshDb();
      final store = UserPackageStore(_p.database);
      // 官方进度：前 3 块走完六步。
      final keys = _content.levels.first.chunks.map((c) => c.id).toList();
      for (final k in keys.take(3)) {
        await _p.chunkStore.applyEvent(k, ChunkEvent.assembleCorrect);
        await _p.chunkStore.applyEvent(k, ChunkEvent.dragCorrect);
        await _p.chunkStore.applyEvent(k, ChunkEvent.accuracyPass, accuracy: 92);
        await _p.chunkStore.applyEvent(k, ChunkEvent.speakSuccess,
            accuracy: 95, fourStarsGreen: true, enforceFourStars: true);
      }
      await store.importValidation(await _validate(_csvTwoRows), allowed: true);
      await store.importValidation(await _validate(_csvOtherModule), allowed: true);
      expect(await store.userRowCount(), 3);

      final before = await _officialSnapshot();
      final bill = (await store.listPackages())
          .firstWhere((r) => r.moduleName == '点单');
      final removed = await store.removePackage(bill.moduleKey);
      expect(removed, 2);

      final after = await _officialSnapshot();
      expect(after, before, reason: '删自定义包不许动官方任何口径');
      expect(await store.userRowCount(), 1);
      final left = await store.listPackages();
      expect(left.map((r) => r.moduleName), ['家居']);
      // 档案清零（removePackage 写空串，listPackages/inspect 都不再认领它）。
      expect(await store.packageOf(bill.moduleKey), isNull);
      final inv = await store.inspect();
      expect(inv.corruptCount, 0);
      expect(inv.strayRows, 0, reason: '级联必须干净：不许留下没人认领的行');
      expect(inv.consistent, isTrue, reason: jsonEncode(inv.toJson()));
    });

    test('删不存在的包 = 0 行，且不写任何 kv', () async {
      await _freshDb();
      final store = UserPackageStore(_p.database);
      expect(await store.removePackage('user_module:deadbeef'), 0);
      expect(await store.listPackages(), isEmpty);
    });
  });

  // ── D4 件 4：低置信判据（阈值零改动，只把不确定说出口）─────────────────
  group('低置信 UI 判据', () {
    test('真值表：灰带/守门拒判/空/低置信/过短 = 机器没底；命中与文本比对 = 不算', () {
      expect(machineUncertain(passed: false, edited: false, softBand: true), isTrue);
      expect(
          machineUncertain(
              passed: false, edited: false, softBand: false, guardOk: false),
          isTrue);
      for (final reason in ['band', 'lowConf', 'empty', 'tooShort']) {
        expect(
            machineUncertain(
                passed: false, edited: false, softBand: false, reason: reason),
            isTrue,
            reason: reason);
      }
      // 反过来：文本确实不匹配（mismatch/coreMiss）是判卷结论，不是仪器没底。
      expect(
          machineUncertain(
              passed: false, edited: false, softBand: false, guardOk: true,
              reason: 'mismatch'),
          isFalse);
      expect(
          machineUncertain(passed: true, edited: false, softBand: true), isFalse,
          reason: '已经过了就别再弹不确定卡');
      expect(
          machineUncertain(passed: false, edited: true, softBand: false,
              reason: 'mismatch'),
          isFalse,
          reason: '手改文本/打字作答是文本比对，不是识别不确定');
      expect(
          machineUncertain(passed: false, edited: false, softBand: false),
          isFalse,
          reason: 'guardOk=null（无守门结论）+ 无 reason → 不许凭空宣布不确定');
    });

    test('静态闸：低置信判据里不许出现任何数字（阈值单源不许被 UI 侧复制）', () {
      final src = File('lib/steps/l4_step.dart').readAsStringSync();
      final start = src.indexOf('bool machineUncertain({');
      expect(start, greaterThan(0), reason: 'machineUncertain 被删了');
      final end = src.indexOf('\n}', start);
      final body = src.substring(start, end);
      expect(RegExp('[0-9]').hasMatch(body), isFalse,
          reason: '判据里出现数字 = 在 UI 侧偷偷新增阈值');
      expect(src.contains('_selfConfirm(true)'), isTrue);
      expect(src.contains("selfEval: true"), isTrue);
      // ASR-231 裁定②：卡片抽成共享组件（第 4/5/6 步同一份），文案钉测跟着组件走。
      final card = File('lib/ui/machine_unsure_card.dart').readAsStringSync();
      expect(card.contains('就是这句，算我说过'), isTrue, reason: '低置信卡片的一级出口没了');
      expect(card.contains('这台机器没把握，不是给你判错'), isTrue);
      expect(card.contains('不计发音分'), isTrue);
      expect(src.contains('MachineUnsureCard('), isTrue, reason: 'L4 没改用共享卡片');
      for (final f in [
        'lib/steps/substitute_step.dart',
        'lib/steps/free_use_step.dart',
      ]) {
        final s = File(f).readAsStringSync();
        expect(s.contains('MachineUnsureCard('), isTrue, reason: '$f 没复用共享卡片');
        expect(s.contains('machineUncertain('), isTrue,
            reason: '$f 自造判据 = 判据双源，阈值早晚会被抄第二份');
        expect(s.contains('这台机器没把握'), isFalse,
            reason: '$f 自己抄了一份卡片文案');
        expect(s.contains('就是这句，算我说过'), isFalse,
            reason: '$f 自己抄了一份一级出口文案');
      }
      // 判定阈值仍然单源：低置信 UI 不许在 lib/ 里复制第二份阈值定义。
      final defs = <String>[];
      for (final e in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!e.path.endsWith('.dart')) continue;
        final t = e.readAsStringSync();
        if (t.contains('const double kPhonRatio =') ||
            t.contains('const double kMatchMin =') ||
            t.contains('const double kCoreRatio =')) {
          defs.add(e.path.replaceAll(r'\', '/'));
        }
      }
      expect(defs.where((p) => p.endsWith('l4_step.dart')), isEmpty,
          reason: '判卷阈值被复制进了 L4：$defs');
    });
    test('装机腿抓到的坑钉死：失败屏可滚，小屏不许裁掉打字出口', () {
      // 模拟器 720×1600 实测：加了低置信卡片后，失败屏把「打字作答（不计发音分）」
      // 顶到屏幕外——那一出口是 ASR-216 明令「第一次失败就给」的，裁掉=红线。
      final raw = File('lib/steps/l4_step.dart').readAsStringSync();
      final src = _code(raw).split(RegExp(r'\s+')).join(' ');
      expect(src.contains('bool get _failureScreen =>'), isTrue,
          reason: '失败屏判定被删了（Spacer 条件会失去依据）');
      expect(
          src.contains('if (_failureScreen) const SizedBox(height: 10) else const Spacer()'),
          isTrue,
          reason: '失败态仍在用 Spacer 居中，内容一多就顶出屏幕');
      expect(
          src.contains('else if (_judge != null && !_passed) Expanded( '
              'child: SingleChildScrollView( child: Column('),
          isTrue,
          reason: '失败屏没包在可滚容器里');
      // 条件顺序必须与 build 的分支链一致，否则 _failureScreen 会与实际渲染不同步。
      for (final guard in ['!_permBlocked', '!_engineFailed', '!_showAnswer',
        '!_selfAssess', '!_followAlong', '!_thinking', '!_listening']) {
        expect(src.contains(guard), isTrue, reason: '_failureScreen 少了 $guard 这一条');
      }
    });

    test('ASR-233：第5步失败屏同样可滚，第6步卡片必须在滚动容器里', () {
      // 同一条装机腿教训：卡片一加，小屏就把原有出口顶出去。
      final sub = _code(File('lib/steps/substitute_step.dart').readAsStringSync())
          .split(RegExp(r'\s+'))
          .join(' ');
      expect(sub.contains('bool get _failureScreen =>'), isTrue);
      expect(
          sub.contains(
              'if (_failureScreen) const SizedBox(height: 10) else const Spacer()'),
          isTrue,
          reason: '第5步失败态还在用 Spacer 居中，卡片一加就顶出屏幕');
      expect(sub.contains('Expanded( child: SingleChildScrollView( child: Column('),
          isTrue, reason: '第5步失败屏没包在可滚容器里');
      // 卡片出现时不许再并排摆一个「自己算通过」旧出口（两个一级出口=用户猜）。
      expect(sub.contains('if (!_machineUnsure &&'), isTrue,
          reason: '旧的自评出口没有与卡片互斥');

      final free = _code(File('lib/steps/free_use_step.dart').readAsStringSync())
          .split(RegExp(r'\s+'))
          .join(' ');
      final scrollAt = free.indexOf('Expanded( child: SingleChildScrollView(');
      final cardAt = free.indexOf('if (_machineUnsure)');
      expect(scrollAt, greaterThan(0), reason: '第6步没有可滚容器');
      expect(cardAt, greaterThan(scrollAt), reason: '第6步卡片落在滚动容器之外');
    });
  });
}

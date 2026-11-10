import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/progress_integrity.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// ASR-228 · D3 落库件 2/3 的硬断言集。
///
/// 一句话口径：**用户包能写多少行，官方口径就得一个字不变**。
/// 所以这里不只测「写对了」，更测「官方每个读 API 看不见它」——
/// 排除口径在库层（`AppDatabase.kUserKeyExclude`）只有一份，
/// 本文件把每个官方读点都跑一遍，出现任何 `user:` 键即红。
Level _level(String id, int count) => Level(
      id: id,
      theme: 'Store $id',
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

late ContentPack _content;
late ProgressService _p;

Future<void> _freshDb() async {
  final dir = await Directory.systemTemp.createTemp('d3_store');
  _p = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
  await _p.init();
}

/// 造一份官方进度：前 6 块走完六步（其中 2 块已掌握），第 7 块学到一半。
Future<void> _seedOfficial() async {
  final keys = _content.levels.first.chunks.map((c) => c.id).toList();
  for (final k in keys.take(6)) {
    await _p.chunkStore.applyEvent(k, ChunkEvent.assembleCorrect);
    await _p.chunkStore.applyEvent(k, ChunkEvent.dragCorrect);
    await _p.chunkStore.applyEvent(k, ChunkEvent.accuracyPass, accuracy: 90);
    await _p.chunkStore.applyEvent(
        k, ChunkEvent.speakSuccess, accuracy: 95, fourStarsGreen: true, enforceFourStars: true);
  }
  for (final k in keys.take(2)) {
    for (var i = 0; i < 4; i++) {
      await _p.chunkStore.applyEvent(k, ChunkEvent.speakSuccess,
          accuracy: 95, review: true);
    }
  }
  await _p.chunkStore.applyEvent(keys[6], ChunkEvent.assembleCorrect);
}

Future<UserPackageValidation> _validate(String text) async =>
    parseAndValidateUserPackage(text);

const _csvTwoModules = 'front,back,module_name\n'
    '"a cup of coffee",一杯咖啡,点单\n'
    '"main course",主菜,餐厅\n';

const _csvOneModule = 'front,back,module_name\n'
    '"check in",值机,机场\n';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _content = ContentPack(version: 'test', levels: [_level('A', 12)]);
  });

  setUp(() async {
    await _freshDb();
    await _seedOfficial();
  });

  test('件 2：导入真的落库 —— 行数、包数、档案内容都对得上', () async {
    final v = await _validate(_csvTwoModules);
    expect(v.ok, isTrue, reason: v.issues.join(' / '));
    final res = await UserPackageStore(_p.database).importValidation(v, allowed: true);
    expect(res.ok, isTrue);
    expect(res.writtenChunks, 2);
    expect(res.moduleNames, containsAll(['点单', '餐厅']));

    final store = UserPackageStore(_p.database);
    expect(await store.userRowCount(), 2);
    final pkgs = await store.listPackages();
    expect(pkgs.length, 2);
    expect(pkgs.first.entries.first.front, isNotEmpty);
  });

  test('件 2 硬断言：每个官方读 API 都看不见 user: 键', () async {
    final before = await _officialSnapshot();
    final v = await _validate(_csvTwoModules);
    await UserPackageStore(_p.database).importValidation(v, allowed: true);

    final after = await _officialSnapshot();
    expect(after.masteredKeys.any(isUserChunkKey), isFalse, reason: '关卡轴漏排除');
    expect(after.assetMasteredKeys.any(isUserChunkKey), isFalse, reason: '资产轴 key 列表漏排除');
    expect(after.rows.any((r) => isUserChunkKey(r.chunkKey)), isFalse, reason: 'allRows 漏排除');
    expect(after.exportKeys.any(isUserChunkKey), isFalse, reason: '导出资产漏排除');
    expect(after.dueKeys.any(isUserChunkKey), isFalse, reason: '到期队列漏排除');
    expect(after.topFail.any((r) => isUserChunkKey(r.chunkKey)), isFalse, reason: '弱点榜漏排除');

    // 数字层面：官方计数一字不变。
    expect(after.masteredCount, before.masteredCount);
    expect(after.assetMastered, before.assetMastered);
    expect(after.assetTotal, before.assetTotal);
    expect(after.dueCount, before.dueCount);
    expect(after.spoken, before.spoken);
    expect(after.avgScore, before.avgScore);
    expect(after.nextDue, before.nextDue);
    expect(after.earliestDue, before.earliestDue);
  });

  test('件 2 硬断言：导入不碰任何断点快照（kv 里 learnResume_* 一模一样）', () async {
    final before = await _resumeKv();
    final v = await _validate(_csvTwoModules);
    await UserPackageStore(_p.database).importValidation(v, allowed: true);
    expect(await _resumeKv(), equals(before));
  });

  test('件 3：导入后立刻 reconcileAll —— 不新增红，也不把 user 行当孤儿', () async {
    final v = await _validate(_csvTwoModules);
    await UserPackageStore(_p.database).importValidation(v, allowed: true);
    final r = await ProgressIntegrity.reconcileAll(_p, _content, reason: 'test');
    final orphans = await ProgressIntegrity.orphans(_p, _content);
    expect(orphans.orphanKeys.where(isUserChunkKey), isEmpty,
        reason: 'user 行被当成孤儿 = 一键修复迟早会删掉用户自己的包');
    expect(r.remaining, 0, reason: '导入不该制造新的不一致');
  });

  test('同名模块重导 = 整包替换，改过的 front 不留孤儿行', () async {
    final store = UserPackageStore(_p.database);
    await store.importValidation(await _validate(_csvOneModule), allowed: true);
    expect(await store.userRowCount(), 1);

    final again = await _validate('front,back,module_name\n'
        '"boarding pass",登机牌,机场\n');
    final res = await store.importValidation(again, allowed: true);
    expect(res.ok, isTrue);
    expect(res.replacedPackages, 1);
    expect(await store.userRowCount(), 1);
    expect((await store.listPackages()).single.entries.single.front,
        'boarding pass');
  });

  test('重名冲突（跨包同 front）：校验器给行级报错，库一行都不写', () async {
    final store = UserPackageStore(_p.database);
    final v = await _validate('front,back,module_name\n'
        '"take off",起飞,机场\n'
        '"take off",脱下,穿衣\n');
    expect(v.ok, isFalse, reason: 'chunkKey 只由 front 决定，重复必须当场报');
    expect(v.issues.map((i) => i.reason), anyElement(contains('内容重复')));
    final res = await store.importValidation(v, allowed: true);
    expect(res.ok, isFalse);
    expect(await store.userRowCount(), 0);
    expect(await store.listPackages(), isEmpty);
  });

  test('名额闸在库层也兜一遍：第 6 本被拒且不写半截', () async {
    final store = UserPackageStore(_p.database);
    for (var i = 0; i < 5; i++) {
      final v = await _validate(
          'front,back,module_name\n"chunk $i",释义,模块$i\n');
      expect((await store.importValidation(v, allowed: true)).ok, isTrue);
    }
    final rowsBefore = await store.userRowCount();
    final v6 = await _validate('front,back,module_name\n"extra",多余,模块6\n');
    final res = await store.importValidation(v6, allowed: true);
    expect(res.ok, isFalse);
    expect(res.note, contains('先删掉一本再存'));
    expect(await store.userRowCount(), rowsBefore, reason: '被拒的导入不许留下任何行');
  });

  test('未过闸的表：一行都不写（超长行 / 坏引号 / 超 tags / 重名冲突）', () async {
    final store = UserPackageStore(_p.database);
    final longFront = 'x' * 200;
    final bad = await _validate('front,back,module_name\n'
        '$longFront,超长,坏表\n'
        '"unclosed,主菜,坏引号\n'
        '"fine",好,坏表,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10\n');
    expect(bad.ok, isFalse);
    final res = await store.importValidation(bad, allowed: true);
    expect(res.ok, isFalse);
    expect(await store.userRowCount(), 0);
    expect(await store.listPackages(), isEmpty);
  });

  test('删包：档案与块行同事务清掉，不留「档案说 2 块 / 台账 0 行」', () async {
    final store = UserPackageStore(_p.database);
    await store.importValidation(await _validate(_csvTwoModules), allowed: true);
    final pkgs = await store.listPackages();
    expect(pkgs, hasLength(2));
    final removed = await store.removePackage(pkgs.first.moduleKey);
    expect(removed, 1);
    expect(await store.userRowCount(), 1);
    expect((await store.listPackages()).map((r) => r.moduleKey),
        isNot(contains(pkgs.first.moduleKey)));
  });

  test('旧数据重置：台账清空时包档案一并清（不留脏注册表）', () async {
    final store = UserPackageStore(_p.database);
    await store.importValidation(await _validate(_csvTwoModules), allowed: true);
    await _p.database.resetChunks();
    expect(await store.userRowCount(), 0);
    expect(await store.listPackages(), isEmpty);
  });

  test('幂等：同一份表导两次，行数不翻倍', () async {
    final store = UserPackageStore(_p.database);
    final v = await _validate(_csvTwoModules);
    await store.importValidation(v, allowed: true);
    await store.importValidation(await _validate(_csvTwoModules), allowed: true);
    expect(await store.userRowCount(), 2);
    expect((await store.listPackages()).length, 2);
  });
}

class _OfficialSnapshot {
  final List<String> masteredKeys;
  final List<String> assetMasteredKeys;
  final List<ChunkRow> rows;
  final List<String> exportKeys;
  final List<String> dueKeys;
  final List<ChunkRow> topFail;
  final int masteredCount;
  final int assetMastered;
  final int assetTotal;
  final int dueCount;
  final int spoken;
  final double avgScore;
  final int? nextDue;
  final int? earliestDue;

  _OfficialSnapshot({
    required this.masteredKeys,
    required this.assetMasteredKeys,
    required this.rows,
    required this.exportKeys,
    required this.dueKeys,
    required this.topFail,
    required this.masteredCount,
    required this.assetMastered,
    required this.assetTotal,
    required this.dueCount,
    required this.spoken,
    required this.avgScore,
    required this.nextDue,
    required this.earliestDue,
  });
}

Future<_OfficialSnapshot> _officialSnapshot() async {
  final now = _p.now.millisecondsSinceEpoch;
  final s = _p.chunkStore;
  final export = await s.exportAssets();
  return _OfficialSnapshot(
    masteredKeys: await s.allMasteredKeys(),
    assetMasteredKeys: await s.allAssetMasteredKeys(),
    rows: await s.allRows(),
    exportKeys: [for (final r in export) '${r['chunk_key']}'],
    dueKeys: await s.dueChunkKeys(now),
    topFail: await s.topFail(20),
    masteredCount: (await s.allMasteredKeys()).length,
    assetMastered: await s.assetMasteredCount(),
    assetTotal: (await s.assetStateCounts()).values.fold<int>(0, (a, b) => a + b),
    dueCount: (await s.dueChunkKeys(now)).length,
    spoken: await s.spokenCount(),
    avgScore: await s.avgScore(),
    nextDue: await s.nextDueTimestamp(now),
    earliestDue: await s.earliestDueTimestamp(),
  );
}

Future<Map<String, String>> _resumeKv() async {
  final all = await _p.database.getAllKv();
  return {
    for (final e in all.entries)
      if (e.key.startsWith('learnResume_')) e.key: e.value,
  };
}

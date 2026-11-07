import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/data_channel.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/legacy_gate.dart';
import 'package:chunkspoke_flutter/services/license_state.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// ASR-233 · 备份通道三件钉测。
///
/// 一句话口径：**备份件只能带「学习数据 + 词表档案」，不能带身份，也不能带半截态。**
///  A3 档案随 kv 走、块行走官方口径被排除 → 合并完必须按档案补齐缺行（只补不覆盖）；
///  A5 授权键整段不进件、也不从件里写回（明文 JSON 谁都能导入，随件走=白送 PRO）；
///  A6 手改件里的自定义块行/会话一律忽略（自定义块只能由档案重建，否则绕过名额闸）。
/// 老用户身份走库外标记（D1），三件都不许碰它。
Level _level(String id, int count) => Level(
      id: id,
      theme: 'ASR-233 $id',
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

class _Rig {
  _Rig(this.p, this.content, this.gate, this.dir);
  final ProgressService p;
  final ContentPack content;
  final LegacyGate gate;
  final Directory dir;
  UserPackageStore get store => UserPackageStore(p.database);
}

Future<_Rig> _rig({bool legacy = false}) async {
  final dir = await Directory.systemTemp.createTemp('asr233_backup');
  final p = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
  await p.init();
  final d = await p.database.db;
  await d.delete('chunks');
  await d.delete('kv');
  await d.delete('sessions');
  final content = ContentPack(version: 'test', levels: [_level('M', 8)]);
  p.setChunkTiers(content);
  final gate = LegacyGate(supportDir: dir, dbExists: () async => true);
  if (legacy) await gate.adoptFromImport(kLegacyFlagYes);
  return _Rig(p, content, gate, dir);
}

const _csvTwoRows = 'front,back,module_name\n'
    '"a cup of coffee",一杯咖啡,点单\n'
    '"the bill, please",买单,点单\n';

Future<UserPackageValidation> _validate(String text) =>
    Future.value(parseAndValidateUserPackage(text));

/// 官方口径快照：备份往返前后必须逐字段相同（自定义块不许污染任何一个数）。
/// 断点里的 `savedAt` 是写盘墙钟，两台机器必然不同；比的是锚点/块号/阶段/星位。
Future<Map<String, Object?>> _official(_Rig r) async {
  final db = r.p.database;
  final now = DateTime.now().millisecondsSinceEpoch;
  final raw = await r.p.learnResumeFromDb('M');
  Map<String, dynamic>? resume;
  if (raw != null && raw.isNotEmpty) {
    resume = (jsonDecode(raw) as Map<String, dynamic>)..remove('savedAt');
  }
  return {
    'masteredKeys': (await db.allMasteredKeys()).join(','),
    'rows': (await db.allChunks()).length,
    'due': await db.countDueChunks(now),
    'assetCounts': (await db.assetStateCounts()).toString(),
    'assetMastered': await db.countAssetMastered(),
    'sessions': (await db.allSessionRows()).length,
    'resume': resume?.toString(),
  };
}

/// 模拟「已激活的机器」：授权键全落 kv（值随便，本测只看它走不走备份件）。
Future<void> _activate(_Rig r) async {
  for (final k in [
    kKvLicenseEdition,
    kKvLicenseNonce,
    kKvLicenseTag,
    kKvLicenseVerifyState,
    kKvLicenseActivatedAt,
    kKvLicenseTail,
    kKvLicenseSecretFp,
    kKvLicenseDeviceId,
  ]) {
    await r.p.database.setKv(k, 'PRO-TEST');
  }
}

/// 官方进度：前 3 块走完六步（与 D4 级联测同一套造数）。
Future<void> _study(_Rig r) async {
  final keys = r.content.levels.first.chunks.map((c) => c.id).toList();
  for (final k in keys.take(3)) {
    await r.p.chunkStore.applyEvent(k, ChunkEvent.assembleCorrect);
    await r.p.chunkStore.applyEvent(k, ChunkEvent.dragCorrect);
    await r.p.chunkStore.applyEvent(k, ChunkEvent.accuracyPass, accuracy: 92);
    await r.p.chunkStore.applyEvent(k, ChunkEvent.speakSuccess,
        accuracy: 95, fourStarsGreen: true, enforceFourStars: true);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ── A5：授权态不进件、不从件里写回 ────────────────────────────────────
  group('A5 授权态与备份件隔离', () {
    test('纯函数成形时就剔除授权键：件里搜不到 license.，条数以件里真有的为准', () {
      final map = buildChannelMap(
        kv: {
          'baseRate': '1.25',
          kKvLicenseEdition: 'PRO',
          kKvLicenseNonce: 'ABCDE',
          kKvLicenseTag: '0123456789',
          kKvLicenseDeviceId: 'dev-1',
          '${AppDatabase.kUserPkgKvPrefix}abc': '{"module_name":"点单"}',
        },
        chunks: const [],
        sessions: const [],
        legacyFlag: kLegacyFlagNo,
        now: DateTime(2026, 11, 7),
      );
      final text = jsonEncode(map);
      expect(text.contains('license.'), isFalse, reason: '授权键随件走 = 白送 PRO');
      expect((map['kv'] as Map).keys, ['baseRate', '${AppDatabase.kUserPkgKvPrefix}abc']);
      expect((map['counts'] as Map)['kv'], 2);
      expect(text.contains('userpkg.'), isTrue, reason: '词表档案必须带走，否则换机丢词表');
    });

    test('真库导出：已激活的机器导出的件里没有授权键，kvCount 不谎报', () async {
      final r = await _rig();
      await _activate(r);
      await r.p.database.setKv('baseRate', '1.25');
      await r.store.importValidation(await _validate(_csvTwoRows));

      final export = await buildChannelExport(db: r.p.database, gate: r.gate);
      expect(export.json.contains('license.'), isFalse);
      expect(export.kvCount, 2, reason: 'baseRate + 一份词表档案；8 个授权键已剔除');
      final kv = (jsonDecode(export.json) as Map)['kv'] as Map;
      expect(kv.containsKey('baseRate'), isTrue);
      expect(kv.keys.any((k) => k.toString().startsWith('userpkg.')), isTrue);
    });

    test('旧备份件带着授权键：预览如实报「已忽略」，合并后本机仍未激活', () async {
      final src = await _rig();
      await _activate(src);
      await src.p.database.setKv('baseRate', '1.25');
      final export = await buildChannelExport(db: src.p.database, gate: src.gate);
      // 手工造一份「ASR-233 之前」的件：把授权键塞回去。
      final old = jsonDecode(export.json) as Map<String, dynamic>;
      (old['kv'] as Map)[kKvLicenseEdition] = 'PRO';
      (old['kv'] as Map)[kKvLicenseVerifyState] = kVerifyOk;
      (old['kv'] as Map)[kKvLicenseActivatedAt] = '1700000000000';
      final text = jsonEncode(old);

      final dst = await _rig();
      final plan = await previewChannelImport(db: dst.p.database, text: text);
      expect(plan.ignoredLicenseKv, 3);
      expect(plan.newKv, 1, reason: '只有 baseRate 算新增，授权键不许混进这个数');

      final applied =
          await applyChannelImport(db: dst.p.database, gate: dst.gate, text: text);
      expect(applied.ignoredLicenseKv, 3);
      final kv = await dst.p.database.getAllKv();
      expect(kv.keys.where(isLicenseKv), isEmpty,
          reason: '导入一份别人的备份就等于激活，这是付费门的洞');
      expect(kv['baseRate'], '1.25');
    });

    test('D1 不受影响：老用户标记照旧带回，授权键剔除不许连坐身份', () async {
      final src = await _rig(legacy: true);
      await src.p.database.setKv('baseRate', '1.0');
      final export = await buildChannelExport(db: src.p.database, gate: src.gate);
      expect(export.legacyFlag, kLegacyFlagYes);

      final dst = await _rig();
      expect(await dst.gate.readRaw(), isNull);
      final applied = await applyChannelImport(
          db: dst.p.database, gate: dst.gate, text: export.json);
      expect(applied.adoptedLegacy, 1);
      expect(await dst.gate.readRaw(), kLegacyFlagYes);
    });

    test('排除判据单源：通道里不许自己写第二份 startsWith', () {
      final src = File('lib/services/data_channel.dart').readAsStringSync();
      expect(src.contains("startsWith('license.')"), isFalse);
      expect(src.contains('isLicenseKv('), isTrue);
      final lic = File('lib/services/license_state.dart').readAsStringSync();
      expect(lic.contains("const String kKvLicensePrefix = 'license.';"), isTrue);
      expect(lic.contains('bool isLicenseKv(String key)'), isTrue);
    });
  });

  // ── A3：换机往返只回来档案的半截态 ────────────────────────────────────
  group('A3 档案补行（换机 / 清数据往返）', () {
    test('导出→空机合并：档案与块行一起回来，自检一致，官方口径分毫不差', () async {
      final src = await _rig();
      await _study(src);
      await src.store.importValidation(await _validate(_csvTwoRows));
      await src.p.database.setKv('baseRate', '1.25');
      final before = await _official(src);
      expect(await src.store.userRowCount(), 2);

      final export = await buildChannelExport(db: src.p.database, gate: src.gate);
      // 件里只有档案、没有自定义块行（官方口径在库层就排除了）。
      final payload = jsonDecode(export.json) as Map<String, dynamic>;
      expect((payload['chunks'] as List).any((c) => c['chunk_key'].toString().startsWith('user:')),
          isFalse);

      final dst = await _rig();
      final applied = await applyChannelImport(
          db: dst.p.database,
          gate: dst.gate,
          text: export.json,
          store: dst.p.chunkStore);
      expect(applied.rebuiltUserRows, 2, reason: '不补行就是「档案有、台账无」的红');
      expect(applied.nothingToDo, isFalse);
      expect(await dst.store.userRowCount(), 2);
      final inv = await dst.store.inspect();
      expect(inv.consistent, isTrue, reason: jsonEncode(inv.toJson()));
      expect(inv.missingRows, 0);
      expect(inv.strayRows, 0);
      expect(await _official(dst), before, reason: '自定义块不许进任何官方数字');
      // 补回来的行按「未开始学习」记：不排期、不进到期队列。
      for (final row in await dst.p.database.allUserChunks()) {
        expect(row.dueDate, 0);
        expect(row.assetState, ChunkAssetState.learning);
      }
    });

    test('只补缺行：本机已有的行一字不动（进度更靠后也不许被档案盖掉）', () async {
      final r = await _rig();
      await r.store.importValidation(await _validate(_csvTwoRows));
      final rec = (await r.store.listPackages()).single;
      final first = rec.entries.first.chunkKey;
      // 本机把第一行推到更靠后的资产态，并删掉第二行（模拟半截态）。
      final d = await r.p.database.db;
      await d.update('chunks', {'asset_state': ChunkAssetState.consolidated.index},
          where: 'chunk_key = ?', whereArgs: [first]);
      await r.p.database.deleteChunksByKeys([rec.entries.last.chunkKey]);
      final inv0 = await r.store.inspect();
      expect(inv0.missingRows, 1);

      final added = await r.store.rebuildMissingRows();
      expect(added, 1);
      final rows = {
        for (final x in await r.p.database.allUserChunks()) x.chunkKey: x
      };
      expect(rows[first]!.assetState, ChunkAssetState.consolidated,
          reason: '补行不许覆盖既有进度');
      expect(rows[rec.entries.last.chunkKey]!.assetState, ChunkAssetState.learning);
      expect((await r.store.inspect()).consistent, isTrue);
      expect(await r.store.rebuildMissingRows(), 0, reason: '补齐后再跑必须是幂等的 0');
    });

    test('坏档案跳过：不凭猜测重建，红留给自检判', () async {
      final r = await _rig();
      await r.store.importValidation(await _validate(_csvTwoRows));
      await r.store.importValidation(await _validate(
          'front,back,module_name\n"central heating",集中供暖,家居\n'));
      final home = (await r.store.listPackages())
          .firstWhere((x) => x.moduleName == '家居');
      await r.p.database
          .setKv('${AppDatabase.kUserPkgKvPrefix}${home.moduleKey}', '{坏掉的档案');
      await r.p.database.deleteChunksByKeys([home.entries.first.chunkKey]);

      final added = await r.store.rebuildMissingRows();
      expect(added, 0, reason: '好包不缺行；坏包读不出来，不许猜内容重建');
      final inv = await r.store.inspect();
      expect(inv.corruptCount, 1);
      expect(inv.consistent, isFalse);
    });

    test('空库跑补行 = 0，不写任何东西', () async {
      final r = await _rig();
      expect(await r.store.rebuildMissingRows(), 0);
      expect(await r.store.userRowCount(), 0);
      expect((await r.store.inspect()).consistent, isTrue);
    });

    test('调用点钉死：合并通道与一键修复都必须补行（不许只写在注释里）', () {
      for (final f in [
        'lib/services/data_channel.dart',
        'lib/screens/diagnostics.dart',
      ]) {
        final code = File(f)
            .readAsStringSync()
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(code.contains('rebuildMissingRows()'), isTrue,
            reason: '$f 没接补行口，半截态会一路红到用户面前');
      }
    });
  });

  // ── A6：手改件里的自定义块行/会话 ─────────────────────────────────────
  group('A6 自定义块只由档案重建', () {
    test('件里塞 user: 块行与会话：如实报忽略，一行都不写、不留孤儿', () async {
      final src = await _rig();
      await _study(src);
      final export = await buildChannelExport(db: src.p.database, gate: src.gate);
      final before = await _official(src);

      final evil = jsonDecode(export.json) as Map<String, dynamic>;
      (evil['chunks'] as List).add({
        'chunk_key': 'user:deadbeef',
        'level': ChunkLevel.mastered.index,
        'due_date': 1,
        'asset_state': ChunkAssetState.mastered.index,
      });
      (evil['sessions'] as List).add({
        'chunk_key': 'user:deadbeef',
        'ts': 123,
        'outcome': 'speakSuccess',
        'score': 100,
        'review': 0,
      });
      final text = jsonEncode(evil);

      final dst = await _rig();
      final plan = await previewChannelImport(db: dst.p.database, text: text);
      expect(plan.ignoredUserChunks, 1);
      final applied = await applyChannelImport(
          db: dst.p.database,
          gate: dst.gate,
          text: text,
          store: dst.p.chunkStore);
      expect(applied.ignoredUserChunks, 1);
      expect(await dst.store.userRowCount(), 0, reason: '绕过名额闸写进来的行必须挡掉');
      expect((await dst.store.inspect()).strayRows, 0);
      expect(await _official(dst), before);
      expect((await dst.p.database.allSessionRows()).length, before['sessions']);
    });

    test('导出侧同样只带官方会话：自定义键不进件', () async {
      final r = await _rig();
      await r.p.database.insertSession('mc0', 'speakSuccess', 90, ts: 1000);
      await r.p.database.insertSession('user:deadbeef', 'speakSuccess', 90, ts: 1001);
      final export = await buildChannelExport(db: r.p.database, gate: r.gate);
      expect(export.sessionCount, 1);
      expect(export.json.contains('user:deadbeef'), isFalse);
    });
  });
}
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/services/data_channel.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/legacy_gate.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// ASR-233 深度自查 · 七处缺陷的钉死回归。
///
/// 每条对应一次实测发现的真问题（不是假路径）：
///  1 跨包同 front 撞名 -> 归属闸 + 安全删包 + 集合差对账；
///  2 字符白名单误拒重音拉丁/中日韩标点/emoji -> 改黑名单；
///  3 授权机器恢复备份原样写回档案 = 绕过校验器与名额闸 -> 消毒闸 + 通道接线；
///  5 导出头版本常量落后 pubspec -> 同源断言；
///  6 JSON 键大小写 / 数组 tags / CSV 空行行号；
///  7 导入两事务 -> 单事务 replaceChunksAndKv。
/// 第 4 处（反馈页文案）由 test/user_preview_screen_test.dart 钉死，不在此重复。

/// 干净空库：AppDatabase 开库即建表，无需手动清。
Future<AppDatabase> _freshDb() async {
  final dir = await Directory.systemTemp.createTemp('asr233_audit');
  return AppDatabase(path: '${dir.path}/t.db');
}

UserPackageValidation _v(String text) => parseAndValidateUserPackage(text);

String _csv(String front, String module) =>
    'front,back,module_name\n$front,释义,$module\n';

/// 造一份合法档案 JSON（与导入落库同 schema），键名用规范小写。
String _archive(String module, List<String> fronts, {int importedAt = 1}) {
  final mk = userModuleKey(module);
  return jsonEncode({
    'module_key': mk,
    'module_name': module,
    'imported_at': importedAt,
    'entries': [
      for (final f in fronts)
        {'front': f, 'back': '释义', 'module_name': module},
    ],
  });
}

String _kvKey(String module) =>
    '${AppDatabase.kUserPkgKvPrefix}${userModuleKey(module)}';

Map<String, dynamic> _decode(String archive) =>
    jsonDecode(archive) as Map<String, dynamic>;

Future<ChannelImportPlan> _restore(
  AppDatabase db,
  Map<String, String> kv, {
  required bool allowed,
  bool apply = false,
}) async {
  final text = jsonEncode(buildChannelMap(
    kv: kv,
    chunks: const [],
    sessions: const [],
    legacyFlag: kLegacyFlagNo,
    now: DateTime(2026, 11, 8),
  ));
  if (!apply) {
    return previewChannelImport(db: db, text: text, allowUserPackages: allowed);
  }
  final dir = await Directory.systemTemp.createTemp('asr233_audit_gate');
  final gate = LegacyGate(supportDir: dir, dbExists: () async => true);
  return applyChannelImport(
      db: db, gate: gate, text: text, allowUserPackages: allowed);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // 缺陷 2：字符校验改黑名单（误拒正常内容）。
  group('缺陷2 字符黑名单', () {
    for (final good in [
      'café',
      'résumé',
      'naïve',
      '你好，世界！',
      '「词块」（测试）；…—',
      'coffee ☕',
      '扩展汉字𠀀',
    ]) {
      test('放行正常内容：$good', () {
        final v = _v(_csv(good, '我的词表'));
        expect(v.ok, isTrue, reason: v.issues.join(' / '));
        expect(v.entries.single.front, good);
      });
    }
    // 危险字符用 fromCharCode 构造，避免源码里出现裸控制符。
    // 不用 BOM 做用例：解析器会 replaceFirst 抹掉第一个 BOM，到不了字段闸。
    final bad = <int>[0x00, 0x200b, 0x202e, 0x7f, 0x2066];
    for (final code in bad) {
      test('拒收危险字符 U+${code.toRadixString(16)}', () {
        final v = _v(_csv('word${String.fromCharCode(code)}tail', '我的词表'));
        expect(v.ok, isFalse);
        expect(v.issues.map((e) => e.reason),
            anyElement(contains('控制符或不可见字符')));
      });
    }
  });

  // 缺陷 6：JSON 键大小写 / 数组 tags / CSV 空行行号。
  group('缺陷6 解析归一', () {
    test('JSON 大写键 Front/Back/Module_Name 正常取值', () {
      final v = _v(jsonEncode([
        {'Front': 'plate', 'Back': '盘子', 'Module_Name': '餐饮'},
      ]));
      expect(v.ok, isTrue, reason: v.issues.join(' / '));
      expect(v.entries.single.front, 'plate');
      expect(v.entries.single.back, '盘子');
      expect(v.entries.single.moduleName, '餐饮');
    });

    test('JSON 数组 tags 切成干净标签（不带方括号）', () {
      final v = _v(jsonEncode([
        {
          'front': 'plate',
          'back': '盘子',
          'module_name': '餐饮',
          'tags': ['常用', '口语'],
        },
      ]));
      expect(v.ok, isTrue, reason: v.issues.join(' / '));
      expect(v.entries.single.tags, ['常用', '口语']);
    });

    test('CSV 中间空行：报错指到文件真实行号', () {
      final v = _v('front,back,module_name\nplate,盘子,餐饮\n\n,缺正面,餐饮\n');
      expect(v.ok, isFalse);
      expect(v.issues.any((e) => e.row == 4 && e.field == 'front'), isTrue,
          reason: v.issues.join(' / '));
    });
  });

  // 缺陷 1：跨包同 front 撞名 -> 归属闸 + 安全删包 + 集合差对账。
  group('缺陷1 撞名归属与安全删包', () {
    test('跨包同 front：归属闸挡住，原包完好、自检一致', () async {
      final db = await _freshDb();
      final store = UserPackageStore(db);
      expect(
          (await store.importValidation(_v(_csv('shared word', '甲包')),
                  allowed: true))
              .ok,
          isTrue);
      final res = await store.importValidation(
          _v(_csv('shared word', '乙包')),
          allowed: true);
      expect(res.ok, isFalse);
      expect(res.note, contains('甲包'));
      expect(await store.userRowCount(), 1);
      final pkgs = await store.listPackages();
      expect(pkgs.length, 1);
      expect(pkgs.single.moduleName, '甲包');
      expect((await store.inspect()).consistent, isTrue);
    });

    test('同名模块重导：整包替换，改过的 front 不留孤儿', () async {
      final db = await _freshDb();
      final store = UserPackageStore(db);
      await store.importValidation(_v(_csv('old front', '甲包')), allowed: true);
      final res = await store.importValidation(
          _v(_csv('new front', '甲包')),
          allowed: true);
      expect(res.ok, isTrue);
      expect(res.replacedPackages, 1);
      expect(await store.userRowCount(), 1);
      expect((await store.inspect()).strayRows, 0);
      expect((await store.listPackages()).single.entries.single.front,
          'new front');
    });

    test('删包只删独占行：共享行留给仍声明它的包', () async {
      final db = await _freshDb();
      final store = UserPackageStore(db);
      // 手造历史撞名：两份档案都声明同一 front（旧数据/手改库绕过归属闸）。
      await db.setKv(_kvKey('甲包'), _archive('甲包', ['shared word']));
      await db.setKv(_kvKey('乙包'), _archive('乙包', ['shared word', 'only b']));
      await store.rebuildMissingRows();
      expect(await store.userRowCount(), 2);
      final removedA = await store.removePackage(userModuleKey('甲包'));
      expect(removedA, 0, reason: 'shared 仍被乙包声明，不许删');
      expect(await store.userRowCount(), 2);
      final invAfterA = await store.inspect();
      expect(invAfterA.consistent, isTrue, reason: jsonEncode(invAfterA.toJson()));
      final removedB = await store.removePackage(userModuleKey('乙包'));
      expect(removedB, 2);
      expect(await store.userRowCount(), 0);
    });

    test('对账用集合差：一边缺一边多不许互相抵消', () async {
      final db = await _freshDb();
      final store = UserPackageStore(db);
      await store.importValidation(
          _v('front,back,module_name\nalpha,释,甲\nbeta,释,甲\n'),
          allowed: true);
      await db.deleteChunksByKeys(['user:${sha8Of('beta')}']);
      await db.upsertChunksAndKv([
        const ChunkRow(
            chunkKey: 'user:orphan01',
            level: ChunkLevel.l1,
            dueDate: 0,
            failCount: 0,
            lastScore: 0),
      ], const {});
      final inv = await store.inspect();
      expect(inv.declaredChunks, 2);
      expect(inv.userRowCount, 2);
      expect(inv.missingRows, 1);
      expect(inv.strayRows, 1);
      expect(inv.consistent, isFalse, reason: '算术差会判一致，集合差必须判红');
    });
  });

  // 缺陷 3：备份恢复消毒闸（adoptUserArchives + 通道接线）。
  group('缺陷3 备份恢复消毒闸', () {
    test('名额闸：7 份新档案只收 5、拒 2', () async {
      final store = UserPackageStore(await _freshDb());
      final incoming = <String, String>{
        for (var i = 0; i < 7; i++) _kvKey('包$i'): _archive('包$i', ['front $i']),
      };
      final adoption = await store.adoptUserArchives(incoming);
      expect(adoption.accepted.length, 5);
      expect(adoption.skippedArchives, 2);
      expect(adoption.skippedEntries, 0);
    });

    test('单包超 200：整份拒收', () async {
      final store = UserPackageStore(await _freshDb());
      final big = _archive('大包', [for (var i = 0; i < 201; i++) 'w$i']);
      final adoption = await store.adoptUserArchives({_kvKey('大包'): big});
      expect(adoption.accepted, isEmpty);
      expect(adoption.skippedArchives, 1);
    });

    test('脏条目：整份仍收，坏条目如实剔除计数', () async {
      final store = UserPackageStore(await _freshDb());
      final m = _decode(_archive('mixed', ['good one']));
      (m['entries'] as List).add({
        'front': 'bad${String.fromCharCode(0x200b)}',
        'back': '释',
        'module_name': 'mixed',
      });
      final adoption =
          await store.adoptUserArchives({_kvKey('mixed'): jsonEncode(m)});
      expect(adoption.accepted.length, 1);
      expect(adoption.skippedArchives, 0);
      expect(adoption.skippedEntries, 1);
      final rec =
          UserPackageRecord.fromJson(_decode(adoption.accepted.values.single));
      expect(rec.entries.length, 1);
      expect(rec.entries.single.front, 'good one');
    });

    test('档案间撞名：后一份整份拒收', () async {
      final store = UserPackageStore(await _freshDb());
      final adoption = await store.adoptUserArchives({
        _kvKey('甲'): _archive('甲', ['same front']),
        _kvKey('乙'): _archive('乙', ['same front']),
      });
      expect(adoption.accepted.length, 1);
      expect(adoption.skippedArchives, 1);
    });

    test('与本机既有包撞名：整份拒收', () async {
      final db = await _freshDb();
      final store = UserPackageStore(db);
      await store.importValidation(_v(_csv('taken front', '本机包')),
          allowed: true);
      final adoption = await store
          .adoptUserArchives({_kvKey('外来包'): _archive('外来包', ['taken front'])});
      expect(adoption.accepted, isEmpty);
      expect(adoption.skippedArchives, 1);
    });

    test('kv 后缀与模块键不自洽：拒收', () async {
      final store = UserPackageStore(await _freshDb());
      final adoption =
          await store.adoptUserArchives({_kvKey('乙'): _archive('甲', ['w'])});
      expect(adoption.accepted, isEmpty);
      expect(adoption.skippedArchives, 1);
    });

    test('licensed 合法恢复：档案与补行一起回来，自检一致', () async {
      final db = await _freshDb();
      final plan = await _restore(
          db, {_kvKey('点单'): _archive('点单', ['a cup of coffee'])},
          allowed: true, apply: true);
      expect(plan.skippedUserArchives, 0);
      expect(plan.rebuiltUserRows, 1);
      final store = UserPackageStore(db);
      expect(await store.userRowCount(), 1);
      expect((await store.inspect()).consistent, isTrue);
    });

    test('licensed 手改 7 包件：只落 5 包，自检仍一致', () async {
      final db = await _freshDb();
      final kv = <String, String>{
        for (var i = 0; i < 7; i++) _kvKey('包$i'): _archive('包$i', ['f$i']),
      };
      final plan = await _restore(db, kv, allowed: true, apply: true);
      expect(plan.skippedUserArchives, 2);
      final store = UserPackageStore(db);
      expect((await store.listPackages()).length, 5);
      expect(await store.userRowCount(), 5);
      expect((await store.inspect()).consistent, isTrue);
    });

    test('未授权机器：档案整段忽略，零写入零补行', () async {
      final db = await _freshDb();
      final plan = await _restore(
          db, {_kvKey('点单'): _archive('点单', ['w']), 'baseRate': '1.25'},
          allowed: false, apply: true);
      expect(plan.ignoredUserArchives, 1);
      expect(plan.acceptedUserArchives, isEmpty);
      expect(plan.newKv, 1);
      final store = UserPackageStore(db);
      expect(await store.userRowCount(), 0);
      expect(await store.listPackages(), isEmpty);
      final kv = await db.getAllKv();
      expect(kv.keys.any((k) => k.startsWith(AppDatabase.kUserPkgKvPrefix)),
          isFalse);
      expect(kv['baseRate'], '1.25');
    });
  });

  // 缺陷 5：导出头版本常量与 pubspec 同源（bump 安全）。
  group('缺陷5 版本同源', () {
    test('kChannelAppVersion == pubspec 的 x.y.z', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec 没有 version 行');
      expect(kChannelAppVersion, m!.group(1));
    });
  });

  // 缺陷 7：单事务落盘（静态钉，防回退到两事务）。
  group('缺陷7 单事务落盘', () {
    test('store 用 replaceChunksAndKv，且不再调 deleteChunksByKeys', () {
      final src =
          File('lib/services/user_package_store.dart').readAsStringSync();
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('replaceChunksAndKv('), isTrue);
      expect(code.contains('deleteChunksByKeys('), isFalse,
          reason: '两事务删行会留半截态');
    });
  });
}
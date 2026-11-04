import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/legacy_gate.dart';
import 'package:chunkspoke_flutter/services/license_code.dart';
import 'package:chunkspoke_flutter/services/license_gate.dart';
import 'package:chunkspoke_flutter/services/license_state.dart';

/// 1.6.0（LIC-1）· license 设施四组固定回归 + 基础用例。
///
/// 真源纪律：码规格与运营侧 `运营/unlock-ops/cs_codes.py` **逐字符同源**；
/// 本文件里的两枚字面量码就是该脚本 `--test` 生成、并已用 `verify --test`
/// 回验过的向量（fp=88f56da5）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const testSecret = 'chunkspoke-test-secret-do-not-ship-0000';
  const pyCodeA = 'CSPRO653D5J7TCP85T0C'; // nonce 653D5
  const pyCodeB = 'CSPRO1GC36C00EKMAHEJ'; // nonce 1GC36

  group('A 基础用例：解析与归一化', () {
    test('A1 长度 19 判 length', () {
      final r = parseLicenseCode(pyCodeA.substring(0, 19));
      expect(r.ok, isFalse);
      expect(r.error, LicenseError.length);
      expect(r.detail, '19');
    });

    test('A2 长度 21 判 length', () {
      final r = parseLicenseCode('${pyCodeA}0');
      expect(r.ok, isFalse);
      expect(r.error, LicenseError.length);
      expect(r.detail, '21');
    });

    test('A3 空格/横线直接粘也能过（不要求用户手删）', () {
      const messy = ' cspro-653d5-j7tc-p85t0c ';
      expect(cleanLicenseCode(messy), pyCodeA);
      expect(parseLicenseCode(messy).ok, isTrue);
      expect(verifyLicenseCode(messy, const [testSecret]).ok, isTrue);
    });

    test('A4 字表外字符 U 判 charSet', () {
      final r = parseLicenseCode('CSPRO653D5J7TCP85T0U');
      expect(r.ok, isFalse);
      expect(r.error, LicenseError.charSet);
      expect(r.detail, contains('U'));
    });

    test('A5 手敲易混字符按分段规则收下（tag 段 O→0、I/L→1）', () {
      // 把 tag 里的 0 写成 O：归一后必须和原码同 tag
      final withO = pyCodeA.replaceRange(18, 19, 'O');
      expect(withO, 'CSPRO653D5J7TCP85TOC');
      final r = verifyLicenseCode(withO, const [testSecret]);
      expect(r.ok, isTrue);
      expect(r.code!.tag, 'J7TCP85T0C');
      // nonce 段的 I 归一成 1
      expect(canonLicenseAlnum('I23L4'), '12314');
    });

    test('A6 前缀不是 CS 判 prefix', () {
      final r = parseLicenseCode('XSPRO653D5J7TCP85T0C');
      expect(r.ok, isFalse);
      expect(r.error, LicenseError.prefix);
      expect(r.detail, 'XS');
    });
  });

  group('T-A 档位等价类：手敲 PR0 / PRo / pro 都归一成 PRO', () {
    test('editionEquivalence_acceptsObfuscatedPro', () {
      const variants = [
        'CSPR0653D5J7TCP85T0C',
        'CSPRo653d5j7tcp85t0c',
        'cspro653d5j7tcp85t0c',
      ];
      for (final v in variants) {
        final r = verifyLicenseCode(v, const [testSecret]);
        expect(r.ok, isTrue, reason: v);
        expect(r.code!.edition, kEditionPro, reason: v);
        // 归一后永远是 PRO，**不许把 PR0 落盘**（T-C 的前半）
        expect(r.code!.canonical, startsWith('CSPRO'));
      }
    });
  });

  group('T-B 档位比对不能宽容过头', () {
    test('editionRejectsStructurallyValidButIllegalEdition', () {
      // 结构合法（20 字符、全字表内、CS 开头），但档位 PXY 不在白名单
      final r = parseLicenseCode('CSPXY6K3M9QW4RT7V2BX');
      expect(r.ok, isFalse);
      expect(r.error, LicenseError.edition);
      expect(r.detail, 'PXY');
      expect(matchEdition('TR1AL'), kEditionTrial);
      expect(matchEdition('BETA'), kEditionBeta);
      expect(matchEdition('PR0'), kEditionPro);
      expect(matchEdition('PRX'), isNull);
    });
  });

  group('HMAC 校验', () {
    test('测试 secret 对上运营脚本的两枚向量（Dart⇄Python 同码）', () {
      expect(licenseTagFor(testSecret, kEditionPro, '653D5'), 'J7TCP85T0C');
      expect('CSPRO653D5${licenseTagFor(testSecret, kEditionPro, '653D5')}',
          pyCodeA);
      expect('CSPRO1GC36${licenseTagFor(testSecret, kEditionPro, '1GC36')}',
          pyCodeB);
      expect(licenseSecretFp(testSecret), '88f56da5');
    });

    test('一位 tag 错就拒绝（不许「差不多就放行」）', () {
      final broken = pyCodeA.replaceRange(19, 20, '1');
      expect(broken, isNot(pyCodeA));
      final r = verifyLicenseCode(broken, const [testSecret]);
      expect(r.ok, isFalse);
      expect(r.error, LicenseError.tag);
    });

    test('双 secret：旧码在轮换期继续可验，指纹指向命中的那把', () {
      const prev = 'previous-secret-0123456789abcdef0123';
      final oldCode =
          'CSPRO9H4ZQ${licenseTagFor(prev, kEditionPro, '9H4ZQ')}';
      expect(verifyLicenseCode(oldCode, const [testSecret]).ok, isFalse);
      final r = verifyLicenseCode(oldCode, const [testSecret, prev]);
      expect(r.ok, isTrue);
      expect(r.secretFp, licenseSecretFp(prev));
      expect(r.secretFp, isNot('88f56da5'));
    });

    test('没有任何 secret：拒绝并给出「请用正式安装包」', () {
      final r = verifyLicenseCode(pyCodeA, const []);
      expect(r.ok, isFalse);
      expect(r.error, LicenseError.tag);
      expect(r.detail, 'no-secret');
      expect(licenseErrorMessage(r.error, r.detail), contains('没有内置校验钥匙'));
    });

    test('timingSafeEquals 不短路（长度不同/首字节不同都判 false）', () {
      expect(timingSafeEquals('abc', 'abc'), isTrue);
      expect(timingSafeEquals('abc', 'abd'), isFalse);
      expect(timingSafeEquals('abc', 'ab'), isFalse); // 长度不同也不抛
      expect(timingSafeEquals('', ''), isTrue);
    });
  });

  group('T-D 出码不变式：码是 nonce 的纯函数', () {
    test('同一 nonce 永远出同一枚码 → 账本必须按 nonce 去重', () {
      final a = 'CSPRO653D5${licenseTagFor(testSecret, kEditionPro, '653D5')}';
      final b = 'CSPRO653D5${licenseTagFor(testSecret, kEditionPro, '653D5')}';
      expect(a, b);
      // 两条账本行用同一 nonce = 重复收款，脚本里必须判红（COMM-OPS-2）
      final ledger = <String, String>{};
      ledger['653D5'] = a;
      ledger['653D5'] = b;
      expect(ledger.length, 1);
    });

    test('批内 100 码：码尾两两唯一、nonce 各出现一次', () {
      // 100 个互不相同的 5 字符 nonce（基底 32 的枚举，确定性可复现）
      String nonceAt(int i) {
        var v = i;
        final chars = <String>[];
        for (var k = 0; k < 5; k++) {
          chars.add(kCrockfordAlphabet[v % 32]);
          v ~/= 32;
        }
        return chars.reversed.join();
      }

      final nonces = [for (var i = 0; i < 100; i++) nonceAt(i)];
      final codes = [
        for (final n in nonces)
          'CSPRO$n${licenseTagFor(testSecret, kEditionPro, n)}'
      ];
      final tails = [for (final c in codes) c.substring(c.length - 5)];
      expect(nonces.toSet().length, 100);
      expect(codes.toSet().length, 100);
      expect(tails.toSet().length, 100);
    });
  });

  group('T-C LicenseState 落盘与判据', () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase(path: inMemoryDatabasePath);
      await db.db;
    });

    tearDown(() async {
      await (await db.db).close();
    });

    test('licenseStatePersistsCanonicalEditionAndFlagIsQueryable', () async {
      final lic = LicenseState(
        db: db,
        legacyEligible: false,
        secrets: const [testSecret],
      );
      await lic.load();
      expect(lic.hasLicense, isFalse);
      // ASR-208 §一.4：免费区 = 生存 S0 + A–F，边界按 kFreeLevelCount 走，不写死索引。
      expect(lic.allowsLevel(kFreeLevelCount - 1), isTrue, reason: '免费区内恒可学');
      expect(lic.allowsLevel(kFreeLevelCount), isFalse, reason: '边界起（G 关）要码');
      expect(lic.allows(LicenseFeature.speechAssessment), isTrue);
      expect(lic.allows(LicenseFeature.studyCalendar), isTrue);
      expect(lic.allows(LicenseFeature.dataBackup), isTrue);
      expect(lic.allows(LicenseFeature.oralDiary), isFalse);

      // 用 PR0 形态激活：落盘必须是 canonical PRO
      final r = await lic.activate('cspr0-653d5-j7tc-p85t0c',
          whitelist: WhitelistLookup.active);
      expect(r.ok, isTrue);
      expect(await db.getKv(kKvLicenseEdition), kEditionPro);
      expect(await db.getKv(kKvLicenseNonce), '653D5');
      expect(await db.getKv(kKvLicenseVerifyState), kVerifyOk);
      expect(await db.getKv(kKvLicenseSecretFp), '88f56da5');
      expect(lic.isPro, isTrue);
      expect(lic.allowsLevel(kFreeLevelCount), isTrue, reason: 'PRO 解锁免费边界之外');
      expect(lic.tail, '5T0C');

      // 重启后判据仍可查询（同一把 db）
      final again = LicenseState(
          db: db, legacyEligible: false, secrets: const [testSecret]);
      await again.load();
      expect(again.isPro, isTrue);
      expect(again.deviceId, lic.deviceId, reason: '设备编号只生成一次');
      expect(again.deviceId.length, 16);
    });

    test('老用户身份：无码也全量（legacy=1）', () async {
      final lic = LicenseState(db: db, legacyEligible: true);
      await lic.load();
      expect(lic.hasLicense, isFalse);
      expect(lic.hasFullAccess, isTrue);
      expect(lic.allowsLevel(19), isTrue);
      expect(lic.allows(LicenseFeature.oralDiary), isTrue);
    });
  });

  group('T-G 白名单三态（DDS §31.4）', () {
    late AppDatabase db;
    late LicenseState lic;

    setUp(() async {
      db = AppDatabase(path: inMemoryDatabasePath);
      await db.db;
      lic = LicenseState(
          db: db, legacyEligible: false, secrets: const [testSecret]);
      await lic.load();
      final r = await lic.activate(pyCodeA, whitelist: WhitelistLookup.active);
      expect(r.ok, isTrue);
    });

    tearDown(() async {
      await (await db.db).close();
    });

    test('active → ok；revoked → 锁；absent → 宽限不锁；unavailable → 不动', () async {
      await lic.applyWhitelist(WhitelistLookup.revoked);
      expect(lic.verifyState, kVerifyRejected);
      expect(lic.isPro, isFalse);
      expect(lic.allowsLevel(kFreeLevelCount), isFalse);
      expect(await db.getKv(kKvLicenseVerifyState), kVerifyRejected);

      await lic.applyWhitelist(WhitelistLookup.absent);
      expect(lic.verifyState, kVerifyUnverified);
      expect(lic.isPro, isTrue, reason: '清单消失属于第 2 态：宽限');

      await lic.applyWhitelist(WhitelistLookup.unavailable);
      expect(lic.verifyState, kVerifyUnverified, reason: '断网不改变本地状态');

      await lic.applyWhitelist(WhitelistLookup.active);
      expect(lic.verifyState, kVerifyOk);

      // 快照层同口径
      final snap = parseCodesJson(
          '{"version":1,"codes":[{"nonce":"653D5","status":"active"},'
          '{"nonce":"ZZZZZ","status":"revoked"}]}',
          source: 'test');
      expect(snap!.lookup('653D5'), WhitelistLookup.active);
      expect(snap.lookup('ZZZZZ'), WhitelistLookup.revoked);
      expect(snap.lookup('AAAAA'), WhitelistLookup.absent);
      expect(snap.size, 2);
    });

    test('吊销 / 未登记的码在激活口就被挡住', () async {
      final revoked =
          await lic.activate(pyCodeA, whitelist: WhitelistLookup.revoked);
      expect(revoked.ok, isFalse);
      expect(revoked.message, contains('已被停用'));
      final absent =
          await lic.activate(pyCodeA, whitelist: WhitelistLookup.absent);
      expect(absent.ok, isFalse);
      expect(absent.message, contains('不在发行清单'));
    });

    test('断网激活 → unverified（放行但标注）', () async {
      final lic2 = LicenseState(
          db: db, legacyEligible: false, secrets: const [testSecret]);
      await lic2.load();
      final r =
          await lic2.activate(pyCodeB, whitelist: WhitelistLookup.unavailable);
      expect(r.ok, isTrue);
      expect(r.verifyState, kVerifyUnverified);
      expect(lic2.verifyState, kVerifyUnverified);
      expect(lic2.isPro, isTrue);
    });
  });

  group('LicenseGate 拉取三态', () {
    test('主源 404 → 换备源；两源都坏 → null（不锁）', () async {
      final ok = LicenseGate(
        client: MockClient((req) async {
          if (req.url.host.contains('jsdelivr')) {
            return http.Response('not found', 404);
          }
          return http.Response(
              '{"version":1,"codes":[{"nonce":"653D5","status":"active"}]}',
              200);
        }),
        sources: const ['https://cdn.jsdelivr.net/x', 'https://raw/x'],
      );
      final snap = await ok.fetch();
      expect(snap, isNotNull);
      expect(snap!.lookup('653D5'), WhitelistLookup.active);
      expect(snap.source, 'https://raw/x');

      final bad = LicenseGate(
        client: MockClient((req) async => http.Response('{"oops":1}', 200)),
        sources: const ['https://a/x', 'https://b/x'],
      );
      expect(await bad.fetch(), isNull);
      expect(await bad.lookup('653D5'), WhitelistLookup.unavailable);
    });
  });

  group('T-E/T-F D1 判据在开库之前', () {
    late Directory support;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('cs_lic_gate_');
    });

    tearDown(() async {
      if (await support.exists()) await support.delete(recursive: true);
    });

    test('bootstrapJudgesExistenceBeforeOpenDatabase', () async {
      var probes = 0;
      final gate = LegacyGate(
        supportDir: support,
        dbExists: () async {
          probes++;
          // 真判据：此刻磁盘上有没有库文件
          return File('${support.path}/chunkspoke.db').existsSync();
        },
      );
      expect(await gate.bootstrap(), kLegacyFlagNo);
      expect(probes, 1);
      // 判完不许顺手建库（建了下一台设备也会被判成老用户）
      final names =
          support.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(names, {'legacy.flag'});
      expect(await gate.bootstrap(), kLegacyFlagNo);
      expect(probes, 1, reason: '有值就不再探库');
    });

    test('importLegacyFlagBeforeOpenRestoresLegacyIdentity', () async {
      final gate = LegacyGate(
        supportDir: support,
        dbExists: () async => false,
      );
      expect(await gate.bootstrap(), kLegacyFlagNo);
      // 判据已经写 0 之后，导入带 legacy=1 的备份：身份必须能改回来
      expect(await gate.adoptFromImport(kLegacyFlagYes), isTrue);
      expect(await gate.readRaw(), kLegacyFlagYes);
      expect(LegacyGate.isLegacy(await gate.readRaw()), isTrue);

      final db = AppDatabase(path: inMemoryDatabasePath);
      await db.db;
      final lic = LicenseState(
        db: db,
        legacyEligible: LegacyGate.isLegacy(await gate.readRaw()),
      );
      await lic.load();
      expect(lic.hasFullAccess, isTrue);
      expect(lic.allowsLevel(kFreeLevelCount), isTrue);
      await (await db.db).close();
    });
  });
}

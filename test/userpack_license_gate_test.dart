import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/screens/license_activate.dart';
import 'package:chunkspoke_flutter/screens/user_import_screen.dart';
import 'package:chunkspoke_flutter/services/data_channel.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/legacy_gate.dart';
import 'package:chunkspoke_flutter/services/license_code.dart';
import 'package:chunkspoke_flutter/services/license_state.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_files.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';

/// ASR-233 · 自定义导入付费门（裁定：甲 + 读删免费 + 不收档案 + 测试 secret + 同代首发）。
///
/// 一句话口径：**解析与预览永久免费；「确认导入」要解锁码。**
/// 免费三块写死在判据里，不许被这道门顺带锁掉：官方 167 块 / 三项输出 / 数据备份；
/// 已在本机的包读删永久免费（门关闭只挡新增与整包替换）。
/// 这里的六组钉测就是规划 §八 的 T-B1..T-B6。
const _proCode = 'cspr0-653d5-j7tc-p85t0c';

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

const _csvTwoRows = 'front,back,module_name\n'
    '"a cup of coffee",一杯咖啡,点单\n'
    '"the bill, please",买单,点单\n';

Future<UserPackageValidation> _validate(String text) =>
    Future.value(parseAndValidateUserPackage(text));

Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int tries = 150}) async {
  for (var i = 0; i < tries; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('等待超时：$finder');
}

/// 去注释后的源码：静态闸只看代码，不能被文档注释里的 API 名字误伤。
String _code(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

class _Rig {
  _Rig(this.p, this.gate, this.dir);
  final ProgressService p;
  final LegacyGate gate;
  final Directory dir;
  UserPackageStore get store => UserPackageStore(p.database);
}

Future<_Rig> _rig() async {
  final dir = await Directory.systemTemp.createTemp('asr233_gate');
  final p = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
  await p.init();
  p.setChunkTiers(ContentPack(version: 'test', levels: [_level('M', 8)]));
  final gate = LegacyGate(supportDir: dir, dbExists: () async => true);
  return _Rig(p, gate, dir);
}

/// 官方口径快照：门开/门关/删包前后必须逐项相同（付费门不许碰官方进度）。
Future<Map<String, Object?>> _official(_Rig r) async {
  final db = r.p.database;
  return {
    'mastered': (await r.p.chunkStore.allMasteredKeys()).join(','),
    'rows': (await db.allChunks()).length,
    'due': await db.countDueChunks(DateTime.now().millisecondsSinceEpoch),
    'assetCounts': (await db.assetStateCounts()).toString(),
  };
}

/// T-B1 的档位探针。
Future<bool> _gateAllows({
  String? edition,
  String verify = kVerifyOk,
  bool legacy = false,
  bool activatePro = false,
}) async {
  final db = AppDatabase(path: inMemoryDatabasePath);
  await db.db;
  try {
    if (edition != null) {
      await db.setKv(kKvLicenseEdition, edition);
      await db.setKv(kKvLicenseVerifyState, verify);
    }
    final lic = LicenseState(
      db: db,
      legacyEligible: legacy,
      secrets: const [kBuiltinTestSecret],
    );
    await lic.load();
    if (activatePro) {
      final r = await lic.activate(_proCode, whitelist: WhitelistLookup.active);
      expect(r.ok, isTrue, reason: r.message);
    }
    return lic.allows(LicenseFeature.customImport);
  } finally {
    await (await db.db).close();
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ── T-B1 档位矩阵 ─────────────────────────────────────────────────────
  test('T-B1 档位矩阵：PRO/老用户放行；未激活、TRIAL、BETA、吊销一律锁', () async {
    expect(await _gateAllows(), isFalse, reason: '未激活机器不能白拿');
    expect(await _gateAllows(activatePro: true), isTrue, reason: 'PRO 必须放行');
    expect(await _gateAllows(legacy: true), isTrue, reason: '老用户终身全量');
    expect(await _gateAllows(edition: kEditionTrial), isFalse,
        reason: 'TRIAL 在 1.6.0 只解析不放行');
    expect(await _gateAllows(edition: kEditionBeta), isFalse,
        reason: 'BETA 只解析不放行');
    expect(await _gateAllows(edition: kEditionPro, verify: kVerifyRejected),
        isFalse, reason: '吊销的 PRO 等于没激活');
    expect(await _gateAllows(edition: kEditionPro, verify: kVerifyUnverified),
        isTrue, reason: '断网宽限态（unverified）仍按本地 PRO 放行');
  });

  // ── T-B2 UI 墙：确认导入这一刻拦，零写入 ───────────────────────────────
  group('T-B2 导入器墙 sheet', () {
    late Directory tmp;
    late ProgressService progress;
    late ContentPack content;
    late LicenseState license;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('asr233_gate_ui');
      progress = ProgressService(db: AppDatabase(path: '${tmp.path}/t.db'));
      await progress.init();
      content = ContentPack(version: 'test', levels: [_level('A', 12)]);
      license = LicenseState(
        db: progress.database,
        legacyEligible: false,
        secrets: const [kBuiltinTestSecret],
      );
      await license.load();
    });

    Widget app() => MultiProvider(
          providers: [
            Provider<ProgressService>.value(value: progress),
            Provider<ContentPack>.value(value: content),
            ChangeNotifierProvider<LicenseState>.value(value: license),
          ],
          child: MaterialApp(
            home: UserImportScreen(
              files: UserPackageFiles(dir: '${tmp.path}/user_packages'),
            ),
          ),
        );

    testWidgets('未授权点「确认导入」→ 出墙、user 行 0、档案 0', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.runAsync(() async {
        await tester.pumpWidget(app());
        await _pumpUntil(tester, find.text('我的模块 · 导入'));

        final field = find.byType(TextField);
        await tester.enterText(field, _csvTwoRows);
        await tester.pump();
        await tester.tap(find.text('解析并预览'));
        await tester.pump();
        expect(find.text('确认导入（将写入本机）'), findsOneWidget);

        await tester.tap(find.text('确认导入（将写入本机）'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // 墙：标题 + 免费说明 + 价格单源（价格不在这里二次写死）。
        expect(find.text('导入自己的词表需要解锁码'), findsOneWidget);
        // 顶部实话与墙内说明都讲「预览免费」——出现两次是对的，不是重复。
        expect(find.textContaining('解析与预览永久免费'), findsWidgets);
        expect(find.textContaining('确认导入会写进「我的模块」'), findsOneWidget);
        expect(find.text('¥$kEarlyBirdPrice'), findsOneWidget);
        expect(find.text('已写入本机'), findsNothing);

        // 结构上零写入：一行台账、一份档案都不许有。
        final store = UserPackageStore(progress.database);
        expect(await store.userRowCount(), 0);
        expect(await store.listPackages(), isEmpty);
        expect(await store.inspect(), isA<UserPackageInventory>());

        // 本机埋点（零遥测，落 analytics_events）。
        expect(progress.analyticsEvents.map((e) => e['n']),
            contains('custom_import_wall_shown'));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    });
  });

  // ── T-B3 库层兜底 ──────────────────────────────────────────────────────
  test('T-B3 库层兜底：直调 allowed:false ⇒ failed + gated + 零写入', () async {
    final r = await _rig();
    final v = await _validate(_csvTwoRows);
    expect(v.ok, isTrue);

    final res = await r.store.importValidation(v, allowed: false);
    expect(res.ok, isFalse);
    expect(res.gated, isTrue, reason: 'UI 要能靠这个标记记埋点');
    expect(res.note, contains('解锁码'));
    expect(await r.store.userRowCount(), 0, reason: '绕开 UI 也不许写');
    expect(await r.store.listPackages(), isEmpty);

    // 对照：同一个 v 放行就照旧落库（门不是把功能写坏）。
    final ok = await r.store.importValidation(v, allowed: true);
    expect(ok.ok, isTrue);
    expect(await r.store.userRowCount(), 2);
  });

  // ── T-B4 备份通道 ──────────────────────────────────────────────────────
  test('T-B4 备份通道：未授权不收 userpkg 档案、不补行、如实报数；授权逐字段照旧', () async {
    final src = await _rig();
    expect((await src.store.importValidation(await _validate(_csvTwoRows),
            allowed: true))
        .ok, isTrue);
    await src.p.database.setKv('baseRate', '1.25');
    final export = await buildChannelExport(db: src.p.database, gate: src.gate);
    final payload = jsonDecode(export.json) as Map<String, dynamic>;
    expect((payload['kv'] as Map).keys.any(
            (k) => k.toString().startsWith(AppDatabase.kUserPkgKvPrefix)),
        isTrue,
        reason: '导出照带词表档案（件是用户自己的数据）');

    // 未授权机器：档案跳过 + 计数，块行不补。
    final locked = await _rig();
    final lockedBefore = await _official(locked);
    final plan = await previewChannelImport(
        db: locked.p.database, text: export.json, allowUserPackages: false);
    expect(plan.ignoredUserArchives, 1);
    final applied = await applyChannelImport(
        db: locked.p.database,
        gate: locked.gate,
        text: export.json,
        store: locked.p.chunkStore,
        allowUserPackages: false);
    expect(applied.ignoredUserArchives, 1);
    expect(applied.rebuiltUserRows, 0);
    expect(await locked.store.userRowCount(), 0);
    expect(await locked.store.listPackages(), isEmpty);
    final lockedKv = await locked.p.database.getAllKv();
    expect(
        lockedKv.keys.any(
            (k) => k.startsWith(AppDatabase.kUserPkgKvPrefix)),
        isFalse,
        reason: '合并一份别人的备份 = 白拿自定义包，这条必须挡住');
    expect(await _official(locked), lockedBefore);

    // 授权机器：A3 行为逐字段不变（档案回来、行补回来、自检一致）。
    final open = await _rig();
    final appliedOpen = await applyChannelImport(
        db: open.p.database,
        gate: open.gate,
        text: export.json,
        store: open.p.chunkStore,
        allowUserPackages: true);
    expect(appliedOpen.ignoredUserArchives, 0);
    expect(appliedOpen.rebuiltUserRows, 2);
    expect(await open.store.userRowCount(), 2);
    expect((await open.store.listPackages()).single.moduleName, '点单');
    expect((await open.store.inspect()).consistent, isTrue);
  });

  // ── T-B5 存量保护 ──────────────────────────────────────────────────────
  test('T-B5 存量保护：门关闭后读删免费、新增/整包替换仍受门、官方口径不动',
      () async {
    final r = await _rig();
    expect((await r.store.importValidation(await _validate(_csvTwoRows),
            allowed: true))
        .ok, isTrue);
    final before = await _official(r);
    final pkg = (await r.store.listPackages()).single;

    // 读：照列。
    expect(pkg.chunkCount, 2);
    // 新增/同名重导：门关闭 ⇒ 挡（同名重导在库层就是新写入）。
    final blocked = await r.store.importValidation(
        await _validate(_csvTwoRows),
        allowed: false);
    expect(blocked.ok, isFalse);
    expect(blocked.gated, isTrue);
    expect(await r.store.userRowCount(), 2, reason: '被挡的导入不许动已有行');
    expect(await _official(r), before, reason: '付费门不许碰官方进度');

    // 删：照用（数据是用户的，删不能收费）。
    final removed = await r.store.removePackage(pkg.moduleKey);
    expect(removed, 2);
    expect(await r.store.userRowCount(), 0);
    expect(await r.store.listPackages(), isEmpty);
    expect(await _official(r), before);
  });

  // ── T-B6 单源静态闸 ────────────────────────────────────────────────────
  test('T-B6 单源：UI 只走 allows(customImport)；库层不认授权装配；墙不二次写死价格',
      () {
    final ui = File('lib/screens/user_import_screen.dart').readAsStringSync();
    final uiCode = _code(ui);
    expect(uiCode.contains('allows(LicenseFeature.customImport)'), isTrue,
        reason: '功能门必须走单一出口，不许散落 if (isPro)');
    expect(uiCode.contains('showLicenseWallSheet('), isTrue);
    expect(uiCode.contains('importValidation(v, allowed: allowed)'), isTrue,
        reason: '确认导入必须把门判据传进库层');
    expect(RegExp(r'\b(isPro|hasFullAccess)\b').hasMatch(uiCode), isFalse,
        reason: 'UI 直判授权态 = 绕过 allows() 的第二份判据');
    expect(ui.contains('¥'), isFalse, reason: '墙点价格只有一个真源（license_activate）');

    final backup = File('lib/screens/data_backup.dart').readAsStringSync();
    final backupCode = _code(backup);
    expect(backupCode.contains('allows(LicenseFeature.customImport)'), isTrue,
        reason: '备份导入通道也必须过同一道门');
    expect(backupCode.contains('allowUserPackages: allowUserPackages'), isTrue);
    expect(RegExp(r'\b(isPro|hasFullAccess)\b').hasMatch(backupCode), isFalse);

    final store =
        File('lib/services/user_package_store.dart').readAsStringSync();
    expect(store.contains('required bool allowed'), isTrue,
        reason: 'allowed 必须必填：不给默认值，逼调用方表态');
    expect(store.contains('bool allowed ='), isFalse, reason: '不许给默认放行');
    expect(_code(store).contains('LicenseState'), isFalse,
        reason: '库层只拿 db，不拖授权装配');
    expect(store.contains('UserImportResult.blockedByLicense'), isTrue);

    // 墙文案的价格/名额仍是单源常量。
    final lic = File('lib/screens/license_activate.dart').readAsStringSync();
    expect(lic.contains('kEarlyBirdPrice'), isTrue);
    expect(lic.contains('kEarlyBirdSeats'), isTrue);
  });
}

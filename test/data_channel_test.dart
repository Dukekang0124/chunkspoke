import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/data_channel.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/legacy_gate.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

/// 1.5.10（#209 通道版）· JSON 导出 / 导入合并 + D1 身份回写。
///
/// 口径：导出带 `legacy.flag`；导入**先写库外标记，再动库**；
/// 合并只补不删（本机更新的进度保留、会话按四元组去重、设置不覆盖）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late Directory support;
  late LegacyGate gate;
  var probes = 0;

  setUp(() async {
    db = AppDatabase(path: inMemoryDatabasePath);
    support = await Directory.systemTemp.createTemp('cs_channel_');
    probes = 0;
    gate = LegacyGate(
      supportDir: support,
      dbExists: () async {
        probes++;
        return true;
      },
    );
  });

  tearDown(() async {
    await (await db.db).close();
    if (await support.exists()) await support.delete(recursive: true);
  });

  Future<void> seed() async {
    await db.setKv('baseRate', '1.25');
    await db.setKv('customLlmModel', 'glm-4.7-flash');
    await db.insertSession('c1', 'speakSuccess', 90, ts: 1000);
    await db.upsertChunk(const ChunkRow(
      chunkKey: 'c1',
      level: ChunkLevel.review,
      dueDate: 5000,
      failCount: 1,
      lastScore: 90,
      assetState: ChunkAssetState.consolidated,
      reviewStage: 1,
      firstLearnedAt: 900,
      reviewCount: 2,
      lastReviewAt: 1000,
    ));
  }

  group('导出', () {
    test('带 schema/版本/三表计数 + legacy 标记原件', () async {
      await gate.bootstrap();
      await seed();
      final e = await buildChannelExport(db: db, gate: gate);
      final m = jsonDecode(e.json) as Map<String, dynamic>;
      expect(m['schema_version'], kChannelSchema);
      expect(m['app_version'], kChannelAppVersion);
      expect((m['counts'] as Map)['chunks'], 1);
      expect((m['counts'] as Map)['sessions'], 1);
      expect((m['kv'] as Map)['baseRate'], '1.25');
      final legacy = m['legacy'] as Map;
      expect(legacy['flag'], kLegacyFlagYes);
      expect(legacy['eligible'], true);
      // 「首迹」取最早 first_learned_at。
      expect(legacy['since'], 900);
      expect(e.legacyFlag, kLegacyFlagYes);
      expect(e.filename, startsWith('chunkspoke_backup_'));
      expect(e.filename, endsWith('.json'));
    });

    test('没有 legacy.flag 时按 0 导出，不伪造老用户', () async {
      await seed();
      final e = await buildChannelExport(db: db, gate: gate);
      expect(e.legacyFlag, kLegacyFlagNo);
      final legacy = (jsonDecode(e.json) as Map)['legacy'] as Map;
      expect(legacy['eligible'], false);
    });

    test('无学习痕迹时 since 退到导出时刻（不留 0）', () async {
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final m = buildChannelMap(
        kv: {'a': 'b'},
        chunks: const [],
        sessions: const [],
        legacyFlag: kLegacyFlagNo,
        now: at,
      );
      expect((m['legacy'] as Map)['since'], 1700000000000);
    });
  });

  group('解析与拒绝', () {
    test('空串 / 非 JSON / 非对象 / 缺字段 各有可读原因', () {
      expect(() => decodeChannel('  '), throwsA(isA<ChannelFormatError>()));
      expect(() => decodeChannel('not json'), throwsA(isA<ChannelFormatError>()));
      expect(() => decodeChannel('[1,2]'), throwsA(isA<ChannelFormatError>()));
      expect(() => decodeChannel('{"schema_version":1}'),
          throwsA(isA<ChannelFormatError>()));
    });

    test('来自更新版本的备份拒绝接收（不猜、不降级解析）', () {
      final m = jsonEncode({
        'schema_version': kChannelSchema + 1,
        'kv': {},
        'chunks': [
          {'chunk_key': 'x'}
        ],
        'sessions': [],
      });
      expect(
        () => decodeChannel(m),
        throwsA(predicate((e) =>
            e is ChannelFormatError && e.reason.contains('更新的版本'))),
      );
    });

    test('空备份拒绝（三表全空）', () {
      final m = jsonEncode({
        'schema_version': 1,
        'kv': {},
        'chunks': [],
        'sessions': [],
      });
      expect(
        () => decodeChannel(m),
        throwsA(predicate(
            (e) => e is ChannelFormatError && e.reason.contains('是空的'))),
      );
    });

    // D1 回归：早期判据是「chunks/sessions 都空就整份拒」，会把「只改过设置、
    // 还没开始学」的老用户挡在门外——他的 legacy 标记就在备份里，整份被拒
    // 等于清过一次数据身份就回不来。判据必须只认「三表全空」。
    test('只有设置的备份可解析（老用户没学过也算有内容）', () {
      final m = jsonEncode({
        'schema_version': 1,
        'kv': {'baseRate': '1.25'},
        'chunks': [],
        'sessions': [],
      });
      final decoded = decodeChannel(m);
      expect(decoded['chunks'], isEmpty);
      expect(decoded['sessions'], isEmpty);
      expect((decoded['kv'] as Map)['baseRate'], '1.25');
    });
  });

  group('导入合并', () {
    String exportOf({
      required Map<String, String> kv,
      required List<Map<String, Object?>> chunks,
      required List<Map<String, Object?>> sessions,
      String flag = kLegacyFlagNo,
    }) =>
        jsonEncode(buildChannelMap(
          kv: kv,
          chunks: chunks,
          sessions: sessions,
          legacyFlag: flag,
          now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ));

    Map<String, Object?> chunkMap(
      String key, {
      int asset = 0,
      int reviewCount = 0,
      int lastReviewAt = 0,
    }) =>
        {
          'chunk_key': key,
          'level': 0,
          'due_date': 0,
          'fail_count': 0,
          'last_score': 0,
          'l2_one_try': -1,
          'l4_self_eval': 0,
          'review_stage': 0,
          'asset_state': asset,
          'asset_return_state': -1,
          'asset_return_stage': -1,
          'first_learned_at': 0,
          'review_count': reviewCount,
          'correct_streak': 0,
          'last_review_at': lastReviewAt,
        };

    test('新块进来、本机更新的块留下、会话去重', () async {
      await seed();
      final text = exportOf(
        kv: {'baseRate': '0.75', 'newKey': 'v'},
        chunks: [
          chunkMap('c1', asset: 0, reviewCount: 9), // 比本机弱 → 保留本机
          chunkMap('c2', asset: 3), // 新块
        ],
        sessions: [
          {'chunk_key': 'c1', 'ts': 1000, 'outcome': 'speakSuccess', 'score': 90, 'review': 0},
          {'chunk_key': 'c2', 'ts': 2000, 'outcome': 'speakSuccess', 'score': 80, 'review': 0},
        ],
      );

      final plan = await previewChannelImport(db: db, text: text, allowUserPackages: true);
      expect(plan.newChunks, 1);
      expect(plan.updatedChunks, 0);
      expect(plan.keptChunks, 1);
      expect(plan.newSessions, 1);
      expect(plan.dupSessions, 1);
      expect(plan.newKv, 1); // baseRate 已存在 → 不算新增

      await applyChannelImport(db: db, gate: gate, text: text, allowUserPackages: true);

      final c1 = await db.getChunk('c1');
      expect(c1!.assetState, ChunkAssetState.consolidated); // 本机更新未被压回
      expect(await db.getChunk('c2'), isNotNull);
      // 设置不覆盖：本机 1.25 保留，新键补上。
      expect(await db.getKv('baseRate'), '1.25');
      expect(await db.getKv('newKey'), 'v');
      expect((await db.allSessionRows()).length, 2);
    });

    test('同一条块备份更强时覆盖（补不是删）', () async {
      await db.upsertChunk(const ChunkRow(
        chunkKey: 'c9',
        level: ChunkLevel.review,
        dueDate: 0,
        failCount: 0,
        lastScore: 70,
        assetState: ChunkAssetState.consolidating,
      ));
      final text = exportOf(
        kv: {},
        chunks: [chunkMap('c9', asset: 4, reviewCount: 3, lastReviewAt: 5000)],
        sessions: [
          {'chunk_key': 'c9', 'ts': 1, 'outcome': 'x', 'score': 0, 'review': 0}
        ],
      );
      final plan = await applyChannelImport(db: db, gate: gate, text: text, allowUserPackages: true);
      expect(plan.updatedChunks, 1);
      final row = await db.getChunk('c9');
      expect(row!.assetState, ChunkAssetState.mastered);
      expect(row.reviewCount, 3);
    });

    test('重复导入幂等：第二次什么都不做', () async {
      await seed();
      final text = exportOf(
        kv: {'baseRate': '0.75'},
        chunks: [chunkMap('c1'), chunkMap('c2')],
        sessions: [
          {'chunk_key': 'c1', 'ts': 1000, 'outcome': 'speakSuccess', 'score': 90, 'review': 0},
          {'chunk_key': 'c3', 'ts': 3000, 'outcome': 'speakSuccess', 'score': 80, 'review': 0},
        ],
      );
      await applyChannelImport(db: db, gate: gate, text: text, allowUserPackages: true);
      final again = await previewChannelImport(db: db, text: text, allowUserPackages: true);
      expect(again.newChunks, 0);
      expect(again.updatedChunks, 0);
      expect(again.newSessions, 0);
      expect(again.newKv, 0);
      expect(again.nothingToDo, isTrue);
    });
  });

  group('D1 导入先于判据', () {
    test('导入把身份写回，且这一步不依赖 DB 探测', () async {
      // 首启：没库 → 0
      final fresh = LegacyGate(
        supportDir: support,
        dbExists: () async {
          probes++;
          return false;
        },
      );
      expect(await fresh.bootstrap(), kLegacyFlagNo);
      expect(probes, 1);

      // 用户装回备份（带 legacy=1）：必须在任何开库动作之前改写标记。
      final text = jsonEncode(buildChannelMap(
        kv: const {},
        chunks: const [
          {
            'chunk_key': 'c1',
            'level': 0,
            'due_date': 0,
            'fail_count': 0,
            'last_score': 0,
            'first_learned_at': 10,
          }
        ],
        sessions: const [],
        legacyFlag: kLegacyFlagYes,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));
      await applyChannelImport(db: db, gate: fresh, text: text, allowUserPackages: true);
      expect(await fresh.readRaw(), kLegacyFlagYes);
      expect(probes, 1, reason: '导入路径不得再探一次库（顺序反了身份就回不来）');

      // 再启动：读到已有值，**永不重写**、也不再探库。
      probes = 0;
      expect(await fresh.bootstrap(), kLegacyFlagYes);
      expect(probes, 0);
    });

    test('已是老用户时导入不会把它改回 0', () async {
      final g = LegacyGate(
        supportDir: support,
        dbExists: () async {
          probes++;
          return true;
        },
      );
      expect(await g.bootstrap(), kLegacyFlagYes);
      expect(await g.adoptFromImport(kLegacyFlagNo), isFalse);
      expect(await g.readRaw(), kLegacyFlagYes);
      probes = 0;
      await g.bootstrap(); // 幂等：有值就不再探库
      expect(probes, 0);
    });

    // COLLAPSE-161 三-2：判据已经把 legacy 写成 0 的新用户，导入带 legacy=1 的
    // 备份后，身份**必须能改回来**；而已经 1 的绝不重复写。
    test('adoptRestoresLegacyAfterZeroFlag', () async {
      final g = LegacyGate(
        supportDir: support,
        dbExists: () async {
          probes++;
          return false;
        },
      );
      expect(await g.bootstrap(), kLegacyFlagNo);
      expect(await g.readRaw(), kLegacyFlagNo);

      // 0 → 1：D1 的恢复通道
      expect(await g.adoptFromImport(kLegacyFlagYes), isTrue);
      expect(await g.readRaw(), kLegacyFlagYes);

      // 已是 1：不重复写、返回 false
      expect(await g.adoptFromImport(kLegacyFlagYes), isFalse);
      expect(await g.readRaw(), kLegacyFlagYes);
      // 全程只有首启那一次探库
      expect(probes, 1);
    });

    // 同一漏洞的端到端形态：老用户只改过设置、没学过，备份里没有 chunks/sessions，
    // 但带着 legacy=1。这条路径必须能走通——否则清过数据的爷爷永远回不来。
    test('只有设置 + legacy=1 的备份也能把身份接回来', () async {
      final fresh = LegacyGate(
        supportDir: support,
        dbExists: () async {
          probes++;
          return false;
        },
      );
      expect(await fresh.bootstrap(), kLegacyFlagNo);

      final text = jsonEncode(buildChannelMap(
        kv: const {'baseRate': '1.25', 'ttsVoice': 'warm'},
        chunks: const [],
        sessions: const [],
        legacyFlag: kLegacyFlagYes,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));

      final plan = await applyChannelImport(db: db, gate: fresh, text: text, allowUserPackages: true);
      expect(plan.newKv, 2);
      expect(plan.newChunks, 0);
      expect(await fresh.readRaw(), kLegacyFlagYes);
      expect(probes, 1, reason: '只有设置也不能再去探库');
      expect(await db.getKv('baseRate'), '1.25');
    });
  });

  // ASR-230 裁定 1 的硬要求：selfEval 台账标记必须**可查**。
  // 真机没有 root 时唯一的查证通道是「设置→数据备份→导出 JSON」，
  // 所以这条链路不能只靠口头承诺，得有钉测：导出带得上、导入回得来。
  group('自评标记可查（票5 的验证口径）', () {
    test('自评写进台账 → 备份件带 l4_self_eval:1 → 导入回来仍是 1', () async {
      await db.upsertChunk(const ChunkRow(
        chunkKey: 'c1',
        level: ChunkLevel.review,
        dueDate: 5000,
        failCount: 0,
        lastScore: 0,
        l2OneTry: 1,
        l4SelfEval: true,
        assetState: ChunkAssetState.learning,
      ));

      final exported = await buildChannelExport(db: db, gate: gate);
      final decoded = jsonDecode(exported.json) as Map<String, dynamic>;
      final row = (decoded['chunks'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((c) => c['chunk_key'] == 'c1');
      expect(row.containsKey('l4_self_eval'), isTrue,
          reason: '备份件的字段白名单里没有自评标记 ⇒ 票5 在真机上无从验证「算我说过」这条腿');
      expect(row['l4_self_eval'], 1);

      // 抹掉本机行再导入：证明这个字段真的落库、也真的回得来（不是只在内存里好看）。
      await db.deleteChunksByKeys(['c1']);
      expect(await db.getChunk('c1'), isNull);
      final plan = await applyChannelImport(db: db, gate: gate, text: exported.json, allowUserPackages: true);
      expect(plan.newChunks, 1);
      expect((await db.getChunk('c1'))!.l4SelfEval, isTrue,
          reason: '导入合并丢了自评标记：清过数据再导回来的用户会被判成没自评');
    });
  });
}

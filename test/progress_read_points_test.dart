import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/learning_flow.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/progress_display.dart';
import 'package:chunkspoke_flutter/services/progress_integrity.dart';
import 'package:chunkspoke_flutter/services/self_check.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

/// 指令 ASR-211 修复 5：进度不变量矩阵 = **写入点 × 读取点**，进 CI。
///
/// 案三能藏这么久，不是某个函数算错，而是**没人知道有几处在读进度**：
/// 地图读集合计数（已掌握 21/25）、练习页读位置缺口（第 10 块）、断点页读快照，
/// 三处各自成立，拼起来就是自相矛盾；自检又拿台账比台账，永远零红。
///
/// 这个测试把话说死：
///   ① 台账/断点的每一个调用点必须登记在下面这张矩阵里——多一个（新读点没审）
///      或少一个（登记已过时）都红；
///   ② 断点快照只允许登记的写点写入；UI 侧禁止用快照块号决定位置或文案；
///   ③ 造一个真跳块台账，钉住「审计 → 渲染 → 自检」三层给出同一组数。
///
/// 跑法：`flutter test test/progress_read_points_test.dart`（发版门禁同套全量里跑）。

/// 扫描用的 token 表；新增进度 API 时先加到这里，再登记进矩阵。
///
/// ASR-228 D3 追加最后一组：`user:` 命名空间的写点与排除口径。
/// 它们与进度同源的理由只有一个——**导入会往同一张 chunks 表写行**；
/// 排除口径一旦散落到各读点，案三就会以「我的模块污染官方计数」的形式重演。
const List<String> _tokens = [
  'allMasteredKeys',
  'allAssetMasteredKeys',
  'assetStateCounts',
  'countAssetMastered',
  'chunkStore.get',
  'nextUnmasteredIndex',
  'allRows',
  'learnResumeFromDb',
  'learnResume(',
  'setLearnResume',
  'clearLearnResume',
  'reconcileResume',
  'learnResumeKey',
  'deriveResume',
  'resumeKvAfterChunkDone',
  'LevelDisplay',
  'kUserKeyExclude',
  'officialOnly',
  'allUserChunks',
  'UserPackageStore',
  'importValidation',
  'reconcileAll',
];

/// 矩阵：文件 → 该文件允许出现的进度调用点。
///
/// 读点口径注释写在这里（案三之后，每个数是谁渲染的必须一眼可查）。
const Map<String, Set<String>> _matrix = {
  // —— 库层：台账唯一读写出口 ——
  'lib/services/database.dart': {
    'allMasteredKeys', // 关卡轴已掌握 key 集合（唯一真源）
    'assetStateCounts', // 资产轴分组计数
    'countAssetMastered', // 资产轴已掌握数
    'kUserKeyExclude', // ASR-228 D3：user: 排除口径的唯一一份
    'officialOnly', // 同上，拼 where 用的单源助手
    'allUserChunks', // 「我的模块」自己的读路径（不与官方口径混用）
  },
  // —— 台账派生层（断点唯一派生式在这里）——
  'lib/services/chunk_progress.dart': {
    'allMasteredKeys',
    'allAssetMasteredKeys',
    'assetStateCounts',
    'countAssetMastered',
    'nextUnmasteredIndex', // 位置缺口（首个未掌握块）
    'allRows',
    'learnResumeKey',
    'deriveResume', // ASR-205 单源派生
  },
  'lib/services/learning_flow.dart': {'learnResumeKey'},
  'lib/services/loaders.dart': {
    'allRows',
    'learnResumeFromDb',
    'learnResume(',
    'setLearnResume',
    'clearLearnResume',
    'reconcileResume',
    'deriveResume',
  },
  // —— 对账与归位 ——
  'lib/services/progress_integrity.dart': {
    'allMasteredKeys',
    'chunkStore.get',
    'allRows', // 孤儿行扫描
    'learnResumeFromDb',
    'learnResumeKey',
    'reconcileResume',
    'resumeKvAfterChunkDone',
    'reconcileAll', // 自愈入口本体
  },
  // —— ASR-228 D3：自定义包写点（同一张 chunks 表，命名空间隔离）——
  'lib/services/user_package_store.dart': {
    'allUserChunks', // userRowCount 只数自己的行
    'UserPackageStore',
    'importValidation', // 唯一写入口
    'kUserKeyExclude', // 注释里点名排除口径，扫描器按字符串计
  },
  'lib/services/progress_guard.dart': {'reconcileAll'},
  'lib/screens/diagnostics.dart': {'reconcileAll'},
  'lib/screens/user_import_screen.dart': {
    'UserPackageStore',
    'importValidation',
    'reconcileAll', // 件 3：导入写完同帧对账，不许等下次冷启动
  },
  // —— 渲染单源与自检 ——
  'lib/services/progress_display.dart': {'LevelDisplay'},
  'lib/services/self_check.dart': {'LevelDisplay'},
  // —— UI 读取点 ——
  'lib/screens/map.dart': {'allMasteredKeys', 'allRows'},
  'lib/screens/me.dart': {'allMasteredKeys'},
  'lib/screens/library.dart': {'allRows'},
  'lib/screens/free_build_screen.dart': {'allRows'},
  'lib/screens/listening_home_screen.dart': {'allRows'},
  'lib/screens/listening_player.dart': {'chunkStore.get', 'allRows'},
  'lib/services/ai_coach.dart': {'allMasteredKeys', 'allAssetMasteredKeys'},
  'lib/services/learning_export.dart': {'allRows'},
  // —— 练习会话：位置来自台账，块内书签只在锚定会话写 ——
  'lib/steps/practice_loop.dart': {
    'chunkStore.get',
    'nextUnmasteredIndex',
    'learnResumeFromDb',
    'setLearnResume',
    'clearLearnResume',
    'resumeKvAfterChunkDone',
    'LevelDisplay',
  },
  // —— 端到端驱动页：造数用，不参与生产路径 ——
  'lib/main_e2e.dart': {
    'chunkStore.get',
    'learnResume(',
    'setLearnResume',
    'clearLearnResume',
  },
};

/// 允许写断点快照的文件（其余文件出现 `setLearnResume` 即红）。
const Set<String> _resumeWriters = {
  'lib/services/loaders.dart',
  'lib/services/chunk_progress.dart',
  'lib/services/database.dart',
  'lib/steps/practice_loop.dart',
  'lib/main_e2e.dart',
};

/// lib/ 下全部 Dart 源，键为仓库相对路径（`lib/screens/map.dart`）。
Map<String, String> _libFiles(String root) {
  final map = <String, String>{};
  for (final e in Directory('$root/lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final rel = e.path.replaceAll(r'\', '/');
    map[rel.substring(rel.indexOf('lib/'))] = e.readAsStringSync();
  }
  return map;
}

Map<String, Set<String>> _scan(Map<String, String> files) {  final out = <String, Set<String>>{};
  for (final e in files.entries) {
    final hits = <String>{for (final t in _tokens) if (e.value.contains(t)) t};
    if (hits.isNotEmpty) out[e.key] = hits;
  }
  return out;
}

/// 去注释后的源码：禁用词检查必须看代码，不能被文档注释里的说明文字误伤。
String _code(String src) => src
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

Level _level(String id, int count) => Level(
      id: id,
      theme: 'Matrix $id',
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

/// 六步全绿 → 该块按关卡轴记为已掌握。
Future<void> _master(ProgressService p, String key) async {
  await p.chunkStore.applyEvent(key, ChunkEvent.assembleCorrect);
  await p.chunkStore.applyEvent(key, ChunkEvent.dragCorrect);
  await p.chunkStore.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 92);
  await p.chunkStore.applyEvent(
    key,
    ChunkEvent.speakSuccess,
    accuracy: 95,
    fourStarsGreen: true,
    enforceFourStars: true,
  );
}

/// 每个用例开头清库：':memory:' 在本机 sqflite_ffi 下会被复用，
/// 上一条用例留下的块会伪装成下一条的「孤儿行」，把测试变成假绿/假红。
Future<void> _reset(ProgressService p) async {
  final d = await p.database.db;
  await d.delete('chunks');
  await d.delete('kv');
  await d.delete('sessions');
}

void main() {
  final root = Directory.current.path;
  late final Map<String, String> files = _libFiles(root);
  late final Map<String, Set<String>> actual = _scan(files);

  group('不变量矩阵（写入点 × 读取点）', () {
    test('每个进度调用点都已登记；漏登记或登记过时都红', () {
      final unregistered = <String>[];
      for (final e in actual.entries) {
        final allowed = _matrix[e.key];
        if (allowed == null) {
          unregistered.add('${e.key} 未登记：${e.value.join(', ')}');
          continue;
        }
        final extra = e.value.difference(allowed);
        if (extra.isNotEmpty) {
          unregistered.add('${e.key} 出现未登记的调用：${extra.join(', ')}');
        }
      }
      final stale = <String>[];
      for (final e in _matrix.entries) {
        if (!files.containsKey(e.key)) {
          stale.add('${e.key} 已不在 lib/ 里（矩阵过时）');
          continue;
        }
        final gone = e.value.difference(actual[e.key] ?? <String>{});
        if (gone.isNotEmpty) stale.add('${e.key} 登记的 ${gone.join(', ')} 已不存在');
      }
      expect(unregistered, isEmpty,
          reason: '新增进度读取点必须先登记并说明渲染口径：\n${unregistered.join('\n')}');
      expect(stale, isEmpty, reason: '登记与源码不符：\n${stale.join('\n')}');
    });

    test('登记规模不低于案三普查的 21 个读/写点', () {
      final n = _matrix.values.fold<int>(0, (s, v) => s + v.length);
      expect(n, greaterThanOrEqualTo(21), reason: '当前登记 $n 个点');
    });

    test('断点快照只有登记的写点能写', () {
      final offenders = [
        for (final e in files.entries)
          if (e.value.contains('setLearnResume') &&
              !_resumeWriters.contains(e.key))
            e.key,
      ];
      expect(offenders, isEmpty, reason: '这些文件不该写断点快照：$offenders');
      // kv 层直接写 learnResume_* 的旁路也要挡住（resetChunks 是唯一例外，在库层；
      // learning_flow.dart 只是**定义**这把 key，不写值）。
      final bypass = [
        for (final e in files.entries)
          if (e.value.contains("'learnResume_") &&
              !{
                'lib/services/loaders.dart',
                'lib/services/database.dart',
                'lib/services/learning_flow.dart', // key 定义处
              }.contains(e.key))
            e.key,
      ];
      expect(bypass, isEmpty, reason: '拼 key 直写断点的旁路：$bypass');
    });

    test('练习页禁止用快照决定位置或文案（ASR-211 修复 2 的钉）', () {
      final src = files['lib/steps/practice_loop.dart']!;
      expect(src.contains('_ci = r.chunkIndex'), isFalse,
          reason: '位置必须由台账派生；快照只提供块内相位');
      expect(src.contains('resume?.chunkIndex ??'), isFalse,
          reason: ':258 那类「快照兜底位置」的写法不得复活');
      expect(src.contains(r'第 ${r.chunkIndex + 1} 块'), isFalse,
          reason: '断点文案不能直接渲染快照块号');
      expect(src.contains('!_isFullLevel'), isTrue,
          reason: '非锚定会话不许写整模块断点（_writeResume 的门）');
      expect(src.contains('LevelDisplay'), isTrue,
          reason: '进度文案必须走渲染单源，不许就地拼数字');
    });

    // ── ASR-228 D3 · 落库件 4：写点登记齐 + 排除口径单源 ──────────────────
    test('user: 排除口径只允许一份定义，别处手写 SQL 即红', () {
      final definers = [
        for (final e in files.entries)
          if (e.value.contains('String kUserKeyExclude')) e.key,
      ];
      expect(definers, ['lib/services/database.dart'],
          reason: '排除口径复制第二份，就等于给未来的漏写读点开门');

      final handWritten = [
        for (final e in files.entries)
          if (e.key != 'lib/services/database.dart' &&
              e.value.contains(r"chunk_key NOT LIKE 'user:%'"))
            e.key,
      ];
      expect(handWritten, isEmpty, reason: '这些文件绕开单源自己拼了排除式：$handWritten');
    });

    test('自定义包只有登记的写入口能写 user 行（UI 不许直接碰库）', () {
      final writers = [
        for (final e in files.entries)
          if (e.value.contains('importValidation') &&
              !{'lib/services/user_package_store.dart',
                'lib/screens/user_import_screen.dart'}.contains(e.key))
            e.key,
      ];
      expect(writers, isEmpty, reason: '出现第二个写入口：$writers');

      final ui = _code(files['lib/screens/user_import_screen.dart']!);
      // 件 3 的静态闸：导入器必须同帧调 reconcileAll，不许等下次冷启动/回前台。
      expect(ui.contains('reconcileAll'), isTrue,
          reason: '导入后立刻对账是 D3 件 3，摘掉它就回到「写完不归位」的老路');
      expect(ui.contains('applyImportedRows'), isFalse,
          reason: 'applyImportedRows 会按官方关卡重算锚点，user 行不许走那条路');

      final store = _code(files['lib/services/user_package_store.dart']!);
      for (final forbidden in ['setLearnResume', 'clearLearnResume', 'applyImportedRows']) {
        expect(store.contains(forbidden), isFalse,
            reason: '落库写手不许碰断点：$forbidden');
      }
    });

    test('D3 之后登记规模只增不减（写点 × 读点矩阵扩容到 30+）', () {
      final n = _matrix.values.fold<int>(0, (s, v) => s + v.length);
      expect(n, greaterThanOrEqualTo(30),
          reason: 'ASR-228 D3 应把命名空间写点与排除口径一并登记，当前 $n 个点');
    });
  });

  group('跳块台账：审计 → 渲染 → 自检 同一组数', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    test('缺口 ≠ 连续末端时，三个口径给出同样的两个数', () async {
      final p = ProgressService(db: AppDatabase(path: ':memory:'));
      await p.init();
      await _reset(p);
      // 6 块里跳着掌握 c0/c1/c4/c5：连续末端=4，缺口=第 3 块，跳块清单=[c2,c3]。
      final level = _level('M', 6);
      final content = ContentPack(version: 'test', levels: [level]);
      p.setChunkTiers(content);
      for (final i in [0, 1, 4, 5]) {
        await _master(p, level.chunks[i].id);
      }

      final a = await ProgressIntegrity.audit(p, level);
      expect(a.ledgerMastered, 4);
      expect(a.ledgerNextIndex, 2);
      expect(a.skippedChunkIds, ['mc2', 'mc3']);
      expect(a.gapAhead, isTrue);
      expect(a.consistent, isTrue, reason: '断点与台账同位，本例只查跳块口径');

      final d = LevelDisplay.of(a);
      expect(d.gapAhead, isTrue);
      expect(d.counter, '4/6');
      expect(d.anchorLine, '第 3 块待通过 · 已掌握 4/6');
      expect(d.ledgerLine, contains('跳块 2'));

      // 自检必须把「渲染值」与「台账」并排打印，跳块记黄牌（不是恒等零红）。
      final section = SelfCheck.progressSection([a]);
      final row = section.rows.firstWhere((r) => r.label == level.theme);
      expect(row.value, contains('渲染「第 3 块待通过 · 已掌握 4/6」'));
      expect(row.value, contains('台账 已掌握 4/6'));
      expect(row.state, CheckState.warn);
      expect(section.rows.any((r) => r.label == '跳块清单'), isTrue);

      final j = a.toJson();
      expect(j['skippedChunks'], 2);
      expect(j['gapAhead'], isTrue);
      expect(j['skippedChunkIds'], ['mc2', 'mc3']);
    });

    test('渲染值与台账不同源时自检判红（防「恒等零红」回潮）', () {
      // 手搓一个「集合计数与缺口一致、但断点仍指后块」的红名单之外的情形：
      // 台账 2/5、缺口第 3 块，断点第 5 块 → staleSnapshot → 必须 fail。
      const a = ModuleAudit(
          levelId: 'z',
          theme: '分歧',
          total: 5,
          ledgerMastered: 2,
          ledgerNextIndex: 2,
          snapshotIndex: 4,
          snapshotChunkId: 'z4',
          snapshotValid: true,
          wrongChunkIds: [],
          pendingChunkIds: ['z2', 'z3', 'z4'],
          skippedChunkIds: [],
          masteredScores: [90, 88]);
      final s = SelfCheck.progressSection([a]);
      final row = s.rows.firstWhere((r) => r.label == '分歧');
      expect(row.state, CheckState.fail);
      expect(s.hasFail, isTrue);
      expect(s.rows.last.value, contains('红名单 1'));
    });

    test('孤儿行扫描：台账有、内容包没有的行进导出（迁移表据此定夺）', () async {
      final p = ProgressService(db: AppDatabase(path: ':memory:'));
      await p.init();
      await _reset(p);
      final level = _level('O', 3);
      final content = ContentPack(version: 'test', levels: [level]);
      p.setChunkTiers(content);
      await _master(p, level.chunks[0].id);
      // 上一版内容包留下的块（本包已无 oc9 / zz1）。
      await p.chunkStore.applyEvent('oc9', ChunkEvent.dragCorrect);
      await p.chunkStore.applyEvent('zz1', ChunkEvent.dragCorrect);

      final o = await ProgressIntegrity.orphans(p, content);
      expect(o.orphanKeys, containsAll(<String>['oc9', 'zz1']));
      expect(o.count, greaterThanOrEqualTo(2));
      expect(o.clean, isFalse);
      expect(o.orphanMastered, 0, reason: '只拖过一步的孤儿不该算丢进度');
      expect(o.toJson()['orphans'], o.count);

      final section = SelfCheck.progressSection(
          [await ProgressIntegrity.audit(p, level)], orphans: o);
      final row = section.rows.firstWhere((r) => r.label == '孤儿行');
      expect(row.state, CheckState.warn);
      expect(row.value, contains('样本'));

      // 报告导出必须带上孤儿计数与跳块计数，真机回执只看这一份文件。
      final report = SelfCheck.assemble(
        at: DateTime.now(),
        audits: [await ProgressIntegrity.audit(p, level)],
        engine: const [CheckRow('离线模型', '已就位', CheckState.pass)],
        packs: const [CheckRow('高清发音包', '未下载（可选包）', CheckState.warn)],
        audio: const [CheckRow('音频缓存', '暂无已生成的音频', CheckState.warn)],
        update: const [CheckRow('本机版本', 'versionCode 1', CheckState.pass)],
        localVersion: 'test',
        localVersionCode: 1,
        orphans: o,
      );
      expect(report.toJson()['orphans'], isNotNull);
      expect(report.toJson().containsKey('gapModules'), isTrue);
      expect(report.orphans?.count, o.count);
    });

    test('冷启动归位：陈旧断点被台账改写，红名单清零并留痕', () async {
      final p = ProgressService(db: AppDatabase(path: ':memory:'));
      await p.init();
      await _reset(p);
      final level = _level('R', 5);
      final content = ContentPack(version: 'test', levels: [level]);
      p.setChunkTiers(content);
      await _master(p, level.chunks[0].id);
      // 手工塞一个指到第 4 块的陈旧书签（非锚定会话遗留的那一类）。
      await p.setLearnResume(
          level.id,
          LearnResume(
            chunkIndex: 3,
            chunkId: level.chunks[3].id,
            phase: 0,
            stars: StarBoard.empty,
            savedAt: DateTime.now().millisecondsSinceEpoch,
          ).encode());

      final before = await ProgressIntegrity.audit(p, level);
      expect(before.consistent, isFalse, reason: '前提：制造出红名单');

      final r = await ProgressIntegrity.reconcileAll(p, content, reason: 'test');
      expect(r.reds, 1);
      expect(r.healed, 1);
      expect(r.remaining, 0);
      expect(r.clean, isTrue);
      expect(r.audits.single.consistent, isTrue);

      final snap = LearnResume.tryDecode(await p.learnResumeFromDb(level.id));
      expect(snap?.chunkIndex, 1, reason: '归位后断点 = 首个未掌握块');

      final names = p.analyticsEvents.map((e) => e['n']).toList();
      expect(names, contains('progress_reconcile'),
          reason: '归位必须留痕，诊断导出才查得到');
      final detail = p.analyticsEvents.lastWhere((e) => e['n'] == 'progress_reconcile');
      expect(detail['p']['reason'], 'test');
      expect(detail['p']['healed'], 1);
    });
  });
}

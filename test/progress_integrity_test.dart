import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/learning_flow.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/progress_integrity.dart';
import 'package:chunkspoke_flutter/services/self_check.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/steps/practice_loop.dart';
import 'package:chunkspoke_flutter/ui/widgets.dart';

/// ASR-203：进度断点修复 + 全模块自检。
/// 钉死四件事：台账单源、块完成与断点同事务、完成态 UX、打开模块对账自愈。

class _Fx {
  _Fx(this.path, this.db, this.p);
  final String path;
  final AppDatabase db;
  final ProgressService p;
}

Future<_Fx> _fx(String tag) async {
  final dir = await Directory.systemTemp.createTemp('integrity_$tag');
  final path = '${dir.path}/t.db';
  final db = AppDatabase(path: path);
  final p = ProgressService(db: db);
  await p.init();
  return _Fx(path, db, p);
}

/// 同一落盘文件另开一条连接：模拟进程被杀后重进。
Future<ProgressService> _reopen(String path) async {
  final p = ProgressService(db: AppDatabase(path: path));
  await p.init();
  return p;
}

Level _level(String id, int count) => Level(
      id: id,
      theme: 'Integrity $id',
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

/// 直接把块写成「关卡轴已掌握」，可精确控制留痕（分数 / 是否一次过）。
Future<void> _mastered(AppDatabase db, String key,
    {int score = 95, int oneTry = 1}) async {
  await db.upsertChunk(ChunkRow(
    chunkKey: key,
    level: ChunkLevel.mastered,
    dueDate: 0,
    failCount: 0,
    lastScore: score,
    l2OneTry: oneTry,
    assetState: ChunkAssetState.mastered,
    firstLearnedAt: 1,
  ));
}

String _snap(int index, String chunkId, {int phase = 0}) => LearnResume(
      chunkIndex: index,
      chunkId: chunkId,
      phase: phase,
      stars: StarBoard.empty,
      savedAt: 1,
    ).encode();

/// 16k / mono / 16bit 的合法 WAV（头部真实，数据段按长度填充）。
Uint8List _wav(int dataBytes, {bool brokenHeader = false}) {
  final out = Uint8List(44 + dataBytes);
  final bd = ByteData.sublistView(out);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      out[off + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, brokenHeader ? 'XIff' : 'RIFF');
  bd.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, 16000, Endian.little);
  bd.setUint32(28, 32000, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, dataBytes, Endian.little);
  return out;
}

/// 走完六步的落库口径（与 PracticeLoop 完成块时一致）。
Future<void> _learnChunk(ProgressService p, String key,
    {bool alsoKv = false,
    String levelId = '',
    List<String> keys = const [],
    int doneIndex = 0}) async {
  await p.chunkStore.applyEvent(key, ChunkEvent.assembleCorrect);
  await p.chunkStore.applyEvent(key, ChunkEvent.dragCorrect);
  await p.chunkStore.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 90);
  await p.chunkStore.applyEvent(
    key,
    ChunkEvent.speakSuccess,
    accuracy: 95,
    fourStarsGreen: true,
    enforceFourStars: true,
    alsoKv: alsoKv
        ? ProgressIntegrity.resumeKvAfterChunkDone(
            levelId: levelId, keys: keys, doneIndex: doneIndex, nowMs: 5)
        : null,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('断点派生自台账（修复 1 + 4）', () {
    test('台账与断点同位 → 一致，不判红，仍可接着练', () async {
      final f = await _fx('aligned');
      final level = _level('L', 5);
      await _mastered(f.db, level.chunks[0].id);
      await _mastered(f.db, level.chunks[1].id);
      await f.p.setLearnResume(level.id, _snap(2, level.chunks[2].id, phase: 3));

      final a = await ProgressIntegrity.audit(f.p, level);
      expect(a.ledgerMastered, 2);
      expect(a.ledgerNextIndex, 2);
      expect(a.snapshotIndex, 2);
      expect(a.staleSnapshot, isFalse);
      expect(a.consistent, isTrue);
      expect(a.complete, isFalse);
      expect(a.shouldOfferResume, isTrue);
      expect(a.startIndex, 2);
      expect(a.ringRatio, closeTo(0.4, 0.001));
    });

    test('复现案例：台账 25/25 而断点停在第 21 块 → 判红、环=100%、自愈', () async {
      final f = await _fx('repro');
      final level = _level('R', 25);
      for (final c in level.chunks) {
        await _mastered(f.db, c.id);
      }
      // 单块/锚定路径只写伪 level 的断点，真实 level 的快照停在旧块。
      await f.p.setLearnResume(level.id, _snap(20, level.chunks[20].id));

      var a = await ProgressIntegrity.audit(f.p, level);
      expect(a.ledgerMastered, 25);
      expect(a.complete, isTrue);
      expect(a.ringRatio, 1.0, reason: '完成态环必须 100%，不再被陈旧快照拖成 80%');
      expect(a.shouldOfferResume, isFalse, reason: '废除陈旧「接着上次练」');
      expect(a.staleSnapshot, isTrue);

      a = await ProgressIntegrity.heal(f.p, level, a);
      expect(a.consistent, isTrue);
      expect(a.snapshotIndex, -1);
      expect(await f.p.learnResumeFromDb(level.id), isNull);
    });

    test('断点超前台账（乱课练）→ 同样以台账为准', () async {
      final f = await _fx('ahead');
      final level = _level('A', 4);
      await _mastered(f.db, level.chunks[0].id);
      await f.p.setLearnResume(level.id, _snap(3, level.chunks[3].id));

      var a = await ProgressIntegrity.audit(f.p, level);
      expect(a.staleSnapshot, isTrue);
      a = await ProgressIntegrity.heal(f.p, level, a);
      expect(a.consistent, isTrue);
      expect(a.startIndex, 1, reason: '推进到首个未完成块');
    });

    test('串到别人块上的快照视为无效断点，也会被清掉', () async {
      final f = await _fx('bogus');
      final level = _level('B', 3);
      await _mastered(f.db, level.chunks[0].id);
      await f.p.setLearnResume(level.id, _snap(1, 'someone_elses_chunk'));

      var a = await ProgressIntegrity.audit(f.p, level);
      expect(a.snapshotValid, isFalse);
      expect(a.staleSnapshot, isTrue);
      a = await ProgressIntegrity.heal(f.p, level, a);
      expect(a.snapshotIndex, -1);
      expect(a.consistent, isTrue);
    });
  });

  group('块完成与断点同事务落盘（修复 2）', () {
    test('resumeKvAfterChunkDone：推进到下一块，最后一块完成则清空', () {
      final keys = ['k0', 'k1', 'k2'];
      final mid = ProgressIntegrity.resumeKvAfterChunkDone(
          levelId: 'L', keys: keys, doneIndex: 0, nowMs: 7);
      final decoded = LearnResume.tryDecode(mid['learnResume_L']);
      expect(decoded, isNotNull);
      expect(decoded!.chunkIndex, 1);
      expect(decoded.chunkId, 'k1');
      expect(decoded.savedAt, 7);

      final last = ProgressIntegrity.resumeKvAfterChunkDone(
          levelId: 'L', keys: keys, doneIndex: 2, nowMs: 9);
      expect(last['learnResume_L'], '');
    });

    test('applyEvent(alsoKv) 一次事务写台账+断点：重开连接后两者同时到位', () async {
      final f = await _fx('txn');
      final level = _level('T', 3);
      final keys = [for (final c in level.chunks) c.id];

      await _learnChunk(f.p, keys[0],
          alsoKv: true, levelId: level.id, keys: keys, doneIndex: 0);

      // 另开连接：不得出现「台账已推进、断点停在旧块」。
      final p2 = await _reopen(f.path);
      final snap = LearnResume.tryDecode(await p2.learnResumeFromDb(level.id));
      expect(snap, isNotNull);
      expect(snap!.chunkIndex, 1);
      expect(snap.chunkId, keys[1]);
      expect(ChunkProgressStore.isMastered(await p2.chunkStore.get(keys[0])),
          isTrue);

      final a = await ProgressIntegrity.audit(p2, level);
      expect(a.ledgerMastered, 1);
      expect(a.staleSnapshot, isFalse, reason: '同事务落盘后不该再出现分歧');
    });

    test('不传 alsoKv 时不碰真实 level 的断点（单块/复习会话）', () async {
      final f = await _fx('nokv');
      final level = _level('N', 2);
      await _learnChunk(f.p, level.chunks[0].id);
      expect(await f.p.learnResumeFromDb(level.id), isNull);
    });
  });

  group('错块留痕与一键修复', () {
    test('已掌握但留痕不合格（分数<80 或未一次过）计入错块', () async {
      final f = await _fx('wrong');
      final level = _level('W', 3);
      await _mastered(f.db, level.chunks[0].id, score: 95);
      await _mastered(f.db, level.chunks[1].id, score: 60);
      await _mastered(f.db, level.chunks[2].id, score: 90, oneTry: 0);

      final a = await ProgressIntegrity.audit(f.p, level);
      expect(a.ledgerMastered, 3);
      expect(a.complete, isTrue);
      expect(
          a.wrongChunkIds, containsAll([level.chunks[1].id, level.chunks[2].id]));
      expect(a.pendingChunkIds, isEmpty);
      expect(a.minMasteredScore, 60);
      expect(a.avgMasteredScore, closeTo((95 + 60 + 90) / 3, 0.01));
    });

    test('healAll 只动红名单，修完全绿；同位断点保留', () async {
      final f = await _fx('healall');
      final bad = _level('H1', 2);
      final good = _level('H2', 2);
      final content = ContentPack(version: 'test', levels: [bad, good]);
      await _mastered(f.db, bad.chunks[0].id);
      await f.p.setLearnResume(bad.id, _snap(0, bad.chunks[0].id));
      await _mastered(f.db, good.chunks[0].id);
      await f.p.setLearnResume(good.id, _snap(1, good.chunks[1].id));

      final audits = await ProgressIntegrity.auditAll(f.p, content);
      expect(ProgressIntegrity.reds(audits).map((a) => a.levelId), ['H1']);

      final healed = await ProgressIntegrity.healAll(f.p, content, audits);
      expect(ProgressIntegrity.reds(healed), isEmpty);
      expect(healed.firstWhere((a) => a.levelId == good.id).snapshotIndex, 1,
          reason: '与台账同位的断点是真块内断点，必须保留');
      expect(healed.firstWhere((a) => a.levelId == bad.id).snapshotIndex, -1);
    });
  });

  group('自检判定层（自检页四区块）', () {
    const red = ModuleAudit(
        levelId: 'x',
        theme: 'Red',
        total: 5,
        ledgerMastered: 5,
        ledgerNextIndex: 5,
        snapshotIndex: 2,
        snapshotChunkId: 'x2',
        snapshotValid: true,
        wrongChunkIds: [],
        pendingChunkIds: [],
        masteredScores: [90]);
    const clean = ModuleAudit(
        levelId: 'y',
        theme: 'Clean',
        total: 4,
        ledgerMastered: 1,
        ledgerNextIndex: 1,
        snapshotIndex: -1,
        snapshotChunkId: null,
        snapshotValid: false,
        wrongChunkIds: [],
        pendingChunkIds: ['y1'],
        masteredScores: [88]);

    test('progressSection：台账/断点/环/分数 四项同排 + 红名单汇总', () {
      final s = SelfCheck.progressSection([red, clean]);
      expect(s.title, '进度完整性');
      expect(s.hasFail, isTrue);
      expect(s.rows[0].state, CheckState.fail);
      expect(s.rows[0].value,
          '台账 5/5 · 断点第 3 块 · 环 100% · 最低 90 / 均值 90.0');
      expect(s.rows[1].state, CheckState.pass);
      expect(s.rows[1].value, contains('无断点'));
      expect(s.rows.last.value, '2 个模块 · 红名单 1');
    });

    test('progressSection：无模块时给黄牌而不是崩溃', () {
      final s = SelfCheck.progressSection(const []);
      expect(s.rows.single.state, CheckState.warn);
      expect(s.hasFail, isFalse);
    });

    test('资源完整性：引擎与增强包红黄绿', () {
      final engine = SelfCheck.engineRows(
          modelOnDisk: false,
          engineReady: false,
          engineFailed: true,
          engineError: 'load failed');
      expect(engine.first.state, CheckState.warn);
      expect(engine.last.state, CheckState.fail);

      final packs = SelfCheck.packRows(
          hdVoiceLabel: 'Amy',
          hdInstalled: true,
          hdEngineUp: true,
          enhancedPresent: true,
          enhancedInstalled: false,
          enhancedEnabled: false);
      expect(packs.first.state, CheckState.pass);
      expect(packs.last.state, CheckState.warn);
    });

    test('音频抽检：0 字节 / 坏头 / 过短都算损坏', () async {
      final dir = await Directory.systemTemp.createTemp('selfcheck_audio');
      File('${dir.path}/good.wav').writeAsBytesSync(_wav(32000));
      File('${dir.path}/empty.wav').writeAsBytesSync(Uint8List(0));
      File('${dir.path}/broken.wav')
          .writeAsBytesSync(_wav(100, brokenHeader: true));
      File('${dir.path}/tiny.wav').writeAsBytesSync(_wav(320));
      File('${dir.path}/note.txt').writeAsBytesSync(Uint8List(10));

      final scan = await SelfCheck.scanAudioCache([dir.path]);
      expect(scan.total, 4, reason: '只抽 WAV，别的扩展名不算');
      expect(scan.checked, 4);
      expect(scan.zeroBytes, 1);
      expect(scan.badHeaders, 1);
      expect(scan.tooShort, 1);
      expect(scan.broken, 3);
      expect(scan.shortestSec, closeTo(0.01, 0.001));
      expect(SelfCheck.audioRows(scan).first.state, CheckState.fail);

      final missing = await SelfCheck.scanAudioCache(['${dir.path}/none']);
      expect(missing.total, 0);
      expect(SelfCheck.audioRows(missing).first.state, CheckState.warn);
    });

    test('音频抽检：整批正常时给绿牌', () async {
      final dir = await Directory.systemTemp.createTemp('selfcheck_audio_ok');
      File('${dir.path}/a.wav').writeAsBytesSync(_wav(16000));
      File('${dir.path}/b.wav').writeAsBytesSync(_wav(48000));
      final scan = await SelfCheck.scanAudioCache([dir.path]);
      expect(scan.broken, 0);
      expect(scan.checked, 2);
      expect(SelfCheck.audioRows(scan).single.state, CheckState.pass);
    });

    test('更新链路：可达+版本解析 / 解析失败 / 不可达三态', () async {
      final client = MockClient((request) async {
        final u = request.url.toString();
        if (u.contains('pages')) {
          return http.Response(
              jsonEncode({'versionName': '1.7.0', 'versionCode': 2070}), 200);
        }
        if (u.contains('jsdelivr')) {
          return http.Response(jsonEncode({'versionName': '1.7.0'}), 200);
        }
        return http.Response('nope', 503);
      });
      final rows = await SelfCheck.updateRows(
        localVersionCode: 2070,
        client: client,
        urls: [
          'https://pages.example/version.json',
          'https://jsdelivr.example/version.json',
          'https://raw.example/version.json',
        ],
      );
      expect(rows.first.label, '本机版本');
      expect(rows[1].state, CheckState.pass);
      expect(rows[1].value, contains('已是最新'));
      expect(rows[2].value, contains('versionCode'));
      expect(rows[2].state, CheckState.fail);
      expect(rows[3].state, CheckState.warn);

      final newer = await SelfCheck.updateRows(
        localVersionCode: 2069,
        client: MockClient(
            (_) async => http.Response(jsonEncode({'versionCode': 2070}), 200)),
        urls: ['https://pages.example/version.json'],
      );
      expect(newer[1].value, contains('有更新'));

      // 跨 ABI 槽位（x64 基础号 vs 清单 arm64 号）不得误报「有更新」。
      final crossSlot = await SelfCheck.updateRows(
        localVersionCode: 2070,
        client: MockClient(
            (_) async => http.Response(jsonEncode({'versionCode': 4066}), 200)),
        urls: ['https://pages.example/version.json'],
      );
      expect(crossSlot[1].value, contains('非本机 ABI 槽位'));
      expect(crossSlot[1].state, CheckState.pass);
    });

    test('归档：JSON 三段结构 + 文件名 + 落盘', () async {
      final f = await _fx('archive');
      final report = SelfCheck.assemble(
        at: DateTime.parse('2026-11-02T10:20:30.000'),
        audits: [await ProgressIntegrity.audit(f.p, _level('AR', 2))],
        engine: SelfCheck.engineRows(
            modelOnDisk: true, engineReady: false, engineFailed: false),
        packs: SelfCheck.packRows(
            hdVoiceLabel: 'Amy',
            hdInstalled: false,
            hdEngineUp: false,
            enhancedPresent: true,
            enhancedInstalled: false,
            enhancedEnabled: false),
        audio: SelfCheck.audioRows(AudioScan.empty()),
        update: [const CheckRow('本机版本', 'x', CheckState.pass)],
        localVersion: '1.7.0',
        localVersionCode: 2070,
      );
      expect(SelfCheck.fileName(report.at), 'selfcheck-20261102-102030.json');
      final json = jsonDecode(report.encode()) as Map<String, dynamic>;
      expect(json['allGreen'], isTrue);
      expect(json['reds'], isEmpty);
      expect((json['sections'] as List).map((s) => s['title']),
          ['进度完整性', '资源完整性', '更新链路']);

      final dir = await Directory.systemTemp.createTemp('selfcheck_out');
      final out = await SelfCheck.archive(dir.path, report);
      expect(await out.exists(), isTrue);
      expect(jsonDecode(await out.readAsString())['localVersion'], '1.7.0');
    });
  });

  group('完成态 UX（修复 3）', () {
    Widget gate(ProgressService p, ContentPack content) => MultiProvider(
          providers: [
            Provider<ProgressService>.value(value: p),
            Provider<ContentPack>.value(value: content),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PracticeLoop(level: content.levels.first, onDone: (_) {}),
            ),
          ),
        );

    testWidgets('整模块已掌握 + 陈旧断点 → 已完成 N/N，不出现接着上次练',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        final f = await _fx('gate_done');
        final level = _level('G', 3);
        for (final c in level.chunks) {
          await _mastered(f.db, c.id);
        }
        await f.p.setLearnResume(level.id, _snap(1, level.chunks[1].id, phase: 2));
        final content = ContentPack(version: 'test', levels: [level]);

        await tester.pumpWidget(gate(f.p, content));
        for (var i = 0; i < 12; i++) {
          // 真实 SQLite I/O：runAsync 里必须给真实事件循环时间，光推进假钟等不到落库。
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 40));
        }

        expect(find.text('已完成 3/3'), findsOneWidget);
        expect(find.text('接着上次练'), findsNothing);
        expect(find.byKey(const Key('done-gate-restart')), findsOneWidget);
        // 没有留痕不合格的块 → 不给错块复习按钮
        expect(find.byKey(const Key('done-gate-review-wrong')), findsNothing);

        final ring = tester.widget<CircularProgressIndicator>(find.descendant(
            of: find.byType(MasteryRing),
            matching: find.byType(CircularProgressIndicator)));
        expect(ring.value, 1.0, reason: '验收口径：复现案例详情环=100');

        // 自愈已经把陈旧断点清掉：自检页复跑必须零红。
        final audits = await ProgressIntegrity.auditAll(f.p, content);
        expect(ProgressIntegrity.reds(audits), isEmpty);
      });
    });

    testWidgets('有错块留痕 → 完成态给出错块复习入口', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        final f = await _fx('gate_wrong');
        final level = _level('W2', 3);
        await _mastered(f.db, level.chunks[0].id, score: 70);
        await _mastered(f.db, level.chunks[1].id);
        await _mastered(f.db, level.chunks[2].id);
        final content = ContentPack(version: 'test', levels: [level]);

        await tester.pumpWidget(gate(f.p, content));
        for (var i = 0; i < 12; i++) {
          // 真实 SQLite I/O：runAsync 里必须给真实事件循环时间，光推进假钟等不到落库。
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.text('已完成 3/3'), findsOneWidget);
        expect(find.byKey(const Key('done-gate-review-wrong')), findsOneWidget);
        expect(find.text('错块复习（1 块）'), findsOneWidget);
      });
    });

    testWidgets('半程模块 + 同位断点 → 仍给接着上次练，环取台账', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        final f = await _fx('gate_resume');
        final level = _level('H', 4);
        await _mastered(f.db, level.chunks[0].id);
        await _mastered(f.db, level.chunks[1].id);
        await f.p.setLearnResume(level.id, _snap(2, level.chunks[2].id, phase: 3));
        final content = ContentPack(version: 'test', levels: [level]);

        await tester.pumpWidget(gate(f.p, content));
        for (var i = 0; i < 12; i++) {
          // 真实 SQLite I/O：runAsync 里必须给真实事件循环时间，光推进假钟等不到落库。
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.text('接着上次练'), findsOneWidget);
        expect(find.text('已完成 4/4'), findsNothing);
        expect(find.textContaining('上次学到 第 3 块'), findsOneWidget);

        final ring = tester.widget<CircularProgressIndicator>(find.descendant(
            of: find.byType(MasteryRing),
            matching: find.byType(CircularProgressIndicator)));
        expect(ring.value, closeTo(0.5, 0.001));
      });
    });
  });
}

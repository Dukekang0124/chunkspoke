import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/learning_flow.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/progress_integrity.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

/// ASR-205 闸①：断点不变量属性测试。
///
/// 不变量：**任意完成路径之后，锚点 ∈ {首个未完成块, 末块+1}**。
/// 锚点 = `learnResume_<levelId>` 的 chunkIndex；末块+1 表现为快照清空。
/// 随机序列固定种子，失败可复现；1000 组进 CI / 发版门禁。
Level _level(String id, int count) => Level(
      id: id,
      theme: 'Invariant $id',
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

Future<void> _reset(ProgressService p) async {
  final d = await p.database.db;
  await d.delete('chunks');
  await d.delete('kv');
  await d.delete('sessions');
}

Future<void> _learn(ProgressService p, String key) async {
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

/// 该块本次随机走的完成路径。
Future<void> _applyRandomPath(ProgressService p, String key, int path) async {
  switch (path) {
    case 0: // 锚定学习：六步全绿 → mastered
      await _learn(p, key);
    case 1: // 只过到听辨，未完成
      await p.chunkStore.applyEvent(key, ChunkEvent.dragCorrect);
    case 2: // 学完但四星未全绿 → level=review（台账仍算未完成）
      await p.chunkStore.applyEvent(key, ChunkEvent.assembleCorrect);
      await p.chunkStore.applyEvent(key, ChunkEvent.dragCorrect);
      await p.chunkStore.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 90);
      await p.chunkStore.applyEvent(
        key,
        ChunkEvent.speakSuccess,
        accuracy: 90,
        fourStarsGreen: false,
        enforceFourStars: true,
      );
    case 3: // 主动跳过 → scheduleReview
      await p.chunkStore.applyEvent(key, ChunkEvent.scheduleReview);
    case 4: // 非锚定路径：复习通过（不传 alsoKv）
      await p.chunkStore.applyEvent(key, ChunkEvent.dragCorrect);
      await p.chunkStore.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 95);
      await p.chunkStore.applyEvent(key, ChunkEvent.speakSuccess,
          accuracy: 95, review: true);
    default: // 本次不动
      break;
  }
}

Future<void> _assertInvariant(
    ProgressService p, Level level, int iter, String stage) async {
  final keys = [for (final c in level.chunks) c.id];
  final mastered = (await p.chunkStore.allMasteredKeys()).toSet();
  var anchor = keys.length;
  for (var i = 0; i < keys.length; i++) {
    if (!mastered.contains(keys[i])) {
      anchor = i;
      break;
    }
  }

  final raw = await p.learnResumeFromDb(level.id);
  final snap = LearnResume.tryDecode(raw);
  if (anchor >= keys.length) {
    expect(raw == null || raw.trim().isEmpty, isTrue,
        reason: 'iter=$iter $stage：整关完成应清空断点，实际=$raw');
  } else {
    expect(snap, isNotNull,
        reason: 'iter=$iter $stage：未完成关必须有断点，实际=$raw');
    expect(snap!.chunkIndex, anchor,
        reason: 'iter=$iter $stage：锚点越界/错位（期望 $anchor）');
    expect(snap.chunkId, keys[anchor],
        reason: 'iter=$iter $stage：锚点块 id 不符');
  }

  final audit = await ProgressIntegrity.audit(p, level);
  expect(audit.ledgerNextIndex, anchor,
      reason: 'iter=$iter $stage：审计锚点与台账不一致');
  expect(audit.consistent, isTrue,
      reason: 'iter=$iter $stage：台账与断点必须零分歧');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('不变量：1000 组随机完成序列后 锚点 ∈ {首个未完成块, 末块+1}', () async {
    final p = ProgressService(db: AppDatabase(path: ':memory:'));
    await p.init();
    final level = _level('P', 4);
    final content = ContentPack(version: 'test', levels: [level]);
    p.setChunkTiers(content);

    final rnd = Random(20261103);
    for (var iter = 0; iter < 1000; iter++) {
      await _reset(p);
      var completedAny = false;
      final order = List<int>.generate(level.chunks.length, (i) => i)
        ..shuffle(rnd);
      for (final i in order) {
        final path = rnd.nextInt(6);
        await _applyRandomPath(p, level.chunks[i].id, path);
        // 只有「完成路径」才承诺落断点；纯中途/不动作不在此列。
        if (path == 0 || path == 2 || path == 3 || path == 4) {
          completedAny = true;
          await _assertInvariant(p, level, iter, '块$i/路径$path');
        }
      }
      if (completedAny) {
        await _assertInvariant(p, level, iter, '轮末');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  // ── ASR-206 §二：写入点矩阵（六步之外的台账写入点各造一条）──────────────
  //
  // 规矩：**任何写台账的地方，必须在同一事务里把锚点同步到「首个未完成块」**。
  // 上面 1000 组只覆盖 applyEvent 家族；导入 / 迁移重置 / 失败回退 / 一键修复
  // 走的是别的调用点，第三案只会从这些没被断言的口子长出来。

  Future<void> freshLevel(ProgressService p, Level level) async {
    await _reset(p);
    p.setChunkTiers(ContentPack(version: 'test', levels: [level]));
  }

  Future<String?> anchorRaw(ProgressService p, String levelId) =>
      p.learnResumeFromDb(levelId);

  test('写入点·导入合并：块行与锚点同事务，锚点=首个未完成块', () async {
    final p = ProgressService(db: AppDatabase(path: ':memory:'));
    await p.init();
    final level = _level('I', 4);
    await freshLevel(p, level);

    ChunkRow masteredRow(int i) => ChunkRow(
          chunkKey: 'ic$i',
          level: ChunkLevel.mastered,
          dueDate: 0,
          failCount: 0,
          lastScore: 90,
          l2OneTry: 1,
        );

    // 备份带来前 3 块已掌握：锚点必须立刻落到第 4 块（ic3），不等 heal。
    await p.chunkStore.applyImportedRows(
        List.generate(3, (i) => masteredRow(i)));
    final snap = LearnResume.tryDecode(await anchorRaw(p, 'I'));
    expect(snap, isNotNull, reason: '导入后台账前进，锚点必须同事务写出');
    expect(snap!.chunkIndex, 3, reason: '锚点应=首个未完成块（第 4 块）');
    expect(snap.chunkId, 'ic3');
    final a1 = await ProgressIntegrity.audit(p, level);
    expect(a1.consistent, isTrue, reason: '导入不应留下台账/锚点分歧');

    // 整关补齐：锚点应清空（末块+1 口径）。
    await p.chunkStore.applyImportedRows([masteredRow(3)]);
    final raw = await anchorRaw(p, 'I');
    expect(raw == null || raw.trim().isEmpty, isTrue,
        reason: '整关掌握应清空锚点，实际=$raw');
    final a2 = await ProgressIntegrity.audit(p, level);
    expect(a2.complete, isTrue);
    expect(a2.consistent, isTrue);
  });

  test('写入点·迁移重置：清台账同事务清锚点，不留反向脏快照', () async {
    final p = ProgressService(db: AppDatabase(path: ':memory:'));
    await p.init();
    final level = _level('R', 4);
    await freshLevel(p, level);
    await _learn(p, 'rc0');
    await _learn(p, 'rc1');
    expect(LearnResume.tryDecode(await anchorRaw(p, 'R'))!.chunkIndex, 2,
        reason: '前置：两块完成后锚点应在第 3 块');

    await p.database.resetChunks();
    final d = await p.database.db;
    final left = await d.query('kv', where: "key LIKE 'learnResume_%'");
    expect(left, isNotEmpty, reason: '重置应留下已清空的锚点行');
    for (final r in left) {
      expect((r['value'] as String?)?.trim().isNotEmpty, isFalse,
          reason: '清台账必须同事务清断点，实际=${r['key']}=${r['value']}');
    }
    final audit = await ProgressIntegrity.audit(p, level);
    expect(audit.ledgerMastered, 0);
    expect(audit.consistent, isTrue, reason: '重置后不得判红（锚点>台账=脏数据）');
  });

  test('写入点·开口失败：非完成路径不得推动锚点', () async {
    final p = ProgressService(db: AppDatabase(path: ':memory:'));
    await p.init();
    final level = _level('F', 4);
    await freshLevel(p, level);
    await _learn(p, 'fc0');
    final before = LearnResume.tryDecode(await anchorRaw(p, 'F'))!.chunkIndex;
    expect(before, 1);

    await p.chunkStore.applyEvent('fc1', ChunkEvent.assembleCorrect);
    await p.chunkStore.applyEvent('fc1', ChunkEvent.dragCorrect);
    await p.chunkStore.applyEvent('fc1', ChunkEvent.accuracyPass, accuracy: 90);
    await p.chunkStore.applyEvent('fc1', ChunkEvent.speakFail);
    final after = LearnResume.tryDecode(await anchorRaw(p, 'F'))!.chunkIndex;
    expect(after, 1, reason: '未掌握的块不能把锚点推前');
    final a = await ProgressIntegrity.audit(p, level);
    expect(a.consistent, isTrue);
  });

  test('写入点·诊断一键修复：脏锚点按台账归位', () async {
    final p = ProgressService(db: AppDatabase(path: ':memory:'));
    await p.init();
    final level = _level('H', 4);
    await freshLevel(p, level);
    await _learn(p, 'hc0');
    await _learn(p, 'hc1');
    // 人为造旧锚点（模拟升级前留下的分歧数据）。
    await p.setLearnResume('H',
        const LearnResume(chunkIndex: 0, chunkId: 'hc0', phase: 0, stars: StarBoard.empty, savedAt: 1)
            .encode());
    final dirty = await ProgressIntegrity.audit(p, level);
    expect(dirty.staleSnapshot, isTrue, reason: '前置：应造出陈旧锚点');

    final healed = await ProgressIntegrity.heal(p, level, dirty);
    expect(healed.snapshotIndex, 2, reason: '一键修复=推进到首个未完成块');
    expect(healed.consistent, isTrue);
    expect(healed.staleSnapshot, isFalse, reason: '修复后不得再被判陈旧锚点');
  });
}

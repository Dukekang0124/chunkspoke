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
}

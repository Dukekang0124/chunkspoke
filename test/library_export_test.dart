import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/learning_export.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

Level _level() => Level(
      id: 'A',
      theme: 'Greetings',
      sceneImage: '',
      chunks: List.generate(
        3,
        (i) => Chunk.fromJson({
          'id': 'a$i',
          'text': 'chunk $i',
          'type': 'content',
          'meaningCN': '词块 $i',
        }),
      ),
    );

ContentPack _content() =>
    ContentPack(version: 'test', levels: [_level()]);

/// 六步全绿学完：关卡轴与资产轴都进入已掌握（资产需再走完 4 次复习档：1/3/7/14 天）。
Future<void> _learnAndMaster(ChunkProgressStore store, String id) async {
  await store.applyEvent(id, ChunkEvent.assembleCorrect);
  await store.applyEvent(id, ChunkEvent.dragCorrect);
  await store.applyEvent(id, ChunkEvent.accuracyPass, accuracy: 90);
  await store.applyEvent(id, ChunkEvent.speakSuccess,
      accuracy: 95, fourStarsGreen: true, enforceFourStars: true);
  // 四档全走一遍：+1d（首到期）→ +3d → +7d → +14d → 已掌握（指令 N 修订）
  for (var i = 0; i < 4; i++) {
    await store.applyEvent(id, ChunkEvent.speakSuccess,
        accuracy: 95, review: true);
  }
}

/// 只完成新学（资产停在已巩固，关卡轴已算掌握）。
Future<void> _learnOnly(ChunkProgressStore store, String id) async {
  await store.applyEvent(id, ChunkEvent.assembleCorrect);
  await store.applyEvent(id, ChunkEvent.dragCorrect);
  await store.applyEvent(id, ChunkEvent.accuracyPass, accuracy: 90);
  await store.applyEvent(id, ChunkEvent.speakSuccess,
      accuracy: 95, fourStarsGreen: true, enforceFourStars: true);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('W2-1：已掌握/已学完按资产轴计数，与旧关卡轴分叉', () async {
    final dir = await Directory.systemTemp.createTemp('w21_axis');
    final progress =
        ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
    await progress.init();
    final store = progress.chunkStore;
    await _learnAndMaster(store, 'a0');
    await _learnOnly(store, 'a1');

    // 旧关卡轴：两块都已掌握；新资产轴：只有 a0 走完复习阶梯。
    expect((await store.allMasteredKeys()).toSet(), {'a0', 'a1'});
    expect(await progress.chunksMastered(_content()), 1);
    expect(await progress.chunksLearned(_content()), 2);

    final rows = {for (final r in await store.allRows()) r.chunkKey: r};
    expect(rows['a0']!.assetState, ChunkAssetState.mastered);
    expect(rows['a1']!.assetState, ChunkAssetState.consolidated);
    expect(rows['a2'], isNull);
  });

  test('导出：资产分组、六步漏斗与复习保持率数值正确，且不含原文', () async {
    final dir = await Directory.systemTemp.createTemp('w2_export');
    final progress =
        ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
    await progress.init();
    final store = progress.chunkStore;
    await _learnAndMaster(store, 'a0');
    await _learnOnly(store, 'a1');
    // 1 次复习失败（已掌握块不降档，只计入保持率分母）。
    await store.applyEvent('a0', ChunkEvent.speakFail, review: true);

    final export = await buildLearningExport(
      progress: progress,
      content: _content(),
      now: DateTime(2026, 10, 22, 9, 5),
    );

    expect(export.filename, 'chunkspoke_learning_20261022-0905.txt');
    final t = export.text;
    expect(t, contains('已掌握 1'));
    expect(t, contains('巩固中 0'));
    expect(t, contains('已巩固 1'));
    expect(t, contains('新学 1'));
    expect(t, contains('已学完合计：2 / 3 块'));
    expect(t, contains('听辨完成：2'));
    expect(t, contains('影子跟读通过：2'));
    expect(t, contains('定向替换通过：2'));
    expect(t, contains('自由造句通过：2'));
    expect(t, contains('复习通过：4 次'));
    expect(t, contains('复习未通过：1 次'));
    expect(t, contains('保持率：80.0%'));
    expect(t, contains('会话事件合计：13 条'));
    // 只出聚合数字，不夹带任何词块原文。
    expect(t, isNot(contains('chunk 0')));
  });
}

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

ContentPack _content() => ContentPack(version: 'test', levels: [_level()]);

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
    final progress = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
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
    final progress = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
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

  test('导出：沙盒四项度量成段，口径＝本地统计（访问/句子/串联/搜索筛选）', () async {
    final dir = await Directory.systemTemp.createTemp('w2_export_sandbox');
    final progress = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
    await progress.init();
    final store = progress.chunkStore;
    await _learnAndMaster(store, 'a0');
    await _learnAndMaster(store, 'a1');

    // 没进过沙盒：四项都该是空态，不能编出 0% 的使用率。
    final cold = await buildLearningExport(
      progress: progress,
      content: _content(),
      now: DateTime(2026, 10, 22, 9, 5),
    );
    expect(cold.text, contains('沙盒访问：0 次'));
    expect(cold.text, contains('句子产出：0 句'));
    expect(cold.text, contains('串联使用：0 次'));
    expect(cold.text, contains('搜索使用：—（还没进过沙盒）'));

    final byId = {for (final c in _content().levels.first.chunks) c.id: c};
    final mastered = {'a0', 'a1'};
    await progress.sandbox.recordVisit();
    await progress.sandbox.recordVisit();
    await progress.sandbox.recordSearch();
    // 一句含 2 个已掌握块 → 串联；一句只含 1 个新块 → 普通。
    await progress.sandbox.addSentence([byId['a0']!, byId['a1']!], mastered);
    await progress.sandbox.addSentence([byId['a2']!], mastered);

    final export = await buildLearningExport(
      progress: progress,
      content: _content(),
      now: DateTime(2026, 10, 22, 9, 6),
    );
    final t = export.text;
    expect(t, contains('六、沙盒（自由造句）'));
    expect(t, contains('沙盒访问：2 次'));
    expect(t, contains('句子产出：2 句（通过校验才入库）'));
    expect(t, contains('串联使用：1 次（一句含 ≥2 个不同已掌握块）'));
    expect(t, contains('搜索使用：1 / 2 次访问（50%）'));
    expect(t, contains('筛选使用：0 / 2 次访问（0%）'));
    // 沙盒句子同样只报计数，不导出用户句子原文。
    expect(t, isNot(contains('Chunk 0')));
    expect(t, contains('七、事件总量（校验用）'));
  });

  test('导出：浸泡段落按本周实际秒数/完听/收词出数，不计入会话轴', () async {
    final dir = await Directory.systemTemp.createTemp('w2_export_listen');
    final progress = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
    await progress.init();

    // 周三 2026-10-22；本周从周一 10-19 起算。
    await progress.listening.addSeconds(150, at: DateTime(2026, 10, 19, 20));
    await progress.listening.addSeconds(90, at: DateTime(2026, 10, 22, 8));
    await progress.listening.addSeconds(60, at: DateTime(2026, 10, 18, 20));
    await progress.listening.markCompleted('art_a', at: DateTime(2026, 10, 20));
    await progress.listening.markCompleted('art_b', at: DateTime(2026, 10, 18));
    await progress.listening.markCollected('lx_a', 'art_a',
        at: DateTime(2026, 10, 21));
    await progress.listening.markSixStarted('lx_a');
    await progress.listening.markConverted('lx_a');
    await progress.listening.markWish('art_a', 'oat milk');

    final export = await buildLearningExport(
      progress: progress,
      content: _content(),
      now: DateTime(2026, 10, 22, 9, 5),
    );
    final t = export.text;
    expect(t, contains('五、浸泡（磨耳朵）'));
    expect(t, contains('本周浸泡：4 分钟（实际播放秒数，暂停不计）'));
    expect(t, contains('本周完听：1 篇'));
    expect(t, contains('收词：1 块（累计，按块去重）'));
    expect(t, contains('收词后开始六步：1 块'));
    expect(t, contains('收词后完成六步：1 块（推动率 100.0%）'));
    expect(t, contains('候选块想学：1 条（文章 + 块文本，按篇去重；不建词块）'));
    // 浸泡不产出资产、不进会话轴：资产全为新学、事件合计为 0。
    expect(t, contains('新学 3'));
    expect(t, contains('会话事件合计：0 条'));
  });

  test('导出：讲解版模式切换/完听/跳过与两模式占比，分母为 0 时不编数', () async {
    final dir = await Directory.systemTemp.createTemp('w2_export_expl');
    final progress = ProgressService(db: AppDatabase(path: '${dir.path}/t.db'));
    await progress.init();

    final cold = await buildLearningExport(
      progress: progress,
      content: _content(),
      now: DateTime(2026, 10, 22, 9, 5),
    );
    expect(cold.text, contains('模式切换：原版→讲解版 0 次 · 讲解版→原版 0 次（累计）'));
    expect(
        cold.text,
        contains('讲解段：开始 0 段 · 完听 0 段 · 跳过 0 段'
            '（完听率 — · 跳过率 —）'));
    expect(cold.text, contains('（讲解占比 —，累计实际播放秒数）'));

    await progress.logEvent('listen_mode_switch', {'mode': 'explained'});
    await progress.logEvent('listen_mode_switch', {'mode': 'explained'});
    await progress.logEvent('listen_mode_switch', {'mode': 'original'});
    for (var i = 0; i < 4; i++) {
      await progress.logEvent('listen_expl_start', {'sentence': i});
    }
    for (var i = 0; i < 3; i++) {
      await progress.logEvent('listen_expl_complete', {'sentence': i});
    }
    await progress.logEvent('listen_expl_skip', {'reason': 'user'});
    await progress.listening.addModeSeconds('o', 120);
    await progress.listening.addModeSeconds('x', 60);

    final export = await buildLearningExport(
      progress: progress,
      content: _content(),
      now: DateTime(2026, 10, 22, 9, 6),
    );
    final t = export.text;
    expect(t, contains('模式切换：原版→讲解版 2 次 · 讲解版→原版 1 次（累计）'));
    expect(t, contains('讲解段：开始 4 段 · 完听 3 段 · 跳过 1 段'
        '（完听率 75.0% · 跳过率 25.0%）'));
    expect(t, contains('两模式播放：原版 2 分钟 · 讲解版 1 分钟'
        '（讲解占比 33.3%，累计实际播放秒数）'));
    // 讲解版只是呈现模式：仍不产出资产、不进会话轴。
    expect(t, contains('新学 3'));
    expect(t, contains('会话事件合计：0 条'));
  });

  test('导出头部版本号与 pubspec 同 bump（漏改即红）', () async {
    final pubspec = await File('pubspec.yaml').readAsString();
    final m = RegExp(r'^version:\s*([0-9.]+)\+(\d+)\s*$', multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 里没有 version: X+Y 行');
    expect(kExportAppVersion, m!.group(1),
        reason: '导出头部版本落后于 pubspec，发版时忘了同 bump');
  });
}

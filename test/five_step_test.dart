import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/session.dart';
import 'package:chunkspoke_flutter/steps/practice_loop.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';

int _dbCounter = 0;

Chunk _chunk(String id, String text) =>
    Chunk.fromJson({'id': id, 'text': text, 'type': 'content', 'meaningCN': text});

/// 走完一个块的 happy path → mastered（l2OneTry=1 且 accuracy≥80）。
Future<void> _master(ChunkProgressStore store, String key) async {
  await store.applyEvent(key, ChunkEvent.assembleCorrect);
  await store.applyEvent(key, ChunkEvent.dragCorrect);
  await store.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 90);
  await store.applyEvent(key, ChunkEvent.speakSuccess, accuracy: 95);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('五步状态机（纯函数）', () {
    test('新学：①→②→③→④→结算', () {
      expect(phaseOrder(reviewMode: false), [0, 1, 2, 3]);
      expect(nextPhase(0, reviewMode: false), 1);
      expect(nextPhase(1, reviewMode: false), 2);
      expect(nextPhase(2, reviewMode: false), 3);
      expect(nextPhase(3, reviewMode: false), -1); // -1 = 结算掌握
    });
    test('复习：②→④→结算（跳过听辨块与块拼句）', () {
      expect(phaseOrder(reviewMode: true), [1, 3]);
      expect(nextPhase(1, reviewMode: true), 3);
      expect(nextPhase(3, reviewMode: true), -1);
    });
  });

  group('每日会话计划 dailyPlan', () {
    test('新块 ≤6、复习 ≤6', () {
      final due = List.generate(9, (i) => _chunk('d$i', 'due $i'));
      final news = List.generate(9, (i) => _chunk('n$i', 'new $i'));
      final plan = PracticeSession.dailyPlan(dueChunks: due, newChunks: news);
      expect(plan.newChunks.length, 6);
      expect(plan.reviewChunks.length, 6);
      expect(plan.total, 12);
    });
  });

  group('复习合成场景 reviewLevel', () {
    test('每个复习块映射到包含它的目标句（否则回退自身）', () {
      final c1 = _chunk('a01', 'Good morning');
      final c2 = _chunk('a11', 'everyone');
      final c3 = _chunk('z', 'lonely');
      final lv = Level(
        id: 'A',
        theme: 'Greetings',
        sceneImage: '',
        chunks: [c1, c2, c3],
        sentences: [
          TargetSentence(
              id: 's1',
              text: 'Good morning everyone',
              meaningCN: '大家早上好',
              chunkIds: ['a01', 'a11']),
        ],
      );
      final pack = ContentPack(version: '1.2.2', levels: [lv]);
      final rl = PracticeSession.reviewLevel(pack, [c1, c3]);
      expect(rl.chunks.length, 2);
      expect(rl.sentences[0].text, 'Good morning everyone'); // c1 命中目标句
      expect(rl.sentences[1].text, 'lonely'); // c3 无句 → 回退自身
    });
  });

  group('断点续练锁定（完成 2 块 → 从第 3 块）', () {
    test('退出重进仍从第 3 块开始（同路径重开）', () async {
      _dbCounter++;
      final p = '${Directory.systemTemp.path}/five_step_resume_$_dbCounter.db';
      final f = File(p);
      if (f.existsSync()) f.deleteSync();

      final db1 = AppDatabase(path: p);
      await db1.db;
      final s1 = ChunkProgressStore(db1);
      final keys = ['a', 'b', 'c', 'd', 'e'];
      await _master(s1, 'a');
      await _master(s1, 'b');
      expect(await s1.nextUnmasteredIndex(keys), 2); // 完成 2 块 → 第 3 块

      // 杀进程重开：关闭原连接，用同路径新实例读取。
      await (await db1.db).close();
      final db2 = AppDatabase(path: p);
      await db2.db;
      final s2 = ChunkProgressStore(db2);
      expect(await s2.nextUnmasteredIndex(keys), 2); // 仍从第 3 块
      expect((await s2.allMasteredKeys()).length, 2);
    });
  });
}

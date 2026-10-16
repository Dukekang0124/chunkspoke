import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/chunk_progress.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

/// 走完一个词块的四环节 → mastered。
Future<void> masterChunk(ChunkProgressStore store, String key) async {
  await store.applyEvent(key, ChunkEvent.assembleCorrect); // ① 听辨点选
  await store.applyEvent(key, ChunkEvent.dragCorrect); // ② 造句（L2 一次过闸）
  await store.applyEvent(key, ChunkEvent.accuracyPass, accuracy: 80); // ③ 照读
  await store.applyEvent(key, ChunkEvent.speakSuccess, accuracy: 90); // ④ 开口
}

void main() {
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  test('断点续练：完成 2 块退出重进，必须从第 3 块开始', () async {
    final path =
        '${Directory.systemTemp.path}/chunkspoke_resume_${DateTime.now().microsecondsSinceEpoch}.db';
    final keys = ['c1', 'c2', 'c3', 'c4', 'c5'];

    // 会话 1：完成前 2 块（每块完成即落盘）。
    final store = ChunkProgressStore(AppDatabase(path: path));
    expect(await store.nextUnmasteredIndex(keys), 0); // 全新 → 第 1 块
    await masterChunk(store, 'c1');
    expect(await store.nextUnmasteredIndex(keys), 1); // 1 块完成 → 第 2 块
    await masterChunk(store, 'c2');
    expect(await store.nextUnmasteredIndex(keys), 2); // 2 块完成 → 第 3 块

    // 会话 2：模拟退出重进（新开数据库连接读同一落盘文件）。
    final store2 = ChunkProgressStore(AppDatabase(path: path));
    expect(await store2.nextUnmasteredIndex(keys), 2,
        reason: '完成 2 块后重进必须从第 3 块（index 2）开始，禁止从头');
    expect(ChunkProgressStore.isMastered(await store2.get('c1')), isTrue);
    expect(ChunkProgressStore.isMastered(await store2.get('c2')), isTrue);
  });

  test('每完成 1 块立即落盘（不依赖整场景/每 5 块）', () async {
    final path =
        '${Directory.systemTemp.path}/chunkspoke_resume_${DateTime.now().microsecondsSinceEpoch}.db';
    final keys = ['c1', 'c2', 'c3'];

    final store = ChunkProgressStore(AppDatabase(path: path));
    await masterChunk(store, 'c1');
    // 仅完成 1 块即新开连接读取，进度必须在。
    final store2 = ChunkProgressStore(AppDatabase(path: path));
    expect(ChunkProgressStore.isMastered(await store2.get('c1')), isTrue);
    expect(await store2.nextUnmasteredIndex(keys), 1);
  });
}

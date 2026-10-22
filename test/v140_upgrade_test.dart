import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/session.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/session_report.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/ui/motion.dart';

Chunk _c(String id) => Chunk(
    id: id,
    text: id,
    type: 'content',
    meaningCN: id,
    sentence: ChunkSentence(
        text: id,
        slots: [],
        coreWords: [],
        swapSlotIndex: 0,
        swapOptions: []));

int _dbCounter = 0;
AppDatabase _newDb() {
  final p = '${Directory.systemTemp.path}/v140_test_${_dbCounter++}.db';
  final f = File(p);
  if (f.existsSync()) f.deleteSync();
  return AppDatabase(path: p);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('A1 解锁阈值', () {
    test('累计掌握 ≥10 解锁自由造句沙盒', () {
      expect(freeBuildUnlocked(9), isFalse);
      expect(freeBuildUnlocked(10), isTrue);
      expect(freeBuildUnlocked(25), isTrue);
      expect(kFreeBuildUnlockLearned, 10);
    });
  });

  group('A3 会话构成', () {
    final all = List.generate(12, (i) => _c('c$i'));
    test('dailyPlan 新块 ≤6 且复习 ≤6', () {
      final due = all.take(8).toList();
      final plan = PracticeSession.dailyPlan(dueChunks: due, newChunks: all);
      expect(plan.newChunks.length, lessThanOrEqualTo(6));
      expect(plan.reviewChunks.length, lessThanOrEqualTo(6));
    });
    test('buildPlan 复习优先', () {
      final due = all.take(3).toList();
      final plan = PracticeSession.buildPlan(due, all);
      expect(plan.length, 3);
      expect(plan.first.id, 'c0');
    });
  });

  group('A2 口径 + A4 里程碑 + A0 兼容', () {
    test('平均准确度 = 文本匹配相似度（recordScore 落盘）', () async {
      final ps = ProgressService(db: _newDb());
      await ps.init();
      await ps.recordScore(90);
      await ps.recordScore(80);
      expect(ps.avgScore, 85.0);
    });

    test('今日开口 = noteSpoken 累加', () async {
      final ps = ProgressService(db: _newDb());
      await ps.init();
      await ps.noteSpoken();
      await ps.noteSpoken();
      expect(ps.todaySpoken, 2);
    });

    test('里程碑 10/25/50/100 且庆祝后不再重复', () async {
      final db = _newDb();
      final ps = ProgressService(db: db);
      await ps.init(); // 空库 init（reset 无数据，不影响后续插入）
      final d = await db.db;
      for (var i = 0; i < 30; i++) {
        await d.insert('chunks', {
          'chunk_key': 'm$i',
          'level': ChunkLevel.mastered.index,
          'due_date': 0,
          'fail_count': 0,
          'last_score': 90,
          'asset_state': ChunkAssetState.mastered.index,
        });
      }
      expect(await ps.pendingMilestone(), 10);
      await ps.markMilestoneCelebrated(10);
      expect(await ps.pendingMilestone(), 25);
      await ps.markMilestoneCelebrated(25);
      expect(await ps.pendingMilestone(), isNull); // 30 块未到 50
    });

    test('W2-1：里程碑只认资产轴，旧关卡轴不再触发', () async {
      final db = _newDb();
      final ps = ProgressService(db: db);
      await ps.init();
      final d = await db.db;
      for (var i = 0; i < 60; i++) {
        await d.insert('chunks', {
          'chunk_key': 'legacy$i',
          'level': ChunkLevel.mastered.index,
          'due_date': 0,
          'fail_count': 0,
          'last_score': 90,
          'asset_state': ChunkAssetState.learning.index,
        });
      }
      expect(await ps.pendingMilestone(), isNull);
    });

    test('A0 升级兼容：连击/自由造句/掌握块/准确度全部无损', () async {
      final db = _newDb();
      final d = await db.db;
      // 预置 v1.3.1 存量用户数据（dataVersion 已是 1.1.0）。
      await d.insert('kv', {'key': 'dataVersion', 'value': '1.1.0'});
      await d.insert('kv', {'key': 'streak', 'value': '3'});
      await d.insert('kv', {'key': 'freeBuildCount', 'value': '5'});
      await d.insert('kv', {'key': 'scores', 'value': '[90,85]'});
      await d.insert('chunks', {
        'chunk_key': 'k1',
        'level': ChunkLevel.mastered.index,
        'due_date': 0,
        'fail_count': 0,
        'last_score': 92,
      });
      final ps = ProgressService(db: db);
      await ps.init(); // 触发 ensureMigrated + _migrateSchema
      expect(ps.streak, 3);
      expect(ps.freeBuildCount, 5);
      expect(ps.avgScore, 87.5);
      expect(await ps.chunkStore.allMasteredKeys(), contains('k1'));
    });
  });

  group('B6 战报字段', () {
    test('SessionReport 字段真实可构造', () {
      const r =
          SessionReport(newMastered: 2, spoken: 4, maxCombo: 3, reviewed: 5);
      expect(r.newMastered, 2);
      expect(r.spoken, 4);
      expect(r.maxCombo, 3);
      expect(r.reviewed, 5);
    });
  });

  group('B7 降级策略', () {
    test('正常：满粒子 + 开震 + 开彩带', () {
      const p = MotionPolicy();
      expect(p.reduce, isFalse);
      expect(p.particles(60), 60);
      expect(p.hapticsOn, isTrue);
      expect(p.confettiOn, isTrue);
    });
    test('省电：粒子减半 + 关屏震', () {
      const p = MotionPolicy(lowPower: true);
      expect(p.reduce, isTrue);
      expect(p.particles(60), 30);
      expect(p.hapticsOn, isFalse);
    });
    test('减弱动画：关彩带 + 粒子减半', () {
      const p = MotionPolicy(reduceMotion: true);
      expect(p.reduce, isTrue);
      expect(p.confettiOn, isFalse);
      expect(p.particles(60), 30);
    });
  });
}

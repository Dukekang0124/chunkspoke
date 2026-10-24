import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/listening_store.dart';

void main() {
  late Map<String, String> kv;
  late DateTime now;
  late ListeningStore store;

  setUp(() {
    kv = {};
    now = DateTime(2026, 10, 23, 9);
    store = ListeningStore(
      read: (k) => kv[k],
      write: (k, v) async => kv[k] = v,
      clock: () => now,
    );
  });

  group('浸泡时长', () {
    test('累计秒数与按日分桶；非正值忽略', () async {
      await store.addSeconds(90);
      now = now.add(const Duration(days: 1));
      await store.addSeconds(30);
      await store.addSeconds(0);
      await store.addSeconds(-5);
      expect(store.totalSeconds, 120);
      expect(store.secondsByDay, {'2026-10-23': 90, '2026-10-24': 30});
    });

    test('只保留最近 30 天日桶，总时长不丢', () async {
      for (var i = 0; i < 35; i++) {
        now = DateTime(2026, 8, 1).add(Duration(days: i));
        await store.addSeconds(10);
      }
      expect(store.secondsByDay.length, 30);
      expect(store.totalSeconds, 350);
    });
  });

  group('续播点', () {
    test('按篇存取，lastHeard 取最近', () async {
      await store.savePosition('L01', 12000, 3);
      now = now.add(const Duration(minutes: 5));
      await store.savePosition('L02', 4000, 1);
      expect(store.positionFor('L01')!.positionMs, 12000);
      expect(store.positionFor('L02')!.sentenceIndex, 1);
      expect(store.lastHeardArticleId, 'L02');
      expect(store.lastHeardAt('L01'), isNotNull);
    });

    test('脏数据不炸', () {
      kv[ListeningStore.kPositions] = '{bad';
      expect(store.positionFor('L01'), isNull);
      expect(store.lastHeardArticleId, isNull);
    });

    test('lastListenedAt 取续播点与完听的较晚时间', () async {
      await store.savePosition('L01', 1000, 0);
      now = now.add(const Duration(hours: 1));
      await store.markCompleted('L01');
      now = now.add(const Duration(hours: 1));
      await store.savePosition('L02', 2000, 1);
      final map = store.lastListenedAt;
      expect(map['L01'], DateTime(2026, 10, 23, 10).millisecondsSinceEpoch);
      expect(map['L02'], DateTime(2026, 10, 23, 11).millisecondsSinceEpoch);
    });
  });

  group('收词与推动率', () {
    test('收词按块去重；推动率只认已收词且完成六步', () async {
      expect(await store.markCollected('lx_food_oat_milk', 'L01'), isTrue);
      expect(await store.markCollected('lx_food_oat_milk', 'L01'), isFalse);
      await store.markCollected('lx_food_no_ice', 'L03');
      expect(store.stats.collected, 2);

      // 未收词的完成不算转化
      expect(await store.markConverted('c01'), isFalse);
      expect(await store.markConverted('lx_food_oat_milk'), isTrue);
      expect(await store.markConverted('lx_food_oat_milk'), isFalse);
      expect(store.stats.converted, 1);
      expect(store.stats.conversionRate, 0.5);
    });

    test('无收词时转化率为 null（UI 展示「—」）', () {
      expect(store.stats.conversionRate, isNull);
    });

    test('收词记录保留来源篇目', () async {
      store.markCollected('lx_work_a_badge', 'L07');
      expect(store.collected.single.articleId, 'L07');
    });

    test('本篇收词计数按块去重，跨篇不串名额', () async {
      await store.markCollected('c01', 'L01');
      await store.markCollected('c01', 'L01');
      await store.markCollected('c02', 'L01');
      await store.markCollected('c03', 'L02');
      expect(store.collectedCountFor('L01'), 2);
      expect(store.collectedCountFor('L02'), 1);
      expect(store.isCollectedIn('c01', 'L01'), isTrue);
      expect(store.isCollectedIn('c01', 'L02'), isFalse);
    });

    test('六步开始按已收词块去重，完成推动率单独计数', () async {
      await store.markCollected('c01', 'L01');
      await store.markCollected('c02', 'L01');
      // 未收词的开始请求不计数。
      expect(await store.markSixStarted('c03'), isFalse);
      expect(await store.markSixStarted('c01'), isTrue);
      expect(await store.markSixStarted('c01'), isFalse);
      expect(store.stats.sixStarted, 1);
      expect(await store.markConverted('c01'), isTrue);
      expect(store.stats.sixStarted, 1);
      expect(store.stats.converted, 1);
      expect(store.stats.conversionRate, 0.5);
    });
  });

  group('候选块意愿', () {
    test('只记文章+文本，按篇去重；不产生收词/学习计数', () async {
      expect(await store.markWish('L01', 'oat milk'), isTrue);
      expect(await store.markWish('L01', 'oat milk'), isFalse);
      expect(await store.markWish('L02', 'oat milk'), isTrue);
      expect(store.wishCount('L01', 'oat milk'), 1);
      expect(store.isWished('L02', 'oat milk'), isTrue);
      expect(store.totalWishes, 2);
      expect(store.stats.wishes, 2);
      expect(store.stats.collected, 0);
      expect(store.stats.sixStarted, 0);
      expect(store.stats.converted, 0);
    });

    test('空文章/空文本拒绝落账', () async {
      expect(await store.markWish('', 'oat milk'), isFalse);
      expect(await store.markWish('L01', '  '), isFalse);
      expect(store.totalWishes, 0);
    });

    test('脏数据不炸', () {
      kv[ListeningStore.kCandidateWishes] = '{bad';
      expect(store.candidateWishes, isEmpty);
      expect(store.totalWishes, 0);
    });
  });

  group('完听与本周汇总', () {
    test('完听按篇去重，重听只更新时间不重复计数', () async {
      await store.markCompleted('L01');
      expect(store.completedCount, 1);
      expect(store.isCompleted('L01'), isTrue);
      now = now.add(const Duration(hours: 2));
      await store.markCompleted('L01');
      expect(store.completedCount, 1);
      expect(store.completedSince(DateTime(2026, 10, 23).millisecondsSinceEpoch),
          1);
    });

    test('completedSince 只数区间内的篇目', () async {
      await store.markCompleted('L01', at: DateTime(2026, 10, 18, 23));
      await store.markCompleted('L02', at: DateTime(2026, 10, 20, 8));
      final weekStart = DateTime(2026, 10, 19).millisecondsSinceEpoch;
      expect(store.completedSince(weekStart), 1);
    });

    test('secondsSince 按自然日边界汇总', () async {
      await store.addSeconds(100, at: DateTime(2026, 10, 19, 8));
      await store.addSeconds(50, at: DateTime(2026, 10, 18, 23));
      expect(store.secondsSince(DateTime(2026, 10, 19)), 100);
      expect(store.secondsSince(DateTime(2026, 10, 18)), 150);
    });

    test('脏数据不炸', () {
      kv[ListeningStore.kCompleted] = '{bad';
      expect(store.completedCount, 0);
      expect(store.isCompleted('L01'), isFalse);
    });
  });

  group('重逢', () {
    test('按篇累计并汇总', () async {
      await store.markReunion('L01');
      await store.markReunion('L01');
      await store.markReunion('L04');
      expect(store.reunionsFor('L01'), 2);
      expect(store.totalReunions(), 3);
      expect(store.stats.reunions, 3);
    });
  });

  test('统计口径整体联动', () async {
    await store.addSeconds(60);
    await store.savePosition('L01', 1000, 0);
    await store.markCollected('lx_food_oat_milk', 'L01');
    await store.markConverted('lx_food_oat_milk');
    await store.markReunion('L01');
    final s = store.stats;
    expect(s.totalSeconds, 60);
    expect(s.collected, 1);
    expect(s.converted, 1);
    expect(s.reunions, 1);
    expect(s.articlesHeard, 1);
  });

  group('磨耳朵 2.0 偏好（指令 S）', () {
    test('今日浸泡只认当天日桶，不受历史天数影响', () async {
      await store.addSeconds(120);
      now = now.add(const Duration(days: 1));
      await store.addSeconds(60);
      expect(store.todaySeconds, 60);
      expect(store.totalSeconds, 180);
    });

    test('变速按级别记忆：不跨级串味，重复设置取最后一次', () async {
      expect(store.speedOverrideFor('A1'), isNull);
      await store.setSpeedOverride('A1', 1.0);
      expect(store.speedOverrideFor('A1'), 1.0);
      expect(store.speedOverrideFor('C1'), isNull, reason: 'A1 的选择不该带到 C1');
      await store.setSpeedOverride('A1', 1.25);
      expect(store.speedOverrideFor('A1'), 1.25);
    });

    test('译文默认开；关掉后重开仍保持', () async {
      expect(store.showTranslation, isTrue);
      await store.setShowTranslation(false);
      expect(store.showTranslation, isFalse);
      final reopened = ListeningStore(
        read: (k) => kv[k],
        write: (k, v) async => kv[k] = v,
        clock: () => now,
      );
      expect(reopened.showTranslation, isFalse);
      await reopened.setShowTranslation(true);
      expect(reopened.showTranslation, isTrue);
    });
  });

  group('讲解版（指令 S+）', () {
    test('模式偏好默认原版，切换后跨实例保持', () async {
      expect(store.explainMode, isFalse);
      await store.setExplainMode(true);
      expect(store.explainMode, isTrue);
      final reopened = ListeningStore(
        read: (k) => kv[k],
        write: (k, v) async => kv[k] = v,
        clock: () => now,
      );
      expect(reopened.explainMode, isTrue);
      await reopened.setExplainMode(false);
      expect(store.explainMode, isFalse);
    });

    test('首遇记忆：去重、跨实例保留、超 1000 条只留最近', () async {
      expect(store.explainedKeys, isEmpty);
      await store.markExplained(['i:c01', 't:oat milk', 'i:c01']);
      expect(store.explainedKeys, {'i:c01', 't:oat milk'});

      await store.setExplainMode(true);
      final reopened = ListeningStore(
        read: (k) => kv[k],
        write: (k, v) async => kv[k] = v,
        clock: () => now,
      );
      expect(reopened.explainedKeys, containsAll(['i:c01', 't:oat milk']));

      await reopened.markExplained(
          [for (var i = 0; i < 1200; i++) 'i:k$i']);
      final keys = reopened.explainedKeys;
      expect(keys.length, ListeningStore.kMaxExplainedEntries);
      expect(keys, isNot(contains('i:c01')));
      expect(keys, contains('i:k1199'));
    });

    test('两模式秒数只认 o/x 且忽略非正值；脏数据不炸', () async {
      await store.addModeSeconds('o', 30);
      await store.addModeSeconds('x', 20);
      await store.addModeSeconds('x', 10);
      await store.addModeSeconds('z', 99);
      await store.addModeSeconds('o', 0);
      await store.addModeSeconds('o', -5);
      expect(store.modeSeconds, {'o': 30, 'x': 30});

      kv[ListeningStore.kModeSeconds] = '{bad';
      expect(store.modeSeconds, isEmpty);
      await store.addModeSeconds('x', 5);
      expect(store.modeSeconds, {'x': 5});
    });

    test('续播点带模式：跨模式只信句索引，旧数据默认原版', () async {
      await store.savePosition('L01', 4200, 3, mode: 'x');
      final p = store.positionFor('L01')!;
      expect(p.mode, 'x');
      expect(p.sentenceIndex, 3);
      expect(p.positionMs, 4200);

      await store.savePosition('L01', 1000, 1);
      expect(store.positionFor('L01')!.mode, 'o');

      await store.savePosition('L01', 2000, 2, mode: 'Z');
      expect(store.positionFor('L01')!.mode, 'o');

      // 旧版本写入的续播点没有 m 字段。
      kv[ListeningStore.kPositions] =
          '{"L02":{"ms":800,"i":0,"ts":1}}';
      expect(store.positionFor('L02')!.mode, 'o');
    });
  });
}

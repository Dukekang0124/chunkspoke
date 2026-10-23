import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/listening_home.dart';
import 'package:chunkspoke_flutter/services/listening_store.dart';

ListeningArticle _article(
  String id,
  String scene,
  String label,
  int updatedDay, {
  List<String> chunks = const [],
}) =>
    ListeningArticle(
      id: id,
      title: 'Article $id',
      scene: scene,
      sceneLabel: label,
      summaryCN: '摘要 $id',
      updatedAt: '2026-10-${updatedDay.toString().padLeft(2, '0')}',
      audioUrl: '',
      collectLimit: 8,
      sentences: [
        ListeningSentence(
          id: 's_$id',
          text: 'hello world',
          meaningCN: '你好世界',
          chunks: [
            for (final c in chunks)
              ListeningChunk(id: c, text: 'hello', meaningCN: '你好'),
          ],
        ),
      ],
    );

ListeningPosition _pos(int ms, int idx, DateTime at) => ListeningPosition(
      positionMs: ms,
      sentenceIndex: idx,
      updatedAt: at.millisecondsSinceEpoch,
    );

void main() {
  final now = DateTime(2026, 10, 23, 9);
  final articles = [
    _article('L01', 'food', '点餐', 23, chunks: ['c01']),
    _article('L02', 'food', '点餐', 22, chunks: ['c02']),
    _article('L03', 'airport', '机场', 21, chunks: ['c03']),
    _article('L04', 'work', '职场', 20),
    _article('L05', 'hospital', '医院', 19),
  ];

  ListeningHomeData build({
    Map<String, int>? listened,
    Map<String, ListeningPosition>? positions,
    Set<String> completed = const {},
    Set<String> learned = const {},
    int due = 0,
    DateTime? at,
  }) =>
      buildListeningHome(
        articles: articles,
        lastListenedAt: listened ?? const {},
        positions: positions ?? const {},
        completedIds: completed,
        learnedChunkIds: learned,
        now: at ?? now,
        dueReviews: due,
      );

  group('最近 7 天推荐', () {
    test('三张卡：今日篇目 / 昨天听过 / 隔天重逢，且同一天稳定', () {
      final listened = {
        'L02': DateTime(2026, 10, 22, 20).millisecondsSinceEpoch,
        'L03': DateTime(2026, 10, 21, 21).millisecondsSinceEpoch,
        'L04': DateTime(2026, 10, 23, 8).millisecondsSinceEpoch,
      };
      final a = build(listened: listened, learned: {'c03'});
      final b = build(listened: listened, learned: {'c03'});

      expect(a.picks.map((p) => p.kind).toList(), [
        ListeningPickKind.today,
        ListeningPickKind.yesterday,
        ListeningPickKind.reunion,
      ]);
      expect(a.picks[1].article.id, 'L02');
      expect(a.picks[2].article.id, 'L03');
      expect(a.picks[2].hint, '含 1 个已学词块');
      expect(a.picks[0].article.id, b.picks[0].article.id, reason: '同一天应稳定');
      expect({'L02', 'L03', 'L04'}, isNot(contains(a.picks[0].article.id)));
    });

    test('昨日未听不硬凑；昨日篇目不被重复算作隔天重逢', () {
      final data = build(
        listened: {
          'L01': DateTime(2026, 10, 22, 19).millisecondsSinceEpoch,
        },
        learned: {'c01'},
      );
      expect(data.picks.map((p) => p.kind).toList(), [
        ListeningPickKind.today,
        ListeningPickKind.yesterday,
      ]);
      expect(data.picks[1].article.id, 'L01');
      expect(data.picks.any((p) => p.kind == ListeningPickKind.reunion),
          isFalse);
    });
  });

  group('继续听', () {
    test('取最近一次已开始的续播点；跳未开始的篇目', () {
      final data = build(positions: {
        'L01': _pos(5000, 2, DateTime(2026, 10, 23, 10)),
        'L02': _pos(0, 0, DateTime(2026, 10, 23, 11)),
        'L03': _pos(0, 3, DateTime(2026, 10, 23, 12)),
      }, completed: {'L03'});
      expect(data.resume, isNotNull);
      expect(data.resume!.article.id, 'L03');
      expect(data.resume!.sentenceIndex, 3);
      expect(data.resume!.completed, isTrue);
    });

    test('无续播点时不显示卡片', () {
      expect(build().resume, isNull);
    });
  });

  group('全部篇目', () {
    test('最近更新降序；场景分组保持首现顺序并带可读标签', () {
      final data = build();
      expect(data.recent.map((a) => a.id).toList(), [
        'L01',
        'L02',
        'L03',
        'L04',
        'L05',
      ]);
      expect(data.scenes.map((g) => g.scene).toList(), [
        'food',
        'airport',
        'work',
        'hospital',
      ]);
      expect(data.scenes.first.label, '点餐');
      expect(data.scenes.first.articles.length, 2);
    });

    test('全部篇目听过才算无新内容日，并带到期复习数', () {
      final partial = build(listened: {
        'L01': now.millisecondsSinceEpoch,
        'L02': now.millisecondsSinceEpoch,
      }, due: 3);
      expect(partial.noNewContent, isFalse);
      expect(partial.dueReviews, 3);

      final all = build(listened: {
        for (final a in articles) a.id: now.millisecondsSinceEpoch,
      }, due: 4);
      expect(all.noNewContent, isTrue);
      expect(all.dueReviews, 4);
    });
  });

  group('红线', () {
    test('首页源码无 Day N、无百分比文案、无付费入口', () {
      final src = File('lib/screens/listening_home_screen.dart')
          .readAsStringSync();
      expect(
          RegExp(r'\bday\s*\d+', caseSensitive: false).hasMatch(src), isFalse);
      expect(RegExp(r'第\s*\d+\s*天').hasMatch(src), isFalse);
      expect(RegExp(r'''(['"])[^'"\n]*%[^'"\n]*\1''').hasMatch(src), isFalse);
      expect(RegExp(r'会员|付费|订阅|购买').hasMatch(src), isFalse);

      expect(src.contains('最近 7 天推荐'), isTrue);
      expect(src.contains('继续听'), isTrue);
      expect(src.contains('最近更新'), isTrue);
      expect(src.contains('按场景'), isTrue);
      expect(src.contains('词块库待复习'), isTrue);
    });
  });
}

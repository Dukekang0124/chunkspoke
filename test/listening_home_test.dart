import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/listening_home.dart';
import 'package:chunkspoke_flutter/services/listening_player.dart';
import 'package:chunkspoke_flutter/services/listening_store.dart';

ListeningArticle _article(
  String id,
  String scene,
  String label,
  int updatedDay, {
  List<String> chunks = const [],
  ListeningLevel level = ListeningLevel.b1,
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
      levelRaw: level.key,
      level: level,
      baseRate: level.baseRate,
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

ListeningStore _storeWith(Map<String, double> overrides) {
  final kv = <String, String>{
    if (overrides.isNotEmpty)
      'listen_speed_overrides': jsonEncode(overrides),
  };
  return ListeningStore(
    read: (k) => kv[k],
    write: (k, v) async => kv[k] = v,
    clock: () => DateTime(2026, 10, 23, 9),
  );
}

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
    Set<String> mastered = const {},
    Set<String> dueChunkIds = const {},
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
        masteredChunkIds: mastered,
        dueChunkIds: dueChunkIds,
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
      // 指令 S 新增文案在此登记，避免悄悄引入越线口径
      for (final label in [
        '今日复习播单',
        '个到期块',
        '今日浸泡 ',
        '按级别',
        '全部',
      ]) {
        expect(src, contains(label), reason: '首页新增文案需登记：$label');
      }
    });
  });

  group('磨耳朵 2.0 · 分级与联动（指令 S）', () {
    final graded = [
      _article('G01', 'greet', '打招呼', 23,
          chunks: ['a01', 'a04'], level: ListeningLevel.a1),
      _article('G02', 'direction', '问路', 22,
          chunks: ['h01', 'h02'], level: ListeningLevel.a1),
      _article('G03', 'work', '职场', 21,
          chunks: ['c01', 'c02', 'c03'], level: ListeningLevel.b1),
      _article('G04', 'radio', '电台', 20,
          chunks: ['m01'], level: ListeningLevel.c1),
    ];

    ListeningHomeData buildG({
      Set<String> mastered = const {},
      Set<String> dueChunkIds = const {},
    }) =>
        buildListeningHome(
          articles: graded,
          lastListenedAt: const {},
          positions: const {},
          completedIds: const {},
          learnedChunkIds: const {},
          now: now,
          masteredChunkIds: mastered,
          dueChunkIds: dueChunkIds,
        );

    test('级别分组按 A1→C1 固定序，只列库里真实存在的档', () {
      final d = buildG();
      expect(
          d.levelsPresent, [ListeningLevel.a1, ListeningLevel.b1, ListeningLevel.c1]);
      expect(d.levels.map((g) => g.articles.length).toList(), [2, 1, 1]);
      expect(d.levels.first.articles.map((a) => a.id).toList(), ['G01', 'G02']);
    });

    test('引导卡：0 掌握建议 A1；有掌握按场景匹配到该块所在篇的级别', () {
      final fresh = buildG();
      expect(fresh.guidance, isNotNull);
      expect(fresh.guidance!.level, ListeningLevel.a1);
      expect(fresh.guidance!.title, '从 A1 开始听');

      final some = buildG(mastered: {'c01'});
      expect(some.guidance!.level, ListeningLevel.b1);
      expect(some.guidance!.sceneLabel, '职场');
      expect(some.guidance!.hint, contains('含 1 个已掌握块'));
      final words = '${some.guidance!.title}${some.guidance!.hint}';
      expect(RegExp(r'解锁|门槛|考核|付费|会员').hasMatch(words), isFalse,
          reason: '级别只是建议，不得写成门槛');
    });

    test('复习播单：无到期不显示；有到期按到期块数降序，块数去重', () {
      expect(buildG().reviewPlaylist.show, isFalse);
      expect(buildG(dueChunkIds: {'zz'}).reviewPlaylist.show, isFalse);

      final pl = buildG(dueChunkIds: {'c01', 'c02', 'm01'});
      expect(pl.reviewPlaylist.show, isTrue);
      expect(pl.reviewPlaylist.dueChunks, 3);
      expect(pl.reviewPlaylist.articles.map((a) => a.id).toList(), ['G03', 'G04'],
          reason: 'G03 含 2 个到期块，排前');
    });

    test('复习播单只挑含到期块的篇目，不触碰任何到期时间（禁 force due-now）', () {
      final due = {'c01', 'c02'};
      final pl = buildG(dueChunkIds: due);
      expect(pl.reviewPlaylist.articles.map((a) => a.id).toList(), ['G03']);
      expect(
          pl.reviewPlaylist.articles.every((a) =>
              due.intersection(a.chunks.map((c) => c.id).toSet()).isNotEmpty),
          isTrue);
      // 数据层无副作用：同一批文章重复构建，篇目与块集合不变
      final again = buildG(dueChunkIds: due);
      expect(again.reviewPlaylist.articles.map((a) => a.id).toList(),
          pl.reviewPlaylist.articles.map((a) => a.id).toList());
      expect(graded.map((a) => a.chunks.length).toList(),
          again.recent.map((a) => a.chunks.length).toList());
    });

    test('级别默认语速与播放速率梯对齐，且用户覆盖优先', () {
      expect(
          ListeningPlayerController.defaultRateFor(
              graded.first, _storeWith(const {})),
          0.75);
      expect(
          ListeningPlayerController.defaultRateFor(
              graded.first, _storeWith({'A1': 1.25})),
          1.25);
      expect(ListeningPlayerController.indexForRate(0.75), 0);
      expect(ListeningPlayerController.indexForRate(1.0), 1);
      expect(ListeningPlayerController.indexForRate(1.25), 2);
      // 梯外值吸附最近档，绝不产生新档位（音频缓存键因此不变）
      expect(ListeningPlayerController.indexForRate(0.9), 1);
      expect(ListeningPlayerController.indexForRate(0.8), 0);
      expect(ListeningPlayerController.indexForRate(9.9), 2);
    });
  });

}

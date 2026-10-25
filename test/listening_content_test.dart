import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';

void main() {
  late ContentPack content;
  late ListeningPack pack;
  late Map<String, dynamic> rawJson;

  setUpAll(() async {
    content = ContentPack.fromJson(jsonDecode(
            await File('assets/content_pack.json').readAsString())
        as Map<String, dynamic>);
    rawJson = jsonDecode(await File('assets/listening_articles.json').readAsString())
        as Map<String, dynamic>;
    pack = ListeningPack.fromJson(rawJson);
  });

  group('浸泡层内容 schema', () {
    test('24 篇 · 按级别折算时长 45-210 秒 · 校验 0 错', () {
      expect(pack.articles.length, 24);
      expect(validateListeningPack(pack, content), isEmpty);
      for (final a in pack.articles) {
        final atNormal = a.wordCount / 150 * 60 + (a.sentences.length - 1) * 0.3;
        final secs = atNormal / (a.baseRate ?? a.level.baseRate);
        expect(secs, inInclusiveRange(45, 210),
            reason: '${a.id}(${a.level.key}) 折算 ${secs.round()} 秒');
      }
    });

    test('分级分布：A1×5 / A2×2 / B1×14 / B2×1 / C1×2，级别与默认语速成对出现', () {
      final byLevel = <String, int>{};
      for (final a in pack.articles) {
        byLevel[a.level.key] = (byLevel[a.level.key] ?? 0) + 1;
        expect(a.levelRaw, a.level.key, reason: '${a.id} 级别字面量须规范');
        expect(a.baseRate, a.level.baseRate, reason: '${a.id} baseRate 须等于本级默认');
      }
      expect(byLevel, {'A1': 5, 'A2': 2, 'B1': 14, 'B2': 1, 'C1': 2});
      // A1 三篇必须真的更短更慢：词数与句均都低于 B1 任一篇
      final a1MaxWords =
          pack.articles.where((a) => a.level == ListeningLevel.a1).map((a) => a.wordCount).reduce((x, y) => x > y ? x : y);
      final b1MinWords =
          pack.articles.where((a) => a.level == ListeningLevel.b1).map((a) => a.wordCount).reduce((x, y) => x < y ? x : y);
      expect(a1MaxWords, lessThan(b1MinWords));
    });

    test('每篇标注 ≤ 收词上限，既有块占比守下限（核心库批次结构性上移）', () {
      var existing = 0, candidates = 0;
      for (final a in pack.articles) {
        final chunks = a.chunks;
        expect(chunks.length, lessThanOrEqualTo(a.collectLimit), reason: a.id);
        expect(chunks.length, inInclusiveRange(a.level.minChunks, a.level.maxChunks),
            reason: '${a.id} 块数须落在 ${a.level.key} 档');
        if (a.level == ListeningLevel.a1) {
          expect(a.knownChunkRatio, greaterThanOrEqualTo(0.70), reason: a.id);
        }
        existing += chunks.where((c) => !c.candidate).length;
        candidates += chunks.where((c) => c.candidate).length;
      }
      final ratio = existing / (existing + candidates);
      // 首批 16 篇的配比目标是 60–70%；第二批（指令 N §三）以 T0 待宿主池为主，
      // 标注块几乎全部是库内块，全库占比结构性上移。此处只守下限与候选账本非空。
      expect(ratio, greaterThanOrEqualTo(0.60));
      expect(candidates, greaterThanOrEqualTo(20));
    });

    test('既有块 id 全部可解析，候选块 id 不撞车且带 lx_ 前缀', () {
      final contentIds = {
        for (final lv in content.levels)
          for (final c in lv.chunks) c.id,
      };
      final candidateIds = <String>{};
      for (final a in pack.articles) {
        for (final c in a.chunks) {
          if (c.candidate) {
            expect(c.id, startsWith('lx_'));
            expect(contentIds, isNot(contains(c.id)));
            candidateIds.add(c.id);
          } else {
            expect(contentIds, contains(c.id));
          }
        }
      }
      expect(pack.candidates.length, candidateIds.length);
      expect(pack.candidateChunks.keys.toSet(), candidateIds);
      for (final c in pack.candidateChunks.values) {
        expect(c.text.trim(), isNotEmpty);
        expect(c.meaningCN.trim(), isNotEmpty);
      }
    });

    test('八个场景成组，无 Day N 编号库，级别文案不构成门槛', () {
      expect(pack.articles.map((a) => a.scene).toSet(), {
        'food', 'airport', 'work', 'hospital', // 首批四场景
        'greet', 'direction', 'shop', 'radio', // 指令 S 新增四场景
      });
      for (final a in pack.articles) {
        final text = '${a.title} ${a.summaryCN}';
        expect(RegExp(r'\bday\s*\d+', caseSensitive: false).hasMatch(text),
            isFalse,
            reason: '${a.id} 出现 Day N');
        expect(RegExp(r'第\s*\d+\s*天').hasMatch(text), isFalse,
            reason: '${a.id} 出现第 N 天');
        // 级别只是自选标签：内容文案里不得出现解锁/门槛/测试/等级考核口径
        expect(RegExp(r'解锁|门槛|通关|考核|等级测试|付费|会员').hasMatch(text), isFalse,
            reason: '${a.id} 级别文案越线');
        expect(a.sceneLabel.trim(), isNotEmpty, reason: a.id);
      }
    });

    test('句级块文本确实出现在句子里（高亮可定位）', () {
      for (final a in pack.articles) {
        for (final s in a.sentences) {
          for (final c in s.chunks) {
            expect(s.text.toLowerCase(), contains(c.text.toLowerCase()),
                reason: '${s.id}/${c.id}');
          }
        }
      }
    });

    test('候选块账本保留场景与来源篇目（浮层/词块库用）', () {
      for (final c in pack.candidates.values) {
        expect(c.scene, isNotEmpty);
        expect(c.sceneLabel, isNotEmpty);
        expect(pack.byId, contains(c.articleId));
      }
    });
  });

  group('schema 校验能挡住坏内容', () {
    ListeningArticle cloneWith(ListeningSentence Function(ListeningSentence) f) {
      final a = pack.articles.first;
      return ListeningArticle(
        id: a.id,
        title: a.title,
        scene: a.scene,
        sceneLabel: a.sceneLabel,
        summaryCN: a.summaryCN,
        updatedAt: a.updatedAt,
        audioUrl: '',
        collectLimit: a.collectLimit,
        sentences: a.sentences.map(f).toList(),
      );
    }

    test('未知词块 / 块不在句中 / 超出上限', () {
      final bad = cloneWith((s) => s.id == 'L01s2'
          ? ListeningSentence(
              id: s.id,
              text: s.text,
              meaningCN: s.meaningCN,
              chunks: [
                ListeningChunk(id: 'nope', text: 'nope', meaningCN: ''),
              ])
          : s);
      final errs = validateListeningPack(
          ListeningPack(version: 1, generatedAt: '', articles: [bad]), content);
      expect(errs.any((e) => e.contains('引用未知词块')), isTrue);
      expect(errs.any((e) => e.contains('块文本不在句中')), isTrue);
    });

    test('时间轴不完整 / 重叠会被拒', () {
      final bad = cloneWith((s) => ListeningSentence(
            id: s.id,
            text: s.text,
            meaningCN: s.meaningCN,
            chunks: s.chunks,
            startMs: 1000,
            endMs: 900,
          ));
      final errs = validateListeningPack(
          ListeningPack(version: 1, generatedAt: '', articles: [bad]), content);
      expect(errs.any((e) => e.contains('时间轴不完整或倒置')), isTrue);
    });

    test('候选块 id 不带 lx_ / 与既有块冲突会被拒', () {
      final bad = cloneWith((s) => ListeningSentence(
            id: s.id,
            text: 'I want oat milk today.',
            meaningCN: s.meaningCN,
            chunks: [
              ListeningChunk(
                  id: 'oat_milk', text: 'oat milk', meaningCN: '', candidate: true),
              ListeningChunk(
                  id: 'c01', text: 'I want', meaningCN: '', candidate: true),
            ],
          ));
      final errs = validateListeningPack(
          ListeningPack(version: 1, generatedAt: '', articles: [bad]), content);
      expect(errs.any((e) => e.contains('须以 lx_ 开头')), isTrue);
      expect(errs.any((e) => e.contains('与既有词块冲突')), isTrue);
    });

    test('错标级别会被拒：词数 / 句均 / 块数 / baseRate 四轴都核', () {
      Map<String, dynamic> articleRaw(String id) => Map<String, dynamic>.from(
          (rawJson['articles'] as List).cast<Map<String, dynamic>>().firstWhere(
              (a) => a['id'] == id));
      ListeningPack one(Map<String, dynamic> j) => ListeningPack(
          version: 2,
          generatedAt: '',
          articles: [ListeningArticle.fromJson(j)],
        );

      // 把 A1 篇（115 词 / 句均 3.8 / 6 块 / 0.75）冒充 C1
      final fakeC1 = articleRaw('L11')
        ..['level'] = 'C1'
        ..['baseRate'] = 1.25;
      final e1 = validateListeningPack(one(fakeC1), content);
      expect(e1.any((e) => e.contains('词数')), isTrue, reason: e1.join('\n'));
      expect(e1.any((e) => e.contains('句均词数')), isTrue);
      expect(e1.any((e) => e.contains('标注块数')), isTrue);

      // 把 B1 篇冒充 A1：词数/句均/块数越界，且 A1 复用率门槛一并核
      final fakeA1 = articleRaw('L02')
        ..['level'] = 'A1'
        ..['baseRate'] = 0.75;
      final e2 = validateListeningPack(one(fakeA1), content);
      expect(e2.any((e) => e.contains('词数')), isTrue);
      expect(e2.any((e) => e.contains('复用既有词块')), isTrue);

      // 级别字面量非法 / 缺失 / baseRate 与本级默认不符
      final bogus = articleRaw('L01')..['level'] = 'B2+';
      expect(
          validateListeningPack(one(bogus), content)
              .any((e) => e.contains('level 非法')),
          isTrue);
      final noRate = articleRaw('L01')..remove('baseRate');
      expect(
          validateListeningPack(one(noRate), content)
              .any((e) => e.contains('缺 baseRate')),
          isTrue);
      final wrongRate = articleRaw('L01')..['baseRate'] = 1.10;
      expect(
          validateListeningPack(one(wrongRate), content)
              .any((e) => e.contains('与本级默认')),
          isTrue);
    });
  });
}

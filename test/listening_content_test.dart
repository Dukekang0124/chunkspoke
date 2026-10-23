import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';

void main() {
  late ContentPack content;
  late ListeningPack pack;

  setUpAll(() async {
    content = ContentPack.fromJson(jsonDecode(
            await File('assets/content_pack.json').readAsString())
        as Map<String, dynamic>);
    pack = ListeningPack.fromJson(jsonDecode(
            await File('assets/listening_articles.json').readAsString())
        as Map<String, dynamic>);
  });

  group('浸泡层内容 schema', () {
    test('10 篇 · 每篇 2-3 分钟 · 校验 0 错', () {
      expect(pack.articles.length, 10);
      expect(validateListeningPack(pack, content), isEmpty);
      for (final a in pack.articles) {
        final words =
            a.sentences.fold<int>(0, (s, e) => s + e.text.split(' ').length);
        final secs = words / 150 * 60 + (a.sentences.length - 1) * 0.3;
        expect(secs, inInclusiveRange(120, 180), reason: '${a.id} 时长 ${secs ~/ 60}');
      }
    });

    test('每篇标注 ≤8 块，既有块占比 60-70%（首批口径）', () {
      var existing = 0, candidates = 0;
      for (final a in pack.articles) {
        final chunks = a.chunks;
        expect(chunks.length, lessThanOrEqualTo(8), reason: a.id);
        expect(chunks.length, a.collectLimit);
        existing += chunks.where((c) => !c.candidate).length;
        candidates += chunks.where((c) => c.candidate).length;
      }
      final ratio = existing / (existing + candidates);
      expect(ratio, inInclusiveRange(0.60, 0.70));
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

    test('四个场景成组，且无 Day N 编号库', () {
      expect(pack.articles.map((a) => a.scene).toSet(),
          {'food', 'airport', 'work', 'hospital'});
      for (final a in pack.articles) {
        final text = '${a.title} ${a.summaryCN}';
        expect(RegExp(r'\bday\s*\d+', caseSensitive: false).hasMatch(text),
            isFalse,
            reason: '${a.id} 出现 Day N');
        expect(RegExp(r'第\s*\d+\s*天').hasMatch(text), isFalse,
            reason: '${a.id} 出现第 N 天');
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
  });
}

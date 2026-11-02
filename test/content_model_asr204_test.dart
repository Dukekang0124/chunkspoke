import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';

/// ASR-204 一期：数据模型加 CEFR / 阶梯 / 篇目映射字段。
///
/// 口径：**全部可选**。没写 = 与今天完全一致（旧内容零改动仍 0 错）；
/// 一旦写了就必须合法，否则内容加载即报错 —— 宁缺不错。

Chunk _chunk(Map<String, dynamic> extra) => Chunk.fromJson({
      'id': 'c1',
      'text': 'I would like',
      'type': '固定搭配',
      'semantic': 'content',
      'meaningCN': '我想要',
      ...extra,
    });

/// 造一篇刚好落在 B1 标尺内的文章：32 句 × 9 词 = 288 词，句均 9.0，标注 8 块。
///
/// [chunkIds] 决定 8 个标注块引用哪些既有词块（用来构造「出自哪个模块」）。
ListeningArticle _article({
  Map<String, dynamic> extra = const {},
  List<String>? chunkIds,
}) {
  final ids = chunkIds ?? [for (var i = 0; i < 8; i++) 'a$i'];
  final sentences = <Map<String, dynamic>>[
    for (var i = 0; i < 32; i++)
      {
        'id': 'la1_s$i',
        'text': i < ids.length
            ? 'chunk$i again and again here we go today now'
            : 'plain and simple words for the count here now',
        'meaningCN': '',
        'chunks': [
          if (i < ids.length)
            {'id': ids[i], 'text': 'chunk$i', 'meaningCN': ''},
        ],
      },
  ];
  return ListeningArticle.fromJson({
    'id': 'la1',
    'title': 'Ordering coffee',
    'scene': 'cafe',
    'sceneLabel': '咖啡店',
    'level': 'B1',
    'baseRate': 1.0,
    'collectLimit': 8,
    'sentences': sentences,
    ...extra,
  });
}

/// 模块 A：a0..a7（chunk 文本 chunk0..chunk7）；模块 B：b0..b4。
ContentPack _content() => ContentPack.fromJson({
      'version': '1',
      'levels': [
        {
          'id': 'A',
          'theme': 'Greetings',
          'sceneImage': '',
          'chunks': [
            for (var i = 0; i < 8; i++)
              {
                'id': 'a$i',
                'text': 'chunk$i',
                'type': 'content',
                'meaningCN': ''
              }
          ],
          'sentences': [],
        },
        {
          'id': 'B',
          'theme': 'Coffee',
          'sceneImage': '',
          'chunks': [
            for (var i = 0; i < 5; i++)
              {
                'id': 'b$i',
                'text': 'chunk${i + 3}',
                'type': 'content',
                'meaningCN': ''
              }
          ],
          'sentences': [],
        },
      ],
    });

ListeningPack _pack(List<ListeningArticle> articles) =>
    ListeningPack(version: 1, generatedAt: '', articles: articles);

void main() {
  group('CEFR / 阶梯字段（词块与模块）', () {
    test('未声明 = 空串，旧内容零改动照常解析', () {
      expect(_chunk({}).cefr, '');
      final lv = Level.fromJson({
        'id': 'A',
        'theme': 'T',
        'sceneImage': '',
        'chunks': [],
      });
      expect(lv.stage, '');
      expect(lv.cefr, '');
    });

    test('声明后被读取并去空白', () {
      expect(_chunk({'cefr': ' B1 '}).cefr, 'B1');
      final lv = Level.fromJson({
        'id': 'A',
        'theme': 'T',
        'sceneImage': '',
        'chunks': [],
        'stage': 'L1',
        'cefr': 'A2',
      });
      expect(lv.stage, 'L1');
      expect(lv.cefr, 'A2');
    });

    test('档位与阶梯字面量非法 → 校验报错', () {
      final pack = ContentPack(version: '1', levels: [
        Level(
          id: 'A',
          theme: 'T',
          sceneImage: '',
          stage: 'L9',
          cefr: 'C2',
          chunks: [_chunk({'id': 'a1', 'cefr': 'b1'})],
        ),
      ]);
      final errs = validateContentPackReferences(pack);
      expect(errs, contains('A: stage 非法 L9（须为 L0/L1/L2/L3）'));
      expect(errs, contains('A: cefr 非法 C2（须为 A1/A2/B1/B2/C1）'));
      expect(errs.any((e) => e.contains('a1: cefr 非法 b1')), isTrue);
    });

    test('tier（核心度）与 cefr（难度）是两个正交轴', () {
      final c = _chunk({'tier': 'T0', 'cefr': 'A1'});
      expect(c.isCore, isTrue);
      expect(c.cefr, 'A1');
    });
  });

  group('篇目映射字段（磨耳朵 → 主线模块）', () {
    test('未声明 moduleIds/kind 时校验器不加新约束', () {
      expect(validateListeningPack(_pack([_article()]), _content()), isEmpty);
    });

    test('kind 必须是慢速对话 / 常速对话 / 独白三档之一', () {
      final bad = validateListeningPack(
          _pack([_article(extra: const {'kind': 'podcast'})]), _content());
      expect(bad.any((e) => e.contains('kind 非法：podcast')), isTrue);
      expect(
          validateListeningPack(
              _pack([_article(extra: const {'kind': 'slow_dialog'})]),
              _content()),
          isEmpty);
    });

    test('moduleIds 指向不存在的模块 → 报错', () {
      expect(
          validateListeningPack(
              _pack([_article(extra: const {'moduleIds': ['ZZ']})]),
              _content()),
          contains('la1 moduleIds 指向不存在的模块：ZZ'));
    });

    test('≥80% 标注块出自所声明模块才放行（指令 ASR-204 规则三）', () {
      // 8 块全在 A → 通过。
      expect(
          validateListeningPack(
              _pack([
                _article(extra: const {'moduleIds': ['A']})
              ]),
              _content()),
          isEmpty);
      // 声明只服务 A，但 3 块来自 B → 62.5% < 80% → 拒绝。
      final errs = validateListeningPack(
          _pack([
            _article(
              extra: const {'moduleIds': ['A']},
              chunkIds: const ['a0', 'a1', 'a2', 'a3', 'a4', 'b3', 'b4', 'b2'],
            )
          ]),
          _content());
      expect(errs.any((e) => e.contains('要求 ≥80%')), isTrue);
      // 同时声明 A+B → 池子覆盖全部 8 块 → 放行。
      expect(
          validateListeningPack(
              _pack([
                _article(
                  extra: const {'moduleIds': ['A', 'B']},
                  chunkIds: const [
                    'a0', 'a1', 'a2', 'a3', 'a4', 'b3', 'b4', 'b2'
                  ],
                )
              ]),
              _content()),
          isEmpty);
    });

    test('真实内容包在新增字段下仍然 0 错（向后兼容）', () {
      final content = ContentPack.fromJson(jsonDecode(
              File('assets/content_pack.json').readAsStringSync())
          as Map<String, dynamic>);
      final pack = ListeningPack.fromJson(jsonDecode(
              File('assets/listening_articles.json').readAsStringSync())
          as Map<String, dynamic>);
      expect(validateContentPackReferences(content), isEmpty);
      expect(validateListeningPack(pack, content), isEmpty);
      expect(
          content.levels.every((l) => l.stage.isEmpty && l.cefr.isEmpty), isTrue);
      expect(pack.articles.every((a) => a.moduleIds.isEmpty && a.kind.isEmpty),
          isTrue);
    });
  });
}

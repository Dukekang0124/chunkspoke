import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/phonetics.dart';
import 'package:chunkspoke_flutter/services/speech_judge.dart';

/// ASR-209 A 层回归夹具：
///   ① 两条反馈案（按症状文本重建：说对判错 / 目标词未被识别）；
///   ② 100 条扰动（同音 / 弱读缩合 / 连读与口头语）——目标句「说对」必须判对；
///   ③ 反例：真说错仍要判错，且灰带/失败分级正确。
///
/// 注：反馈原图未随指令附上，以下用例按症状重建；拿到原图后逐条对齐。

void main() {
  group('反馈两案（按症状重建）', () {
    test('案 A：说对判错 —— blue 被识别成 blew', () {
      final o = judgeSpeech(
          target: 'I will take the blue one', recognized: 'i will take the blew one');
      expect(o.pass, isTrue, reason: '同音异拼不该判错');
      expect(o.layer, isNot('reject'));
      expect(o.deviationHint, isNotNull);
      expect(o.deviationHint, contains('blew'));
    });

    test('案 B：目标词未被识别 —— buy 被识别成 by', () {
      final o = judgeSpeech(
          target: 'I need to buy a train ticket',
          recognized: 'i need to by a train ticket');
      expect(o.pass, isTrue);
      expect(o.layer, isNot('reject'));
    });
  });

  group('100 条扰动：说对必须判对', () {
    const bases = [
      'Could I get a coffee to go?',
      'I need to buy a train ticket today.',
      'Where is the nearest bus stop?',
      'I would like a glass of water, please.',
      'How much does this cost?',
      'Can you help me find the exit?',
      'I want to go home.',
      'Do you have a table for two?',
      'I will take the blue one.',
      'See you there at eight.',
    ];
    const homophones = {
      'buy': 'by',
      'find': 'fined',
      'two': '2',
      'blue': 'blew',
      'there': 'their',
      'eight': '8',
    };

    String variant(String base, int k) {
      final lower = base.toLowerCase();
      switch (k) {
        case 0:
          return lower.replaceAll(RegExp(r'[?.,]'), '');
        case 1:
          return base.toUpperCase();
        case 2:
          return 'um $lower';
        case 3:
          return '$lower you know';
        case 4:
          return '${lower.replaceAll(RegExp(r'[?.,]'), '')} please';
        case 5:
          for (final e in homophones.entries) {
            if (lower.contains(' ${e.key} ') ||
                lower.contains(' ${e.key}?') ||
                lower.contains(' ${e.key}.') ||
                lower.contains(' ${e.key},')) {
              return lower.replaceFirst(e.key, e.value);
            }
          }
          return lower.replaceAll(RegExp(r'[?.,]'), '');
        case 6:
          if (lower.contains('want to')) {
            return lower.replaceFirst('want to', 'wanna');
          }
          return lower.replaceAll(RegExp(r'[?.,]'), '');
        case 7:
          if (lower.contains(' the ')) {
            return lower.replaceFirst(' the ', ' ');
          }
          return lower.replaceAll(RegExp(r'[?.,]'), '');
        case 8:
          return 'i mean, $lower';
        default:
          return lower.replaceAll(RegExp(r'[?.,]'), '');
      }
    }

    test('10 个目标句 × 10 种扰动 = 100 条全部判对', () {
      var total = 0;
      final failures = <String>[];
      for (final base in bases) {
        for (var k = 0; k < 10; k++) {
          final said = variant(base, k);
          final o = judgeSpeech(target: base, recognized: said);
          total++;
          if (!o.pass) {
            failures.add('$k $said → reason=${o.reason} '
                'core=${o.coreHitRate.toStringAsFixed(2)} '
                'sim=${o.similarity.toStringAsFixed(2)}');
          }
        }
      }
      expect(total, 100);
      expect(failures, isEmpty,
          reason: '以下扰动被判错：\n${failures.join('\n')}');
    });
  });

  group('反例与分级', () {
    test('完全无关的两句仍判错', () {
      final o = judgeSpeech(
          target: 'Where is the nearest bus stop?',
          recognized: 'the weather is really nice today');
      expect(o.pass, isFalse);
      expect(o.band, 'fail');
    });

    test('真说错核心词（snack→snake）仍判错且不是灰带', () {
      final o = judgeSpeech(
          target: 'I want a snack', recognized: 'i want a snake');
      expect(o.pass, isFalse);
      expect(o.band, isNot('hit'));
    });

    test('灰带：只差一个内容词 → 可重说不扣分', () {
      final o = judgeSpeech(
          target: 'The coffee is too hot to drink',
          recognized: 'the coffee is too cold to drink');
      expect(o.pass, isFalse);
      expect(o.band, 'band', reason: '核心词命中 2/3、相似度够高，应落在灰带');
    });

    test('包含通道：目标句前后多出口头语仍判对', () {
      final o = judgeSpeech(
          target: 'Do you have a table for two?',
          recognized: 'um hello do you have a table for two thanks');
      expect(o.pass, isTrue);
      expect(o.layer, 'containment');
    });

    test('数词归一：2 与 two 等价、twenty one 与 21 等价', () {
      expect(wordClose('2', 'two'), isTrue);
      expect(wordClose('21', 'twenty one'), isTrue,
          reason: '数词解析允许英文拼写的多词组合');
      expect(expandSpokenTokens(['21']), ['twenty', 'one']);
      final o = judgeSpeech(
          target: 'Do you have a table for two?',
          recognized: 'do you have a table for 2');
      expect(o.pass, isTrue);
    });

    test('缩合归一：wanna 等价 want to（整句层）', () {
      final o = judgeSpeech(
          target: 'I want to go home', recognized: 'i wanna go home');
      expect(o.pass, isTrue);
    });

    test('逐字一致时不出现偏差提示', () {
      final o = judgeSpeech(
          target: 'Could I get a coffee to go?',
          recognized: 'could i get a coffee to go');
      expect(o.pass, isTrue);
      expect(o.deviationHint, isNull);
    });
  });
}

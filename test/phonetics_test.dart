import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/phonetics.dart';

/// ASR-209 A 层定标样本：
///   - [homophonePairs]：同音/近音不同拼写，判卷**应放行**；
///   - [distinctPairs]：发音不同、语义不同，判卷**应拒绝**。
/// 阈值只由这两组实测比值决定（见 docs/ASR-209-阈值定标.md），不拍脑袋。
const List<List<String>> homophonePairs = [
  ['right', 'write'],
  ['there', 'their'],
  ['two', 'too'],
  ['hear', 'here'],
  ['know', 'no'],
  ['one', 'won'],
  ['hour', 'our'],
  ['piece', 'peace'],
  ['weather', 'whether'],
  ['whole', 'hole'],
  ['would', 'wood'],
  ['plain', 'plane'],
  ['weak', 'week'],
  ['knight', 'night'],
  ['not', 'knot'],
  ['sun', 'son'],
  ['wait', 'weight'],
  ['wear', 'where'],
  ['which', 'witch'],
  ['sea', 'see'],
  ['meet', 'meat'],
  ['break', 'brake'],
  ['dear', 'deer'],
  ['fair', 'fare'],
  ['tail', 'tale'],
  ['steal', 'steel'],
  ['flour', 'flower'],
  ['allowed', 'aloud'],
  ['made', 'maid'],
  ['buy', 'by'],
  ['their', 'theyre'],
];

const List<List<String>> distinctPairs = [
  ['snack', 'snake'],
  ['cat', 'cut'],
  ['man', 'men'],
  ['bag', 'beg'],
  ['pen', 'pan'],
  ['ship', 'sheep'],
  ['full', 'fool'],
  ['sit', 'seat'],
  ['live', 'leave'],
  ['bad', 'bed'],
  ['cup', 'cap'],
  ['hat', 'hot'],
  ['work', 'walk'],
  ['think', 'sink'],
  ['three', 'tree'],
  ['mouth', 'mouse'],
  ['coat', 'caught'],
  ['green', 'grain'],
  ['fun', 'fan'],
  ['book', 'back'],
  ['loose', 'lose'],
  ['coffee', 'copy'],
  ['bread', 'breed'],
];

void main() {
  test('g2p 定标：同音对全部高于阈值、异音对全部低于阈值', () {
    final passRows = <String>[];
    final passRatios = <double>[];
    for (final p in homophonePairs) {
      final r = phonemeRatio(p[0], p[1]);
      passRatios.add(r);
      passRows.add('  ${p[0].padRight(10)} ${g2p(p[0]).padRight(10)} '
          '${p[1].padRight(10)} ${g2p(p[1]).padRight(10)} ${r.toStringAsFixed(3)}');
    }

    final rejectRows = <String>[];
    final rejectRatios = <double>[];
    for (final p in distinctPairs) {
      final r = phonemeRatio(p[0], p[1]);
      rejectRatios.add(r);
      rejectRows.add('  ${p[0].padRight(10)} ${g2p(p[0]).padRight(10)} '
          '${p[1].padRight(10)} ${g2p(p[1]).padRight(10)} ${r.toStringAsFixed(3)}');
    }

    final passMin = passRatios.reduce(math.min);
    final rejectMax = rejectRatios.reduce(math.max);

    // ignore: avoid_print
    print('── 应放行（同音/近音）──\n${passRows.join('\n')}\n'
        '── 应拒绝（异音）──\n${rejectRows.join('\n')}\n'
        'passMin=${passMin.toStringAsFixed(3)} '
        'rejectMax=${rejectMax.toStringAsFixed(3)} '
        'kPhonRatio=${kPhonRatio.toStringAsFixed(3)}');

    expect(passMin, greaterThanOrEqualTo(kPhonRatio),
        reason: '同音对最低值必须不低于阈值，否则真同音也会被拒');
    expect(rejectMax, lessThan(kPhonRatio),
        reason: '异音对最高值必须低于阈值，否则会把说错的词放行');
  });

  test('同音组：逐对放行', () {
    for (final p in homophonePairs) {
      expect(phonemeRatio(p[0], p[1]), greaterThanOrEqualTo(kPhonRatio),
          reason: '${p[0]} / ${p[1]} 应视为同音');
    }
  });

  test('异音组：逐对拒绝', () {
    for (final p in distinctPairs) {
      expect(phonemeRatio(p[0], p[1]), lessThan(kPhonRatio),
          reason: '${p[0]} / ${p[1]} 不应视为同音');
    }
  });

  test('弱读/缩合还原', () {
    expect(spokenExpansion('wanna'), ['want', 'to']);
    expect(spokenExpansion('gonna'), ['going', 'to']);
    expect(spokenExpansion('dunno'), ['do', 'not', 'know']);
    expect(spokenExpansion('hafta'), ['have', 'to']);
    expect(spokenExpansion('cause'), ['because']);
    expect(spokenExpansion('notaword'), isNull);
  });

  // ASR-211 修复 1：撇号缩合与所有格进归一层。
  test('撇号缩合还原与词干', () {
    expect(spokenExpansion("i'd"), ['i', 'would']);
    expect(spokenExpansion("they're"), ['they', 'are']);
    expect(spokenExpansion("don't"), ['do', 'not']);
    expect(spokenExpansion("can't"), ['can', 'not']);
    expect(spokenExpansion("it's"), ['it', 'is']);
    expect(apostropheStem("sam's"), 'sam');
    expect(apostropheStem('sam'), 'sam');
    expect(apostropheStem("'cause"), "'cause", reason: '首字符是撇号时不截断');
    expect(expandSpokenTokens(["i'd", 'like']), ['i', 'would', 'like']);
  });

  test('虚词表覆盖课程里的缩合写法', () {
    // 内容包 L0/L1 里高频出现的撇号形式，逐条必须有表项或可被词干规则吃掉。
    const inCourse = [
      "i'd", "i'll", "i'm", "i've", "you're", "you've", "we're", "they're",
      "it's", "that's", "there's", "what's", "who's", "let's", "he's", "she's",
      "don't", "doesn't", "didn't", "isn't", "aren't", "can't", "won't",
      "couldn't", "shouldn't", "wouldn't", "haven't", "hasn't", "hadn't",
    ];
    for (final t in inCourse) {
      expect(spokenExpansion(t), isNotNull, reason: '$t 缺缩合表项');
      expect(apostropheStem(t), isNotEmpty);
    }
  });

  test('空串与单字符', () {
    expect(g2p(''), '');
    expect(phonemeRatio('', 'the'), 0);
    expect(g2p('a'), 'a');
  });
}

import 'package:chunkspoke_flutter/services/clip_chunk_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 词块联动 · 提取器边界：只认词表与受控句型，宁缺毋滥。
void main() {
  List<String> texts(String s) =>
      extractClipChunks(s).map((h) => h.text).toList();

  test('动词短语：屈折还原成规范形（looking forward to → look forward to）', () {
    final hits = extractClipChunks("I'm looking forward to the weekend.");
    expect(hits.any((h) => h.text == 'look forward to'), isTrue,
        reason: hits.join(','));
    expect(hits.firstWhere((h) => h.text == 'look forward to').kind, '动词短语');
  });

  test('不规则过去式：gave up → give up', () {
    expect(texts('She gave up smoking last year.'), contains('give up'));
  });

  test('be 句型词表命中：was able to → be able to', () {
    final hits = extractClipChunks('He was able to solve it quickly.');
    expect(hits.any((h) => h.text == 'be able to'), isTrue, reason: hits.join(','));
  });

  test('三词搭配：take care of / make sure', () {
    expect(texts('Please take care of your sister.'), contains('take care of'));
    expect(texts('Make sure you lock the door.'), contains('make sure'));
  });

  test('短语落在句尾也能命中（turn off）', () {
    expect(texts('Please turn off.'), contains('turn off'));
  });

  test('介词短语：in the morning', () {
    expect(texts('We met in the morning.'), contains('in the morning'));
  });

  test('框架词不收：go to 不是词块，同句只留 every day', () {
    final t = texts('I go to school every day.');
    expect(t, isNot(contains('go to')));
    expect(t, contains('every day'));
  });

  test('缩写展开后仍能认出 be + adj + prep 词表项', () {
    expect(texts("She's interested in art."), contains('be interested in'));
  });

  test('受控句型模板：be + 副词 + adj + prep → be happy to', () {
    final hits = extractClipChunks('He is really happy to help.');
    final h = hits.where((x) => x.text == 'be happy to').toList();
    expect(h.length, 1, reason: hits.join(','));
    expect(h.first.kind, '常用句型');
  });

  test('句尾模板也算（This is important to me）', () {
    expect(texts('This is important to me.'), contains('be important to'));
  });

  test('中文、纯网址、CSV 片段、单词一律不产出', () {
    expect(extractClipChunks('今天天气很好，我们去公园吧。'), isEmpty);
    expect(extractClipChunks('https://example.com/a/b?c=1'), isEmpty);
    expect(extractClipChunks('a,b,c'), isEmpty);
    expect(extractClipChunks('plate'), isEmpty);
    expect(extractClipChunks(''), isEmpty);
  });

  test('句内重复只收一次，且返回顺序=出现顺序', () {
    final hits = extractClipChunks('Look forward to it, look forward to it.');
    expect(hits.where((h) => h.text == 'look forward to').length, 1);
    expect(hits.map((h) => h.start).toList(),
        orderedEquals(hits.map((h) => h.start).toList()..sort()));
  });

  test('命中互不重叠', () {
    final hits = extractClipChunks(
        'I look forward to hearing from you and will take care of it.');
    final spans = hits.map((h) => [h.start, h.end]).toList()
      ..sort((a, b) => a[0].compareTo(b[0]));
    for (var i = 1; i < spans.length; i++) {
      expect(spans[i][0] >= spans[i - 1][1], isTrue,
          reason: '重叠：${spans[i - 1]} vs ${spans[i]}');
    }
  });

  test('每句上限 4 个，超出的不硬收', () {
    const long = 'I look forward to it and I will take care of it and '
        'make sure to turn off the lights in the morning and hear from you.';
    final hits = extractClipChunks(long);
    expect(hits.length, kClipMaxChunksPerSentence);
  });

  test('同义变体归到同一个 key（跨句去重口径）', () {
    final a = extractClipChunks('I look forward to it.').first;
    final b = extractClipChunks('Looking forward to it!').first;
    expect(a.key, b.key);
    expect(a.text, 'look forward to');
  });

  test('类型只能是四类白名单', () {
    const kinds = {'动词短语', '固定搭配', '介词短语', '常用句型'};
    for (final s in [
      'I look forward to it.',
      'Take care of yourself.',
      'We met in the morning.',
      'He is really happy to help.',
      'Please turn off the light.',
    ]) {
      for (final h in extractClipChunks(s)) {
        expect(kinds.contains(h.kind), isTrue, reason: '${h.text} → ${h.kind}');
      }
    }
  });

  test('looksLikeEnglishSentence 与 normalizeClipSentence 口径', () {
    expect(looksLikeEnglishSentence('I look forward to it.'), isTrue);
    expect(looksLikeEnglishSentence('今天天气很好'), isFalse);
    expect(looksLikeEnglishSentence('go'), isFalse);
    expect(normalizeClipSentence('  I’m  LOOKING forward…  '),
        "i'm looking forward");
  });
}

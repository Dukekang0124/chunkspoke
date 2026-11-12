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

  // ---------------------------------------------------------------------
  // 1.10.1：用户实测「粘贴的句子一个词块都没认出」的回归钉测。
  // 六句来自截图里的「我的英语本 2」，修复前逐句 0 命中。
  // ---------------------------------------------------------------------
  group('用户实测句子：0 命中 → 每句至少一个词块', () {
    const cases = <String, String>{
      'Could you tell me more about your job?': 'tell me more',
      "I'm in charge of marketing planning.": 'be in charge of',
      'It keeps me pretty busy these days.': 'these days',
      'What does your daily work look like?': 'look like',
      'I need to write plans and analyze data.': 'need to',
      'Sometimes I have meetings with my teammates.': 'have a meeting',
    };
    cases.forEach((sentence, expected) {
      test('$sentence → $expected', () {
        expect(texts(sentence), contains(expected), reason: sentence);
      });
    });
  });

  test('可拆分短语动词允许代词插入（write it down / turn it off / pick me up）', () {
    expect(texts('Can you write it down for me?'), contains('write down'));
    expect(texts('Please turn it off.'), contains('turn off'));
    expect(texts('He will pick me up at six.'), contains('pick up'));
    expect(texts('Please write them down.'), contains('write down'));
  });

  test('不可拆分的词组不会被代词插入规则误命中', () {
    // look after 不在可拆分集合里：只认原形，不认 look it after。
    expect(texts('I look after it.'), contains('look after'));
    expect(texts('I look it after.'), isEmpty);
    // talk about 同理：talk me about 不是词组。
    expect(texts('They talk me about work.'), isEmpty);
  });

  test('复数/省冠词别名词形归到同一规范形', () {
    final hits = extractClipChunks('We have meetings and send emails daily.');
    final t = hits.map((h) => h.text).toList();
    expect(t, contains('have a meeting'), reason: t.join(','));
    expect(t, contains('send an email'), reason: t.join(','));
    expect(t, isNot(contains('have meetings')));
    // 跨句去重：两种说法是同一个 key。
    expect(
        extractClipChunks('We have meetings.')[0].key,
        extractClipChunks('We have a meeting.')[0].key);
  });

  test('新增固定搭配在白名单类型内，且规范大小写不被拉低', () {
    expect(texts('Good morning, everyone.'), contains('good morning'));
    expect(texts('We split the bill at the end.'), contains('split the bill'));
    expect(texts('I saw it on TV.'), contains('on TV'));
    final h = extractClipChunks('We split the bill.').first;
    expect(h.kind, '固定搭配');
    expect(h.key, 'split the bill');
  });

  test('受控句型模板：it is/was + adj + to', () {
    expect(texts('It was important to finish on time.'),
        contains('it is important to'));
    final h = extractClipChunks('It is important to practice every day.')
        .firstWhere((x) => x.text == 'it is important to');
    expect(h.kind, '常用句型');
    // 不是形容词就不套模板（It is a small pleasure 不产出）。
    expect(texts('It is a small pleasure.'), isEmpty);
  });

  test('补词表没有放宽成相邻词：框架仍不进', () {
    final t = texts('I go to school every day.');
    expect(t, isNot(contains('go to')));
    expect(t, isNot(contains('to school')));
    expect(extractClipChunks('Where is the toilet?'), isEmpty,
        reason: '没有命中内置短语时如实返回空，不硬造');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_text_parser.dart';

/// 1.9.2 · 「随便粘一段文本」压力报告。
///
/// 模拟不懂技术的用户随手粘贴的各种东西：纯中文、中英混排、带逗号的散文、
/// 网址、缩写、超长句、表情、清单、对话、对照行……先看实际输出，再钉断言。
void main() {
  final cases = <(String, String)>[
    ('纯中文', '今天天气很好。我们去公园吧。'),
    ('逗号散文两行', 'I like apples, bananas, and oranges.\nShe likes tea, coffee, and juice.'),
    ('逗号散文三行', 'I like apples, bananas, and oranges.\nShe likes tea, coffee, and juice.\nHe wants rice, noodles, and dumplings.'),
    ('逗号单行', 'I bought apples, bananas, and oranges at the store.'),
    ('购物清单', '- apples\n- bananas\n- oranges'),
    ('编号清单', '1. Hello\n2. Goodbye\n3. Thank you'),
    ('英文对话', 'A: Good morning!\nB: Morning! How are you?\nA: I am fine, thanks.'),
    ('中文说话人对话', '小明：Hello there!\n小红：Hi! Nice to meet you.'),
    ('竖线对照', 'Hello | 你好\nGood morning | 早上好'),
    ('下一行中文对照', 'Hello\n你好\nGoodbye\n再见'),
    ('中英混排一行', '今天学 Hello world 这个句子'),
    ('网址', 'Visit https://example.com for details. It is free.'),
    ('纯网址行', 'https://example.com\nhttp://test.org'),
    ('缩写段落', 'Mr. Smith went to the U.S. He arrived at 5 p.m. It was nice.'),
    ('超长单句无标点', 'This is a very long sentence that just keeps going and going without any punctuation at all because the user typed it in one breath and never stopped to think about where it might end'),
    ('长段落有标点', 'I get up at seven. I brush my teeth. I have breakfast. Then I go to school by bus. The bus is always late. I do not like waiting in the cold wind every morning.'),
    ('重复句', 'Hello.\nhello.\nHELLO.'),
    ('空文本', ''),
    ('纯空白', '   \n  \n '),
    ('表情', 'I love you 😊\nYou are great! 🎉'),
    ('纯标点', '!!! ??? ...'),
    ('全大写', 'HELLO WORLD. HOW ARE YOU?'),
    ('分号', 'I like tea; she likes coffee.'),
    ('BOM+CRLF', '\uFEFFHello\r\nWorld'),
    ('制表符对照', 'Hello\t你好'),
    ('引号包行', '"Good morning!"\n\'See you later.\''),
    ('小数开头', '3.14 is pi. It is a number.'),
    ('省略号', 'Wait… what? I do not know…'),
    ('时间戳行', '00:12 Hello everyone\n01:30 Welcome back'),
    ('JSON', '[{"front":"Hello","module_name":"x"}]'),
    ('CSV带表头', 'front,back,module_name\nHello,你好,book'),
    ('裸CSV三列', 'a,b,c\nd,e,f'),
    ('单词', 'hello'),
    ('中英夹杂多行', 'apple 苹果\nbanana 香蕉\norange 橙子'),
    ('超长一句超120', 'I really want to learn English because it is important for my job and I hope I can speak it fluently one day without feeling nervous about making mistakes in front of other people'),
  ];

  test('压力报告：打印每种输入的实际整理结果', () {
    final buf = StringBuffer();
    for (final (label, input) in cases) {
      final plan = parsePastedUserText(input);
      buf.writeln('== $label ==');
      if (plan == null) {
        final v = parseAndValidateUserPackage(input);
        buf.writeln('  → 走表格入口 ok=${v.ok} entries=${v.entries.length} '
            'issues=${v.issues.map((i) => "${i.field}:${i.reason}").toList()}');
      } else {
        buf.writeln('  kind=${plan.kindLabel} ok=${plan.ok} '
            'entries=${plan.entries.length} paired=${plan.pairedCount} '
            'missing=${plan.meaningMissing} dropped=${plan.droppedNonEnglish} '
            'dup=${plan.duplicates} skipped=${plan.skipped}');
        for (final e in plan.entries.take(4)) {
          buf.writeln('    [${e.front}] back=[${e.back}]');
        }
        if (plan.entries.length > 4) {
          buf.writeln('    …共 ${plan.entries.length} 条');
        }
        for (final i in plan.validation.issues) {
          buf.writeln('  ISSUE ${i.row}/${i.field}: ${i.reason} '
              '→ 人话: ${describeIssueForLearner(i)}');
        }
        for (final n in plan.notes) {
          buf.writeln('  NOTE $n');
        }
      }
    }
    // ignore: avoid_print
    print(buf.toString());
  });

  group('压力测试钉测：随便粘的文本不许毁数据、不许甩黑话', () {
    test('P0 带逗号的普通英文是句子，不是表格（两行/三行都不误判）', () {
      for (final raw in [
        'I like apples, bananas, and oranges.\nShe likes tea, coffee, and juice.',
        'I like apples, bananas, and oranges.\nShe likes tea, coffee, and juice.\nHe wants rice, noodles, and dumplings.',
      ]) {
        final plan = parsePastedUserText(raw);
        expect(plan, isNotNull, reason: '散文不许被当表格');
        expect(plan!.ok, isTrue, reason: '${plan.validation.issues}');
        expect(plan.kindLabel, '一段英文');
        expect(plan.entries.first.front, 'I like apples, bananas, and oranges.');
        expect(plan.validation.issues, isEmpty);
      }
      // 真正的无表头表格仍然走表格入口（原钉测不变）。
      expect(parsePastedUserText('a,b,c\nd,e,f'), isNull);
      // 带表头的 CSV / JSON 照旧。
      expect(parsePastedUserText('front,back,module_name\nHello,你好,book'), isNull);
      expect(parsePastedUserText('[{"front":"Hello","module_name":"x"}]'), isNull);
    });

    test('P1 句子里的网址不被当说话人吃掉', () {
      final plan = parsePastedUserText(
          'Visit https://example.com for details. It is free.');
      expect(plan, isNotNull);
      expect(plan!.ok, isTrue);
      expect(plan.kindLabel, '一段英文');
      expect(plan.entries.map((e) => e.front).toList(),
          ['Visit https://example.com for details.', 'It is free.']);
      // 纯网址行也原样保留，不削成 //example.com。
      final urls = parsePastedUserText('https://example.com\nhttp://test.org');
      expect(urls!.entries.first.front, 'https://example.com');
      // 真对话不受影响。
      final talk = parsePastedUserText('Tom: How are you?\nLily: Fine, thanks.');
      expect(talk!.kindLabel, '一段对话');
      expect(talk.entries.first.front, 'How are you?');
    });

    test('P2 超长句报错说人话：不报 CSV 行号，直接教怎么改', () {
      const long = 'I really want to learn English because it is important for '
          'my job and I hope I can speak it fluently one day without feeling '
          'nervous about making mistakes in front of other people';
      final plan = parsePastedUserText(long);
      expect(plan, isNotNull);
      expect(plan!.ok, isFalse);
      final msg = describeIssueForLearner(plan.validation.issues.first);
      expect(msg, contains('太长了'));
      expect(msg, contains('分成两句'));
      expect(msg, isNot(contains('第 2 行')));
      expect(msg, isNot(contains('120')));
    });

    test('P3 句尾纯表情碎片不单独成句', () {
      final plan = parsePastedUserText('I love you 😊\nYou are great! 🎉');
      expect(plan, isNotNull);
      expect(plan!.ok, isTrue);
      expect(plan.entries.map((e) => e.front).toList(),
          ['I love you 😊', 'You are great!']);
      expect(plan.entries.any((e) => e.front == '🎉'), isFalse);
    });

    test('P4 字幕时间戳剥掉，台词照常成句', () {
      final plan = parsePastedUserText(
          '00:12 Hello everyone\n01:30 Welcome back\n1:02:33 Nice to see you');
      expect(plan, isNotNull);
      expect(plan!.ok, isTrue);
      expect(plan.entries.map((e) => e.front).toList(),
          ['Hello everyone', 'Welcome back', 'Nice to see you']);
      // 小数不被当时间戳削掉。
      final pi = parsePastedUserText('3.14 is pi.');
      expect(pi!.entries.first.front, '3.14 is pi.');
    });
  });
}
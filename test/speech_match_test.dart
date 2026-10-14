import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/speech.dart';

void main() {
  group('chunkHit (L4 开口容错命中)', () {
    test('词序无关：打乱顺序仍全部命中', () {
      final r = chunkHit('I go to school', 'school to go i');
      expect(r.allHit, isTrue);
      expect(r.hit, containsAll(['go', 'school']));
    });

    test('编辑距离≤1：scool ≈ school 命中', () {
      final r = chunkHit('I go to school', 'i go to scool');
      expect(r.allHit, isTrue);
    });

    test('词干近似：长词前缀容差命中', () {
      final r = chunkHit('she reads books', 'she read book');
      expect(r.allHit, isTrue);
    });

    test('缺失核心词：返回 missed 用于琥珀高亮', () {
      final r = chunkHit('I go to school', 'school');
      expect(r.allHit, isFalse);
      expect(r.missed, contains('go'));
    });

    test('variants 候选可接受替代词', () {
      final r = chunkHit('I go to school', 'i went to school',
          variants: ['went']);
      expect(r.allHit, isTrue);
    });

    test('stopwords 不参与判定', () {
      final r = chunkHit('the cat', 'cat');
      expect(r.allHit, isTrue);
      expect(r.hit, ['cat']);
    });
  });
}

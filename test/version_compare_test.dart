import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/update/version_compare.dart';

void main() {
  group('isNewerVersion (数值比较，禁止字符串)', () {
    test('remote > local → true', () => expect(isNewerVersion(10, 2013), isTrue));
    test('remote == local → false', () => expect(isNewerVersion(2013, 2013), isFalse));
    test('remote < local → false', () => expect(isNewerVersion(2013, 10), isFalse));
  });

  group('parseVersionCode (容错)', () {
    test('int 透传', () => expect(parseVersionCode(2013), 2013));
    test('num 透传', () => expect(parseVersionCode(2013.0), 2013));
    test('字符串数字', () => expect(parseVersionCode('2013'), 2013));
    test('null → 0', () => expect(parseVersionCode(null), 0));
    test('空字符串 → 0', () => expect(parseVersionCode(''), 0));
    test('非数字 → 0', () => expect(parseVersionCode('abc'), 0));
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/update/sha256_util.dart';

void main() {
  test('fileSha256 命中已知向量', () async {
    final dir = await Directory.systemTemp.createTemp('sha');
    final f = File('${dir.path}/t.bin')..writeAsStringSync('abc');
    final h = await fileSha256(f.path);
    // sha256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    expect(h,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    await dir.delete(recursive: true);
  });

  group('sha256Matches', () {
    test('精确匹配', () => expect(sha256Matches('ABC', 'ABC'), isTrue));
    test('忽略大小写', () => expect(sha256Matches('abcdef', 'ABCDEF'), isTrue));
    test('忽略首尾空白', () => expect(sha256Matches(' abc ', 'abc'), isTrue));
    test('expected 为空 → 跳过校验(通过)',
        () => expect(sha256Matches('whatever', ''), isTrue));
    test('不匹配 → false', () => expect(sha256Matches('abc', 'def'), isFalse));
  });
}

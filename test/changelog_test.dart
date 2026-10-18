import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/changelog.dart';

void main() {
  group('A6 动态标题', () {
    test('标题由当前版本号动态拼接，含当前版本号', () {
      expect(changelogTitle('1.4.2'), '本次更新 v1.4.2');
      expect(changelogTitle('1.4.2'), contains('1.4.2'));
      expect(changelogTitle('2.0.0'), contains('2.0.0'));
      expect(changelogTitle('1.4.2'), contains(changelogTitlePrefix));
    });

    test('buildChangelog：标题含版本号，内容项非空', () {
      final c = buildChangelog('1.4.2');
      expect(c.title, contains('1.4.2'));
      expect(c.items, isNotEmpty);
    });
  });
}

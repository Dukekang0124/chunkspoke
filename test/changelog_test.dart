import 'dart:convert';
import 'dart:io';

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
      expect(c.items, isNotEmpty, reason: '未知版本也应落到兜底语料，不弹空窗');
    });
  });

  group('正文语料防漂移（1.5.9 真机自检发现的问题）', () {
    // 1.5.9 首装实测：标题已变 1.5.9，正文仍是 1.5.8 的音色包文案。
    // 根因 = 正文是与版本号无关的单一列表。此组断言把「忘写本版语料」钉死。
    test('包内 version.json 的 versionName 必须有专属语料', () {
      final raw = File('assets/version.json').readAsStringSync();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final v = (j['versionName'] ?? '').toString();
      expect(v, isNotEmpty, reason: '包内清单缺 versionName');
      expect(changelogByVersion.containsKey(v), isTrue,
          reason: 'assets/version.json 已是 $v，但 changelogByVersion 没有 $v 条目'
              '——首启弹窗会显示旧版文案');
    });

    test('每个版本都至少一条，且条目以「· 」开头', () {
      changelogByVersion.forEach((v, items) {
        expect(items, isNotEmpty, reason: '$v 语料为空');
        for (final it in items) {
          expect(it.startsWith('· '), isTrue, reason: '$v 的条目未用「· 」前缀：$it');
        }
      });
    });

    test('取到的就是该版本自己的语料，不会串版', () {
      final a = buildChangelog('1.5.9');
      final b = buildChangelog('1.5.8');
      expect(a.items.first, contains('学习日历'));
      expect(b.items.first, contains('朗读人声'));
      expect(a.items, isNot(equals(b.items)));
    });
  });
}

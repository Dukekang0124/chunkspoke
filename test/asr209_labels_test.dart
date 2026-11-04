import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/ui/labels.dart';

/// ASR-209 六：S0「Survival First」标题与副标题撞名。
///
/// 病灶：level.dart 主标题走 `sceneCn(theme)`、副标题直接用英文 theme；
/// 词表里没有某个 theme 时 `sceneCn` 原样返回英文 → 两行一模一样。
/// 这里不再手写清单，直接把内容包里出现的 theme 全查一遍。
void main() {
  test('生存包主题有中文名（标题不再回退成英文）', () {
    expect(sceneCn('Survival First'), '生存英语');
    expect(sceneCn('Survival First'), isNot('Survival First'));
  });

  test('内容包里每个 theme 都能翻成中文（标题/副标题不撞名）', () {
    final pack = jsonDecode(File('assets/content_pack.json').readAsStringSync())
        as Map<String, dynamic>;
    final themes = <String>{
      for (final l in (pack['levels'] as List).cast<Map<String, dynamic>>())
        if (l['theme'] is String) l['theme'] as String,
    };
    expect(themes, isNotEmpty);
    final missing = themes.where((t) => sceneCn(t) == t).toList();
    expect(missing, isEmpty,
        reason: '以下 theme 没有中文映射，卡片标题会与英文副标题重复：$missing');
  });
}

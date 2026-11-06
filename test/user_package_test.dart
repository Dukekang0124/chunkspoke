import 'dart:convert';

import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:flutter_test/flutter_test.dart';

/// ASR-213 第 1 天地基：用户包模板 / 解析 / 设备侧校验 / 命名空间隔离。
void main() {
  test('两份模板自身必须过闸（模板即回归，改字段表必须同步改模板）', () {
    final csv = parseAndValidateUserPackage(userPackageCsvTemplate());
    expect(csv.ok, isTrue, reason: csv.issues.join(' | '));
    expect(csv.entries.length, 2);
    final json = parseAndValidateUserPackage(userPackageJsonTemplate());
    expect(json.ok, isTrue, reason: json.issues.join(' | '));
  });

  test('必填缺失给行级报错（第 N 行 · 字段 · 原因）', () {
    final r = parseAndValidateUserPackage(''
        'front,back,module_name\n'
        ',我想要靠窗的座位,航空出行\n');
    expect(r.ok, isFalse);
    expect(r.firstErrorText, contains('第 2 行'));
    expect(r.firstErrorText, contains('front'));
  });

  test('媒体字段结构性拒绝：音频由本机合成', () {
    final r = parseAndValidateUserPackage(''
        'front,back,module_name,audio_url\n'
        'plate,盘子,餐饮点餐,https://x/y.mp3\n');
    expect(r.ok, isFalse);
    expect(r.issues.map((e) => e.toString()).join(' | '), contains('音频由本机合成'));
  });

  test('密钥类字段结构性拒绝（与 codes.json/secret 零交集）', () {
    final r = parseAndValidateUserPackage(''
        'front,back,module_name,secret\n'
        'plate,盘子,餐饮点餐,abc\n');
    expect(r.ok, isFalse);
    expect(r.issues.map((e) => e.toString()).join(' | '), contains('密钥类字段一律禁止'));
  });

  test('每包 200 块上限，超限明示原因', () {
    final rows = [
      'front,back,module_name',
      for (var i = 0; i < kUserPackageMaxChunks + 1; i++) 'w$i,释义$i,我的模块',
    ].join('\n');
    final r = parseAndValidateUserPackage(rows);
    expect(r.ok, isFalse);
    expect(r.issues.map((e) => e.reason).join(' | '), contains('超出每包'));
  });

  test('块 ID 走 user: 命名空间且内容寻址稳定', () {
    final a = parseAndValidateUserPackage(''
        'front,back,module_name\nplate,盘子,餐饮点餐\n');
    final b = parseAndValidateUserPackage(
        'front,back,module_name\nplate,盘子,餐饮点餐\n');
    expect(a.ok, isTrue, reason: a.issues.join(' | '));
    final key = a.entries.single.chunkKey;
    expect(key, startsWith('user:'));
    expect(isUserChunkKey(key), isTrue);
    expect(isUserChunkKey('sv01'), isFalse);
    expect(b.entries.single.chunkKey, key, reason: '重复导入要能幂等替换自己的包');
    expect(a.entries.single.moduleKey, startsWith('user_module:'));
  });

  test('包内重复行报出行号', () {
    final r = parseAndValidateUserPackage(''
        'front,back,module_name\n'
        'plate,盘子,餐饮点餐\n'
        'plate,盘子,餐饮点餐\n');
    expect(r.ok, isFalse);
    expect(r.issues.map((e) => e.toString()).join(' | '), contains('内容重复'));
  });

  test('六步可用位：只有单词、没有整句时，依赖整句的步骤必须标为不可用', () {
    final wordOnly = parseAndValidateUserPackage(
        'front,back,module_name\nplate,盘子,餐饮点餐\n');
    expect(wordOnly.entries.single.hasSentenceForSpeakingSteps, isFalse);
    expect(wordOnly.entries.single.sentenceSourceText, isNull);

    final withExample = parseAndValidateUserPackage(
        'front,back,module_name,example\nplate,盘子,餐饮点餐,Wash the plate first.\n');
    expect(withExample.entries.single.hasSentenceForSpeakingSteps, isTrue);
    expect(withExample.entries.single.sentenceSourceText, 'Wash the plate first.');
  });

  test('cefr 与 tags 口径', () {
    final bad = parseAndValidateUserPackage(
        'front,back,module_name,cefr\nplate,盘子,餐饮点餐,B9\n');
    expect(bad.issues.map((e) => e.reason).join(' | '), contains('A1/A2/B1/B2/C1/C2'));
    final manyTags = parseAndValidateUserPackage(
        'front,back,module_name,tags\nplate,盘子,餐饮点餐,${List.filled(9, 't').join(', ')}\n');
    expect(manyTags.issues.map((e) => e.reason).join(' | '), contains('最多 8 个标签'));
  });

  test('JSON 顶层两种形状都收，坏 JSON 给整包级报错', () {
    expect(parseAndValidateUserPackage(jsonEncode([
      {'front': 'plate', 'back': '盘子', 'module_name': '餐饮点餐'}
    ])).ok, isTrue);
    expect(parseAndValidateUserPackage(jsonEncode({
      'chunks': [
        {'front': 'plate', 'back': '盘子', 'module_name': '餐饮点餐'}
      ]
    })).ok, isTrue);
    expect(parseAndValidateUserPackage('{"chunks": [1,2').ok, isFalse);
    expect(parseAndValidateUserPackage('{"foo": 1}').firstErrorText,
        contains('chunks'));
  });
}

import 'dart:io';

import 'package:chunkspoke_flutter/screens/user_preview_screen.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ASR-215 小片钉测：只预览不落库（四红线里的两条靠测试守住）。
void main() {
  test('红线：预览页不得 import 任何 store/db/provider（结构性零写入）', () {
    final src = File('lib/screens/user_preview_screen.dart').readAsStringSync();
    for (final forbidden in [
      'chunkspoke_flutter/services/progress',
      'chunkspoke_flutter/services/chunk_store',
      'chunkspoke_flutter/models/app_database',
      'provider.dart',
      'sqflite',
    ]) {
      expect(src.contains(forbidden), isFalse, reason: '预览页出现了 $forbidden');
    }
  });

  testWidgets('UI 上明写「只预览，不落库」，且校验通过只报数不写库', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UserPreviewScreen()));
    expect(find.textContaining('只预览，不落库'), findsOneWidget);

    await tester.tap(find.text('填入 CSV 模板'));
    await tester.pump();
    await tester.tap(find.text('解析并预览'));
    await tester.pump();
    expect(find.textContaining('校验通过：2 块 · 2 个模块'), findsOneWidget);
    expect(find.textContaining('不占名额'), findsOneWidget);
  });

  testWidgets('未过闸时明说「一行都不会写入」并列出行级报错', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: UserPreviewBody(
        result: parseAndValidateUserPackage(
            'front,back,module_name' + String.fromCharCode(10) + ',盘子,餐饮点餐'),
      ),
    ));
    expect(find.textContaining('未过闸'), findsOneWidget);
    expect(find.textContaining('一行都不会写入'), findsOneWidget);
    expect(find.textContaining('第 2 行'), findsOneWidget);
    expect(find.textContaining('front'), findsWidgets);
  });

  test('六项体验清单齐六条且带「不写库、不碰进度」声明', () {
    expect(UserImportFeedbackScreen.questions.length, 6);
    final src = File('lib/screens/user_preview_screen.dart').readAsStringSync();
    expect(src.contains('这一版只做预览：不写库、不碰进度'), isTrue);
  });
}

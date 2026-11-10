import 'dart:io';

import 'package:chunkspoke_flutter/screens/user_preview_screen.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 预览页钉测：只看不存（四红线里的两条靠测试守住）+ 文案不许有技术词。
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

  testWidgets('UI 上明写「只是看看，不会保存」，且校验通过只报数不保存', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UserPreviewScreen()));
    expect(find.textContaining('只是看看，不会保存'), findsOneWidget);
    // 面向普通用户的页面不许出现「落库 / 写库 / 命名空间」这类词。
    for (final jargon in ['落库', '写库', '命名空间', '字段', 'schema']) {
      expect(find.textContaining(jargon), findsNothing, reason: '预览页出现了 $jargon');
    }

    await tester.tap(find.text('看看示例表格'));
    await tester.pump();
    await tester.tap(find.text('整理一下'));
    await tester.pump();
    expect(find.textContaining('可以了：2 句'), findsOneWidget);
    // 预览主体里报归属；输入框里也有模板原文，所以按整句钉，不按子串。
    expect(find.textContaining('放进「航空出行'), findsOneWidget);
    expect(find.textContaining('这一页只看不存'), findsOneWidget);
  });

  testWidgets('从添加页带原文进来：不用再粘一次，打开就已排好', (tester) async {
    const pasted = 'Can I get a cup of coffee? Sure. What size would you like?';
    await tester.pumpWidget(const MaterialApp(
        home: UserPreviewScreen(initialText: pasted)));
    await tester.pump();
    expect(find.textContaining('这就是你刚粘进来的内容'), findsOneWidget);
    expect(find.textContaining('可以了：3 句'), findsOneWidget);
    expect(find.textContaining('Can I get a cup of coffee?'), findsWidgets);
    // 带原文时不再显示「把英文粘进来」那种空态引导。
    expect(find.textContaining('把英文粘进来'), findsNothing);
  });

  testWidgets('没过检查时明说「一句都不会保存」并列出行级原因', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: UserPreviewBody(
        result: parseAndValidateUserPackage(
            'front,back,module_name${String.fromCharCode(10)},盘子,餐饮点餐'),
      ),
    ));
    expect(find.textContaining('要看看'), findsOneWidget);
    expect(find.textContaining('一句都不会保存'), findsOneWidget);
    expect(find.textContaining('第 2 行'), findsOneWidget);
    expect(find.textContaining('英文'), findsWidgets);
  });

  test('六项体验清单齐六条且带「不会保存任何句子」声明', () {
    expect(UserImportFeedbackScreen.questions.length, 6);
    final src = File('lib/screens/user_preview_screen.dart').readAsStringSync();
    expect(src.contains('这一页只是收集你的意见：不会保存任何句子，也不动学习记录'), isTrue);
  });
}
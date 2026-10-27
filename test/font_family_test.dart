import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_web/ui/theme.dart';

/// CanvasKit 只在字体集合里找不到字形时才去 fonts.gstatic.com 拉 Noto 兜底。
/// 一旦某个 widget 的样式丢掉字族（fontFamily=null），中文就会触发外链请求。
String? familyOf(WidgetTester tester, String text) {
  final rt = tester.widget<RichText>(
    find.descendant(of: find.text(text), matching: find.byType(RichText)).first,
  );
  return rt.text.style?.fontFamily;
}

void main() {
  testWidgets('按钮默认字族继承主题的 NotoSansSC', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildWebTheme(),
      home: Scaffold(
        body: Column(
          children: [
            OutlinedButton(onPressed: () {}, child: const Text('outlined')),
            ElevatedButton(onPressed: () {}, child: const Text('elevated')),
            TextButton(onPressed: () {}, child: const Text('textbtn')),
            OutlinedButton(
              onPressed: () {},
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('styled', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (final label in ['outlined', 'elevated', 'textbtn', 'styled']) {
      expect(familyOf(tester, label), 'NotoSansSC', reason: '$label 丢字族会触发 CanvasKit 外链兜底');
    }
  });

  testWidgets('styleFrom(textStyle:) 会替换掉字族（记录该坑，防回归写法）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildWebTheme(),
      home: Scaffold(
        body: OutlinedButton(
          onPressed: () {},
          style: OutlinedButton.styleFrom(textStyle: const TextStyle(fontSize: 11)),
          child: const Text('替换'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(familyOf(tester, '替换'), isNull);
  });
}

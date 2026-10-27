import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_web/app.dart';
import 'package:chunkspoke_web/ui/theme.dart';

/// 守卫真实事故：固定 locale=zh_CN 但没有中文 MaterialLocalizations 时，
/// `_TextFieldState._getEffectiveDecoration` 里的 `MaterialLocalizations.of`
/// 返回 null，搜索框一构建就抛「Null check operator used on a null value」，
/// release 下整块变成灰色 ErrorWidget。
void main() {
  testWidgets('zh_CN MaterialApp 能提供 MaterialLocalizations，TextField 不报错', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: kWebSupportedLocales,
        localizationsDelegates: kWebLocalizationsDelegates,
        theme: buildWebTheme(),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: TextField(
                decoration: InputDecoration(hintText: '搜索英文 / 中文 / id'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final context = tester.element(find.byType(TextField));
    expect(MaterialLocalizations.of(context), isNotNull);
    // 中文代理生效：系统级字符串不该再回落到英文
    expect(MaterialLocalizations.of(context).copyButtonLabel, '复制');
    expect(find.text('搜索英文 / 中文 / id'), findsOneWidget);
  });
}

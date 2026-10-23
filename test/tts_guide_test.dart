import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/screens/tts_guide.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/ui/theme.dart';

Widget _wrap(TtsGuideScreen screen) =>
    MaterialApp(theme: darkTheme, home: screen);

void main() {
  testWidgets('noEngine 引导页：原因 + 下载/设置/继续入口', (tester) async {
    var continued = false;
    await tester.pumpWidget(_wrap(TtsGuideScreen(
      status: TtsStatus.noEngine,
      diagnostic: 'noEngine (engine=none)',
      engine: '',
      onRecheck: () async => TtsStatus.noEngine,
      onContinue: () async => continued = true,
    )));

    expect(find.text('先装一个语音引擎，再开始朗读'), findsOneWidget);
    expect(find.text('未检测到 TTS 引擎'), findsOneWidget);
    expect(find.text('打开系统语音设置'), findsOneWidget);
    expect(find.text('去下载语音引擎'), findsOneWidget);
    expect(find.text('重新检测'), findsOneWidget);

    await tester.ensureVisible(find.text('先继续使用'));
    await tester.tap(find.text('先继续使用'));
    await tester.pump();
    expect(continued, isTrue);
  });

  testWidgets('noEnglish 引导页：展示当前引擎与语音包步骤', (tester) async {
    await tester.pumpWidget(_wrap(TtsGuideScreen(
      status: TtsStatus.noEnglish,
      diagnostic: 'noEnglish (engine=com.google.android.tts)',
      engine: 'com.google.android.tts',
      onRecheck: () async => TtsStatus.noEnglish,
      onContinue: () async {},
    )));

    expect(find.text('给语音引擎补上英文语音'), findsOneWidget);
    expect(find.text('当前引擎：Google 语音合成'), findsOneWidget);
    expect(find.text('安装其他语音引擎'), findsOneWidget);
    expect(find.textContaining('安装英文语音数据'), findsOneWidget);
  });

  testWidgets('重新检测成功：提示可用语音', (tester) async {
    await tester.pumpWidget(_wrap(TtsGuideScreen(
      status: TtsStatus.noEngine,
      diagnostic: 'noEngine (engine=none)',
      engine: '',
      onRecheck: () async => TtsStatus.ready,
      onContinue: () async {},
    )));

    await tester.ensureVisible(find.text('重新检测'));
    await tester.tap(find.text('重新检测'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('已检测到可用的英文语音'), findsOneWidget);
  });
}

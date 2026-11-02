import 'dart:io';

import 'package:chunkspoke_flutter/services/pronunciation_score.dart';
import 'package:chunkspoke_flutter/services/theme_provider.dart';
import 'package:chunkspoke_flutter/ui/pron_result_card.dart';
import 'package:chunkspoke_flutter/ui/theme.dart';
import 'package:chunkspoke_flutter/ui/theme_card.dart';
import 'package:chunkspoke_flutter/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 视觉回归证据：真组件 × 14 套色板（7 主题 × 浅/深）逐张出图。
///
/// 跑法：`flutter test --update-goldens test/theme_visual_golden_test.dart`
/// 产物落在 test/goldens/theme/，再复制到 .evidence/theme/screenshots/ 归档。
/// 关注点（任务书 §8.2）：浅色主题下不得出现白字白底；词块四色 + 形状双重编码
/// 在每套主题里都要仍然分得开。
void main() {
  const cases = <String, String>{
    'default': '墨蓝琥珀',
    'nude_rose': '奶咖玫瑰',
    'sage': '莫兰迪灰绿',
    'plum': '雾玫瑰灰紫',
    'ocean': '深海蓝',
    'forest': '墨绿',
    'charcoal': '炭灰极简',
  };

  for (final id in cases.keys) {
    for (final mode in ['dark', 'light']) {
      final dir = Directory('test/goldens/theme/$id-$mode');
      if (!dir.existsSync()) dir.createSync(recursive: true);

      testWidgets('$id $mode 词块四色 + 外观卡片 + 评分卡', (tester) async {
        final p = ThemeProvider(
            initialId: id, initialMode: mode == 'dark' ? 'dark' : 'light');
        await tester.binding.setSurfaceSize(const Size(420, 780));
        await tester.pumpWidget(ChangeNotifierProvider<ThemeProvider>.value(
          value: p,
          child: MaterialApp(
            theme: p.lightThemeData,
            darkTheme: p.darkThemeData,
            themeMode: p.themeMode,
            home: Scaffold(
              backgroundColor: kBg,
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('主标题 ${cases[id]}',
                        style: TextStyle(
                            color: kText,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    Text('次要说明文字（kTextSecondary）',
                        style: TextStyle(color: kTextSecondary, fontSize: 14)),
                    Text('弱提示文字（kTextMuted）',
                        style: TextStyle(color: kTextMuted, fontSize: 12)),
                    const SizedBox(height: 12),
                    const Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChunkTile('want to', 'content'),
                        ChunkTile('to', 'function'),
                        ChunkTile('and', 'connector'),
                        ChunkTile('at 8am', 'timeplace'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    PronResultCard(
                        result: scorePronunciation(
                          target: 'i want to go home',
                          recognized: 'i want go home',
                        )),
                    const SizedBox(height: 16),
                    const ThemeCard(),
                    const SizedBox(height: 16),
                    ElevatedButton(
                        onPressed: () {}, child: const Text('主按钮')),
                  ],
                ),
              ),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));

        await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/theme/$id-$mode/page.png'));

        // 机器可判定的「没有白字白底」：主文字与底色必须真有差异。
        expect(find.text('主标题 ${cases[id]}'), findsOneWidget);
        expect(kBg, isNot(kText));
        expect(kText.computeLuminance() == kBg.computeLuminance(), isFalse,
            reason: '$id $mode 主文字与底色同亮度 = 看不见');
      });
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 字形覆盖守卫：界面新增中文后若忘了重跑 `tool/subset_cjk_font.py`，
/// 子集字体缺字会回退到 fonts.gstatic.com（国内不可达 → 豆腐块）。
void main() {
  test('子集字符集覆盖 lib、内容资产与入口页里的全部非 ASCII 字符', () {
    final charset = <int>{
      for (final ch in jsonDecode(File('tool/font_subset_chars.json').readAsStringSync()) as List)
        (ch as String).runes.first,
    };

    final sources = <File>[
      for (final e in Directory('lib').listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart')) e,
      File('assets/content/chunks.json'),
      File('assets/content/articles.json'),
      File('web/index.html'),
      File('web/manifest.json'),
    ];

    final missing = <int>{};
    for (final f in sources) {
      for (final rune in f.readAsStringSync().runes) {
        if (rune < 0x80) continue;
        if (!charset.contains(rune)) missing.add(rune);
      }
    }

    expect(
      missing,
      isEmpty,
      reason: '缺少 ${missing.length} 个字符：'
          '${String.fromCharCodes(missing)} —— 请重跑 tool/subset_cjk_font.py',
    );
  });
}

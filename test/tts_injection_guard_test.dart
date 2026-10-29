import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「测试不许测假路径」（DDS §30.6 / 指令 #249-C 裁定 2）的常驻守门：
/// 1. `lib/` 里每一个 `TtsService(...)` 构造点都必须注入 `readProfile` 与
///    `onEvent`——包括 E2E 入口（`main_e2e.dart`），否则压测跑的是
///    「标准档、事件丢失」的假路径；
/// 2. 发音参数只允许在 `loaders.dart` 里算（`kRate`/`kPitch`/`setSpeechRate`/
///    `setPitch` 不许在别处出现），防单源化被后来者旁路。
void main() {
  test('lib 内每个 TtsService 实例都注入语速单源与埋点（含 E2E 入口）', () {
    final files = _dartFilesUnder('lib');
    expect(files, isNotEmpty);

    var sites = 0;
    for (final f in files) {
      final src = f.readAsStringSync();
      final isDeclaration = _norm(f.path).endsWith('services/loaders.dart');
      for (final m in RegExp(r'TtsService\s*\(').allMatches(src)) {
        // 类声明 `TtsService({` 不是实例化。
        if (isDeclaration && src.substring(m.end).trimLeft().startsWith('{')) {
          continue;
        }
        sites++;
        final args = _balancedArgs(src, m.end);
        final where = '${f.path}:${_lineOf(src, m.start)}';
        expect(args.contains('readProfile:'), isTrue,
            reason: '$where 未注入 readProfile（会 fallback 标准档，测试/真机分叉）');
        expect(args.contains('onEvent:'), isTrue,
            reason: '$where 未注入 onEvent（tts_hd_fallback 等事件会丢）');
      }
    }
    // 两个入口各一个：main.dart + main_e2e.dart。少于 2 说明有入口漏扫。
    expect(sites, greaterThanOrEqualTo(2));
  });

  test('发音参数单源：loaders.dart 之外不许出现速率/音调设置', () {
    final offenders = <String>[];
    for (final f in _dartFilesUnder('lib')) {
      if (_norm(f.path).endsWith('services/loaders.dart')) continue;
      final src = f.readAsStringSync();
      for (final pat in [
        RegExp(r'\bkRate\b'),
        RegExp(r'\bkPitch\b'),
        RegExp(r'\.setSpeechRate\s*\('),
        RegExp(r'\.setPitch\s*\('),
      ]) {
        if (pat.hasMatch(src)) offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: '这些文件绕过了 VoiceProfile：${offenders.toSet().join(', ')}');
  });

  test('两个入口都从 ProgressService 读档位', () {
    for (final name in ['lib/main.dart', 'lib/main_e2e.dart']) {
      final src = File(name).readAsStringSync();
      expect(src.contains('progress.ttsSpeed'), isTrue,
          reason: '$name 未把用户档位接进 TtsService');
    }
  });
}

List<File> _dartFilesUnder(String dir) {
  final out = <File>[];
  for (final e in Directory(dir).listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) out.add(e);
  }
  return out;
}

/// 从 `(` 之后取到配对的 `)`，返回参数文本（不 trim，便于判断 `{`）。
String _balancedArgs(String src, int from) {
  var depth = 1;
  var i = from;
  var inStr = false;
  var quote = '';
  while (i < src.length) {
    final c = src[i];
    if (inStr) {
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == quote) inStr = false;
    } else if (c == '"' || c == "'") {
      inStr = true;
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(from, i);
    }
    i++;
  }
  return src.substring(from);
}

String _norm(String p) => p.replaceAll(r'\', '/');

int _lineOf(String src, int offset) =>
    '\n'.allMatches(src.substring(0, offset)).length + 1;

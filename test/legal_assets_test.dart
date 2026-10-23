import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

/// GPLv3 合规闸门：全文许可证与书面源码要约必须随 APK 与发音包一同分发。
void main() {
  const appAssets = [
    'assets/legal/LICENSE-GPLv3.txt',
    'assets/legal/SOURCE-OFFER.txt',
    'assets/legal/VOICE-PACK-NOTICE.txt',
  ];
  const packFiles = [
    'voice_pack/hd-voice-piper-en-us-medium/LICENSE-GPLv3.txt',
    'voice_pack/hd-voice-piper-en-us-medium/SOURCE-OFFER.txt',
    'voice_pack/hd-voice-piper-en-us-medium/NOTICE.txt',
  ];

  test('APK 资产与发音包均含 GPLv3 全文与源码要约', () {
    for (final p in [...appAssets, ...packFiles]) {
      expect(File(p).existsSync(), isTrue, reason: '缺少 $p');
    }
  });

  test('GPLv3 全文完整（非摘要）', () {
    final raw = File('assets/legal/LICENSE-GPLv3.txt').readAsStringSync();
    final flat = raw.replaceAll(RegExp(r'\s+'), ' ');
    expect(raw.length, greaterThan(30000));
    expect(flat, contains('GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007'));
    expect(flat, contains('Preamble'));
    expect(flat, contains('TERMS AND CONDITIONS'));
    expect(flat, contains('END OF TERMS AND CONDITIONS'));
    expect(flat, contains('How to Apply These Terms to Your New Programs'));
    // 与上游 espeak-ng/COPYING 逐字节一致（非节选、非改写）。
    final sha = sha256.convert(File('assets/legal/LICENSE-GPLv3.txt').readAsBytesSync());
    expect(
        sha.toString(),
        '8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903');
  });

  test('书面要约覆盖数据与 APK 内静态链接代码，并给出源码地址', () {
    final t = File('assets/legal/SOURCE-OFFER.txt').readAsStringSync();
    expect(t, contains('GPL-3.0-or-later'));
    expect(t, contains('espeak-ng-data'));
    expect(t, contains('libsherpa-onnx-c-api.so'));
    expect(t, contains('https://github.com/espeak-ng/espeak-ng'));
    expect(t, contains('https://github.com/k2-fsa/sherpa-onnx'));
    expect(t, contains('3 年'));
  });

  test('随包声明标注模型与各组件许可', () {
    final t = File('assets/legal/VOICE-PACK-NOTICE.txt').readAsStringSync();
    expect(t, contains('vits-piper-en_US-ljspeech-medium'));
    expect(t, contains('GPL-3.0-or-later'));
    expect(t, contains('Apache-2.0'));
    expect(t, contains('MIT'));
  });
}

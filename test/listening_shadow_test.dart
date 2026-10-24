import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/asr_guard.dart';
import 'package:chunkspoke_flutter/services/listening_shadow.dart';

/// 句级轻跟读判定核（指令 S §二.4）：三态文案与「不产资产」口径。
void main() {
  const target = 'Good morning to you too.';
  List<double> confs(int n, double v) => List<double>.filled(n, v);

  group('轻跟读三态', () {
    test('说对 → pass，文案为通过语', () {
      final v = judgeShadowRead(
        target: target,
        recognized: target,
        confidence: 0.92,
        durationSec: 2.0,
        wordConfidences: confs(5, 0.92),
      );
      expect(v.passed, isTrue);
      expect(v.similarity, greaterThan(0.99));
      expect(v.verdict.kind, AsrVerdictKind.pass);
      expect(v.verdict.text, '✓ 说到位了');
    });

    test('说清楚但没说对 → notUsed，原文逐字上屏、与结论分列', () {
      final v = judgeShadowRead(
        target: target,
        recognized: 'Thank you very much indeed for the help',
        confidence: 0.9,
        durationSec: 3.0,
        wordConfidences: confs(8, 0.9),
      );
      expect(v.passed, isFalse);
      expect(v.verdict.kind, AsrVerdictKind.notUsed);
      expect(v.verdict.text, contains('Thank you very much indeed'));
      expect(v.verdict.text, contains('和目标句还不一致'));
      // 闭合跟读文案（chunkStyle=false）不得出现「目标块」口径
      expect(v.verdict.text, isNot(contains('目标块')));
    });

    test('没听清（低置信）→ retry，不给通过结论', () {
      final v = judgeShadowRead(
        target: target,
        recognized: target,
        confidence: 0.1,
        durationSec: 2.0,
        wordConfidences: confs(5, 0.1),
      );
      expect(v.passed, isFalse);
      expect(v.verdict.kind, AsrVerdictKind.retry);
      expect(v.verdict.text, '⚠ 没听清，再说一遍');
    });

    test('录音过短 → 不判通过（防噪兜底与六步④同阈值）', () {
      final v = judgeShadowRead(
        target: target,
        recognized: target,
        confidence: 0.9,
        durationSec: 0.2,
        wordConfidences: confs(5, 0.9),
      );
      expect(v.passed, isFalse);
      expect(v.verdict.kind, isNot(AsrVerdictKind.pass));
    });

    test('静音/空结果 → 不判通过', () {
      final v = judgeShadowRead(
        target: target,
        recognized: '',
        confidence: 0.9,
        durationSec: 1.5,
        wordConfidences: const [],
      );
      expect(v.passed, isFalse);
      expect(v.similarity, 0);
    });

    test('无置信度字段（Azure 路径）→ 只按文本相似度判，不拒判', () {
      final v = judgeShadowRead(
        target: target,
        recognized: target,
        confidence: null,
        durationSec: 2.0,
        wordConfidences: null,
      );
      expect(v.passed, isTrue);
      expect(v.verdict.kind, AsrVerdictKind.pass);
    });
  });
}

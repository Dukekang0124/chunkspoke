import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/speech_judge.dart';

/// Dart ⇄ Python 判定对拍（1.5.9 · §30.2）。
///
/// 夹具 `test/fixtures/judge_parity.json` 由 `tools/judge_parity.py` 用
/// **Python 侧（tools/vosk_sim.py，发布门/基准集的执行体）** 跑同一批合成句生成；
/// 本测试断言 Dart 侧 [judgeSpeech]（用户实际跑的判定）逐条给出同一结论。
///
/// 同一批用例改动一边判定就必须重跑生成器：
///   `python tools/judge_parity.py && flutter test test/judge_parity_test.dart`
///
/// 映射：Python `exact` ⇄ Dart `('ok','exact')`；Python `fuzzy` ⇄ Dart `('ok','fuzzy')`；
/// 拒判的 reason 两边同名。`similarity` 取**加权**相似度（Python `sim` = Dart
/// [JudgeOutcome.weightedSimilarity]），空转写/过短两边都为 0。
void main() {
  final payload = jsonDecode(
    File('test/fixtures/judge_parity.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final cases = (payload['cases'] as List).cast<Map<String, dynamic>>();

  /// 把 Dart 的 (reason, layer) 折回 Python 的单一 reason 词表。
  String parityReason(JudgeOutcome o) {
    if (o.reason == 'ok') return o.layer == 'exact' ? 'exact' : 'fuzzy';
    return o.reason;
  }

  group('判定对拍：Dart judgeSpeech ⇄ Python vosk_sim.judge_speech', () {
    test('夹具完整（非空、kind 正确、每条都有 expect）', () {
      expect(payload['kind'], 'judge-parity');
      expect(cases, isNotEmpty);
      for (final c in cases) {
        expect(c['target'], isA<String>());
        expect(c['hyp'], isA<String>());
        expect(c['expect'], isA<Map>(), reason: '缺 expect：${c['note']}');
      }
    });

    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final exp = (c['expect'] as Map).cast<String, dynamic>();
      final label = '#$i ${c['note']}';
      final divergence = c['divergence'] as String?;

      test(label, () {
        final out = judgeSpeech(
          target: c['target'] as String,
          recognized: c['hyp'] as String,
          confidence: (c['confidence'] as num?)?.toDouble(),
          durationSec: (c['durationSec'] as num?)?.toDouble(),
        );

        final ctx = '目标「${c['target']}」识别「${c['hyp']}」'
            '（conf=${c['confidence']}, dur=${c['durationSec']}）';
        final wantSim = (exp['similarity'] as num).toDouble();

        if (divergence == 'noiseFloor') {
          // 已知差：Python 只算加权（放行），Dart 另有未加权 0.5 底线（拒判）。
          // 断言「差异方向 + 两条口径都在」，两边任何一侧口径变了这条就红。
          expect(exp['passed'], isTrue, reason: '$label Python 侧本应放行：$ctx');
          expect(exp['reason'], 'fuzzy', reason: '$label Python 侧本应是 fuzzy：$ctx');
          expect(out.pass, isFalse, reason: '$label Dart 应被未加权底线拦下：$ctx');
          expect(out.reason, 'lowSim', reason: '$label Dart 拒判理由应为 lowSim：$ctx');
          expect(out.similarity, lessThan(kMinSimilarity),
              reason: '$label Dart 未加权相似度应低于底线 $kMinSimilarity：$ctx');
          expect(out.weightedSimilarity, greaterThanOrEqualTo(0.8),
              reason: '$label 加权相似度仍应达标（差异来自底线而非加权）：$ctx');
          expect(out.weightedSimilarity, closeTo(wantSim, 0.01),
              reason: '$label 加权值与 Python sim 仍须一致：$ctx');
          return;
        }

        expect(out.pass, exp['passed'], reason: '$label 通过与否不一致：$ctx');
        expect(parityReason(out), exp['reason'],
            reason: '$label 结论不一致：$ctx → Dart ${out.reason}/${out.layer}');

        // 加权相似度：Python 的 sim 就是加权值；两边都必须落在同一数上。
        expect(out.weightedSimilarity, closeTo(wantSim, 0.01),
            reason: '$label 加权相似度不一致：$ctx → '
                'Dart ${out.weightedSimilarity.toStringAsFixed(4)} vs '
                'Python ${wantSim.toStringAsFixed(4)}');

        // 完全匹配通道必须是同一条通道，不能靠模糊层凑通过。
        if (exp['reason'] == 'exact') {
          expect(out.layer, 'exact', reason: '$label 应走完全匹配快速通道：$ctx');
        }
        if (exp['passed'] == false) {
          expect(out.similarity, lessThan(1.0), reason: '$label 拒判却给了满分相似度');
        }
      });
    }
  });
}

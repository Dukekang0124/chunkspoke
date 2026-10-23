import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/speech_judge.dart';

/// 判定回归矩阵日志（打印三层漏斗的「规范化后文本 / 相似度 / 置信度 / 最终判定 / 漏斗层」）。
/// 用 `flutter test -r expanded test/judge_log_test.dart` 运行以取原文。
void _log(String tag, JudgeOutcome r) {
  final conf = r.confidence == null ? 'null(缺失)' : r.confidence!.toStringAsFixed(2);
  final norm = r.recognizedWords.join(' ');
  // 人工以 `-r expanded` 读判定原文，print 即本用例的产出通道。
  // ignore: avoid_print
  print('[回归] $tag | 规范化后="$norm" | 相似度=${r.similarity.toStringAsFixed(3)} '
      '| 置信度=$conf | 层=${r.layer} | reason=${r.reason} | 判定=${r.pass ? "放行" : "不放行"}');
}

void main() {
  test('判定回归矩阵（四种输入）+ 防噪兜底 日志', () {
    // ① 正确朗读（本 P0 病灶：上轮被误拒，本轮必须放行）
    _log(
        '①正确朗读',
        judgeSpeech(
            target: 'good morning',
            recognized: 'Good morning',
            confidence: null, // Vosk 顶层无 confidence → 缺失
            durationSec: 1.2));
    // ② 乱说（无关词）
    _log(
        '②乱说',
        judgeSpeech(
            target: 'good morning',
            recognized: 'banana telephone',
            confidence: null,
            durationSec: 1.2));
    // ③ 静音 / 环境音
    _log(
        '③静音/环境音',
        judgeSpeech(target: 'good morning', recognized: '', confidence: null));
    // ④ 快速含糊半秒发音（时长够 0.4s，但文本含糊）
    _log(
        '④快速含糊半秒',
        judgeSpeech(
            target: 'good morning',
            recognized: 'gud mornin',
            confidence: null,
            durationSec: 0.5));
    // 附：过短录音（<0.4s）防噪兜底
    _log(
        '附:过短<0.4s',
        judgeSpeech(
            target: 'good morning',
            recognized: 'good morning',
            confidence: null,
            durationSec: 0.35));

    // 断言：与矩阵一致
    expect(
        judgeSpeech(target: 'good morning', recognized: 'Good morning').pass,
        isTrue);
    expect(
        judgeSpeech(target: 'good morning', recognized: 'banana telephone').pass,
        isFalse);
    expect(judgeSpeech(target: 'good morning', recognized: '').pass, isFalse);
    expect(
        judgeSpeech(
                target: 'good morning',
                recognized: 'gud mornin',
                durationSec: 0.5)
            .pass,
        isFalse);
  });
}

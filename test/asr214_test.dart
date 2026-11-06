import 'dart:io';

import 'package:chunkspoke_flutter/services/asr_budget.dart';
import 'package:chunkspoke_flutter/services/speech_judge.dart';
import 'package:flutter_test/flutter_test.dart';

/// ASR-214 · 真机「USE WAS GREAT」吞词故障的回归钉。
///
/// 取证见 `release/ASR-214/`（复现脚本 `tools/asr214_onset_probe.py`）：
/// 第 6/6 步自由造句，目标词块 `main course`、参考句 "The main course was great."，
/// 用户被回 `USE WAS GREAT（增强识别）` 并判失败。三条真因：
///  ① 增强 zipformer 被 ASR-191「模式 B」当成了**主引擎**，而它 40 句实测
///    WER 0.432 / 整句全对 40%，同批 Vosk 是 0.049 / 82.5%；
///  ② 「目标句当热词」从未生效（tokens.txt 里没有 `MAIN` 这类整词 token，
///    encoder 每次都是 `Encode hotwords failed, skipping`）；
///  ③ 句首丢 300–500 ms 时，Vosk 也会把 `the main` 丢掉 → 尾部对上了却缺首词。
void main() {
  group('ASR-214 F1 一过引擎选择', () {
    test('Vosk 有文本就绝不换增强（真机故障的正解）', () {
      expect(
          useEnhancedFirstPass(voskHasText: true, enhancedHasText: true), isFalse);
      expect(
          useEnhancedFirstPass(voskHasText: true, enhancedHasText: false), isFalse);
    });

    test('只有 Vosk 空结果时增强才兜底', () {
      expect(
          useEnhancedFirstPass(voskHasText: false, enhancedHasText: true), isTrue);
      expect(
          useEnhancedFirstPass(voskHasText: false, enhancedHasText: false), isFalse);
    });

    test('防复发：recognizeOpen 里 Vosk 必须排在增强之前', () {
      final src = File('lib/services/speech.dart').readAsStringSync();
      final start = src.indexOf('Future<VoskResult> recognizeOpen');
      expect(start, greaterThan(-1), reason: 'recognizeOpen 必须存在');
      final body = src.substring(start, start + 1600);
      final voskAt = body.indexOf('_transcriber.transcribeOpen');
      final enhancedAt = body.indexOf('EnhancedAsrService.instance');
      expect(voskAt, greaterThan(-1), reason: '一过必须先问 Vosk');
      expect(enhancedAt, greaterThan(-1), reason: '增强仍作兜底');
      expect(voskAt, lessThan(enhancedAt),
          reason: 'ASR-214：增强不得顶替 Vosk 成为主引擎');
    });
  });

  group('ASR-214 F3 句首被吞判「接近」', () {
    const ref = 'The main course was great.';

    test('真机文本 USE WAS GREAT → 嫌疑成立（不该记用户失败）', () {
      expect(
          onsetLossSuspected(
              target: 'main course', recognized: 'USE WAS GREAT', reference: ref),
          isTrue);
    });

    test('Vosk 丢 300–400ms 的 course was great → 嫌疑成立', () {
      for (final heard in ['course was great', 'in course was great']) {
        expect(
            onsetLossSuspected(
                target: 'main course', recognized: heard, reference: ref),
            isTrue,
            reason: heard);
      }
    });

    test('用户说了另一句话 → 不嫌疑（宁可漏判不误放行）', () {
      expect(
          onsetLossSuspected(
              target: 'main course',
              recognized: 'I want some coffee',
              reference: ref),
          isFalse);
    });

    test('识别文本不比参考句短（用户多说）→ 不嫌疑', () {
      expect(
          onsetLossSuspected(
              target: 'main course',
              recognized: 'and the main course was really great thanks',
              reference: ref),
          isFalse);
    });

    test('目标词其实全命中 → 交给判定层，这里不抢判', () {
      expect(
          onsetLossSuspected(
              target: 'main course',
              recognized: 'main course was great',
              reference: ref),
          isFalse);
    });

    test('整句跟读：目标即参考，丢首词同样落嫌疑', () {
      expect(
          onsetLossSuspected(
              target: ref, recognized: 'course was great', reference: ref),
          isTrue);
    });
  });

  group('ASR-214 F5 预算覆盖二过与降级', () {
    test('超预算返回 null（不抛、不卡 UI）', () async {
      final r = await withinBudget<String>(
          () => Future.delayed(const Duration(milliseconds: 300), () => 'x'),
          budget: const Duration(milliseconds: 50));
      expect(r, isNull);
    });

    test('预算内原样返回', () async {
      final r = await withinBudget<String>(() async => 'ok');
      expect(r, 'ok');
    });

    test('防复发：l4_step 的二过与降级都套在 withinBudget 里', () {
      final src = File('lib/steps/l4_step.dart').readAsStringSync();
      expect(src.contains('withinBudget<VoskResult>'), isTrue,
          reason: 'grammar 二过必须受预算约束');
      expect(src.contains('withinBudget<AsrRetryResult>'), isTrue,
          reason: 'M1 降级重识必须受预算约束');
      expect(src.contains('extraPhrases: _phrases'), isTrue,
          reason: 'ASR-214 F4：二过词表要含本级其他句/块');
    });
  });

  group('ASR-214 F2 诚实化：不再宣称无效热词', () {
    test('changelog 不许再写「热词」当既成能力', () {
      final src = File('lib/services/changelog.dart').readAsStringSync();
      // 1.8.5 起这条口径必须与实测一致：20M 的热词被 encoder 整条拒绝。
      final from = src.indexOf("  '1.8.5': [");
      final to = src.indexOf("  '1.8.4': [");
      expect(from, greaterThan(-1), reason: '1.8.5 必须有 changelog 语料');
      expect(to, greaterThan(from), reason: '条目顺序：1.8.5 在 1.8.4 之前');
      final latest = src.substring(from, to);
      expect(latest.contains('热词已生效'), isFalse);
      expect(latest.contains('增强识别'), isTrue, reason: '本版必须交代引擎位次调整');
    });
  });

  group('ASR-216 卡死出口', () {
    test('两次没听清就该把打字出口摊开（阈值单源）', () {
      expect(shouldOfferTypingFirst(0), isFalse);
      expect(shouldOfferTypingFirst(1), isFalse);
      expect(shouldOfferTypingFirst(2), isTrue);
      expect(shouldOfferTypingFirst(3), isTrue);
    });

    test('防复发：失败屏的一级打字按钮 + 跨屏记账都在', () {
      final step = File('lib/steps/l4_step.dart').readAsStringSync();
      expect(step.contains('shouldOfferTypingFirst(_voiceFails)'), isTrue,
          reason: '失败屏必须按次数决定是否摊开打字出口');
      expect(step.contains('_p.voiceFailCount(widget.chunk.id)'), isTrue,
          reason: '进屏必须读上次的失败账，否则补练回环仍是死循环');
      expect(step.contains('_p.noteVoiceFail(widget.chunk.id)'), isTrue,
          reason: '语音判不过要记一笔');
      expect(step.contains('_p.clearVoiceFails(widget.chunk.id)'), isTrue,
          reason: '任何通道通过都要清账');
      final loaders = File('lib/services/loaders.dart').readAsStringSync();
      for (final m in ['voiceFailCount', 'noteVoiceFail', 'clearVoiceFails']) {
        expect(loaders.contains(m), isTrue, reason: 'ProgressService 缺 $m');
      }
    });
  });

  group('ASR-217 上手卡与双通道', () {
    test('打字出口从第一次失败就在（不再等撞满两次）', () {
      final step = File('lib/steps/l4_step.dart').readAsStringSync();
      expect(step.contains('Text(shouldOfferTypingFirst(_voiceFails)'), isTrue,
          reason: '失败屏的打字出口必须无条件出现，文案按次数分级');
      expect(step.contains('说不清也没关系：直接把句子打出来，照样算过。'), isTrue);
    });

    test('新装走 3 行上手卡，且只讲实装存在的能力', () {
      final nav = File('lib/screens/nav.dart').readAsStringSync();
      expect(nav.contains('_showQuickStartCard(p)'), isTrue, reason: '新装分支必须真的弹卡');
      expect(nav.contains('setQuickStartSeen'), isTrue, reason: '只给一次');
      expect(nav.contains('三步上手'), isTrue);
      // 红线：上手卡里不许出现未实装的能力（P2-6 教训）
      expect(nav.contains('场景对话'), isFalse);
      expect(nav.contains('AI'), isFalse);
    });

    test('changelog 不再声称未实装的场景对话', () {
      final src = File('lib/services/changelog.dart').readAsStringSync();
      expect(src.contains('场景对话里的每一次块完成'), isFalse,
          reason: 'P2-6：该入口不存在，属文案超实装');
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/asr_guard.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';

void main() {
  group('guardAsr 文本启发式', () {
    test('空文本 → empty', () {
      final g = guardAsr(raw: '   ', wordConfidences: const []);
      expect(g.state, AsrGuardState.empty);
      expect(g.raw, '   '); // B5：原文原样保留（含空白）
      expect(g.ok, isFalse);
    });

    test('少于 2 词 → tooShort', () {
      final g = guardAsr(raw: 'hello', wordConfidences: const []);
      expect(g.state, AsrGuardState.tooShort);
    });

    test('同词重复 ≥3 → repeated', () {
      final g = guardAsr(raw: 'i i i get coffee', wordConfidences: const []);
      expect(g.state, AsrGuardState.repeated);
    });

    test('目标块词被堆高（超出块内词频）→ chunkStack', () {
      final g = guardAsr(
        raw: "coffee i'll get a coffee get",
        wordConfidences: const [1, 1, 1, 1, 1, 1],
        targetBlock: "I'll get a coffee",
        checkChunkStack: true,
      );
      expect(g.state, AsrGuardState.chunkStack);
    });

    test('恰好说对目标块（词频一致）不算堆叠', () {
      final g = guardAsr(
        raw: "I'll get a coffee.",
        wordConfidences: const [1, 1, 1, 1],
        targetBlock: "I'll get a coffee",
        checkChunkStack: true,
      );
      expect(g.state, AsrGuardState.ok);
    });

    test('目标块 + 额外实词 → 不算堆叠', () {
      final g = guardAsr(
        raw: "I'll get a coffee now",
        wordConfidences: const [1, 1, 1, 1, 1],
        targetBlock: "I'll get a coffee",
        checkChunkStack: true,
      );
      expect(g.state, AsrGuardState.ok);
    });
  });

  group('guardAsr 置信度门', () {
    test('均值 < 0.6 → lowConf', () {
      final g = guardAsr(
          raw: 'hello there friend',
          wordConfidences: const [0.5, 0.55, 0.5]);
      expect(g.state, AsrGuardState.lowConf);
    });

    test('低置信词占比 > 40% → lowConf（隔离均值门）', () {
      final g = guardAsr(
        raw: 'hello there my friend',
        wordConfidences: const [1.0, 1.0, 0.2, 0.3],
        confThreshold: 0.0,
        twoLowestThreshold: 0.0,
      );
      expect(g.state, AsrGuardState.lowConf);
      expect(g.lowConfRatio, 0.5);
    });

    test('最低两词均值 < 0.45 → lowConf（隔离均值/占比门）', () {
      final g = guardAsr(
        raw: 'what is ya you buy coffee',
        wordConfidences: const [0.9, 0.8, 0.225, 0.9, 0.9, 0.336],
        confThreshold: 0.0,
        lowWordRatio: 1.0,
      );
      expect(g.state, AsrGuardState.lowConf);
      expect(g.twoLowestAvg, closeTo(0.2805, 1e-9));
    });

    test('置信度字段缺失 → 只走文本启发式（不当作 0 拒判）', () {
      final g = guardAsr(
          raw: "I'll get a coffee", wordConfidences: const []);
      expect(g.state, AsrGuardState.ok);
      expect(g.confidence, isNull);
    });

    test('全部达标 → ok', () {
      final g = guardAsr(
          raw: "I'll get a coffee",
          wordConfidences: const [0.82, 0.91, 0.77, 0.88],
          targetBlock: "I'll get a coffee",
          checkChunkStack: true);
      expect(g.state, AsrGuardState.ok);
      expect(g.wordCount, 4);
      expect(g.chunkRatio, 1.0);
    });
  });

  group('三态文案', () {
    AsrGuardResult okGuard(String raw) => guardAsr(
        raw: raw, wordConfidences: const [1, 1, 1, 1]);

    test('命中 → ✓ 目标块用上了', () {
      final v = asrVerdictFor(
          guard: okGuard("I'll get a coffee"),
          targetHit: true,
          targetLabel: "I'll get a coffee");
      expect(v.kind, AsrVerdictKind.pass);
      expect(v.text, '✓ 目标块用上了');
    });

    test('没命中 → 原文 + 未用上目标块（chunkStyle）', () {
      final v = asrVerdictFor(
          guard: okGuard('I like tea very much'),
          targetHit: false,
          targetLabel: 'I need');
      expect(v.kind, AsrVerdictKind.notUsed);
      expect(v.text, '✗ 听到了「I like tea very much」，但没用上「I need」');
    });

    test('未命中（闭合跟读）→ 只说与目标不一致', () {
      final v = asrVerdictFor(
          guard: okGuard('good morning everyone'),
          targetHit: false,
          targetLabel: 'Good morning, everyone.',
          chunkStyle: false);
      expect(v.kind, AsrVerdictKind.notUsed);
      expect(v.text, '✗ 听到了「good morning everyone」，和目标句还不一致');
    });

    test('守门失败 → ⚠ 没听清，再说一遍（不论是否命中）', () {
      final g = guardAsr(raw: 'i i i', wordConfidences: const [0.1, 0.1, 0.1]);
      final v = asrVerdictFor(
          guard: g, targetHit: true, targetLabel: 'I need');
      expect(v.kind, AsrVerdictKind.retry);
      expect(v.text, '⚠ 没听清，再说一遍');
    });

    test('自定义通过文案（④ 替换）', () {
      final v = asrVerdictFor(
          guard: okGuard("I'll get a coffee"),
          targetHit: true,
          targetLabel: "I'll get a coffee",
          passText: '✓ 替换成功，句子说完整了');
      expect(v.text, '✓ 替换成功，句子说完整了');
    });
  });

  group('parseVoskFinalJson（B5 原文事实源）', () {
    test('text 一字不改 + 词级置信度全量保留', () {
      final raw = jsonEncode({
        'text': "coffee i'll get a coffee get",
        'result': [
          {'word': 'coffee', 'conf': 0.917927, 'start': 0.0, 'end': 0.4},
          {'word': "i'll", 'conf': 0.88, 'start': 0.4, 'end': 0.6},
          {'word': 'get', 'conf': 0.93, 'start': 0.6, 'end': 0.8},
          {'word': 'a', 'conf': 1.0, 'start': 0.8, 'end': 0.9},
          {'word': 'coffee', 'conf': 0.91, 'start': 0.9, 'end': 1.2},
          {'word': 'get', 'conf': 0.87, 'start': 1.2, 'end': 1.4},
        ],
      });
      final p = parseVoskFinalJson(raw);
      expect(p.text, "coffee i'll get a coffee get");
      expect(p.wordConfidences,
          [0.917927, 0.88, 0.93, 1.0, 0.91, 0.87]);
      expect(p.confidence, closeTo(0.9179878333, 1e-6));
    });

    test('顶层 confidence 存在时优先使用', () {
      final p = parseVoskFinalJson(jsonEncode({
        'text': 'hello there',
        'confidence': 0.73,
        'result': [
          {'word': 'hello', 'conf': 0.9},
          {'word': 'there', 'conf': 0.8},
        ],
      }));
      expect(p.confidence, 0.73);
      expect(p.wordConfidences, [0.9, 0.8]);
    });

    test('无置信度字段 → null + 空列表（不伪造 0）', () {
      final p = parseVoskFinalJson(jsonEncode({'text': 'good morning'}));
      expect(p.text, 'good morning');
      expect(p.confidence, isNull);
      expect(p.wordConfidences, isEmpty);
    });

    test('大小写/标点原样保留（解析层不改写）', () {
      final p = parseVoskFinalJson(jsonEncode({'text': 'Hello, World!'}));
      expect(p.text, 'Hello, World!');
    });
  });
}

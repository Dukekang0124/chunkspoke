import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/speech_judge.dart';

void main() {
  group('L1 规范化层', () {
    test('小写 / 去标点 / 压缩空格', () {
      expect(normalizeSpeech('  Hello,   WORLD!! '), 'hello world');
      expect(normalizeSpeech("Don't Stop!"), "don't stop");
      expect(tokenizeSpeech('  a  b '), ['a', 'b']);
    });
    test('大小写/标点不同但规范化后等价 → 走完全匹配快速通道', () {
      final r = judgeSpeech(target: "Don't stop", recognized: "DON'T STOP!");
      expect(r.pass, isTrue);
      expect(r.layer, 'exact');
    });
  });

  group('L2 完全匹配快速通道（不叠加置信度）', () {
    test('逐词完全一致 → 直接放行（本 P0 病灶：good morning）', () {
      final r = judgeSpeech(target: 'good morning', recognized: 'Good morning');
      expect(r.pass, isTrue);
      expect(r.reason, 'ok');
      expect(r.layer, 'exact');
      expect(r.similarity, 1.0);
    });
    test('完全一致但置信度极低(0.05) → 仍放行（快速通道不叠加置信度）', () {
      final r = judgeSpeech(
          target: 'good morning', recognized: 'good morning', confidence: 0.05);
      expect(r.pass, isTrue);
      expect(r.layer, 'exact');
    });
    test('置信度缺失(null) + 完全一致 → 放行', () {
      final r = judgeSpeech(
          target: 'good morning', recognized: 'good morning', confidence: null);
      expect(r.pass, isTrue);
    });
    test('过短录音(<0.4s) → 无效不判（tooShort，即便文本一致）', () {
      final r = judgeSpeech(
          target: 'good morning',
          recognized: 'good morning',
          durationSec: 0.2);
      expect(r.pass, isFalse);
      expect(r.reason, 'tooShort');
    });
  });

  group('L3 模糊层（文本不完全一致时）', () {
    test('单字容错 finis≈finish + 置信度缺失 → 按文本相似度放行', () {
      final r = judgeSpeech(
          target: 'I need to finish this report',
          recognized: 'i need to finis this report',
          confidence: null);
      expect(r.pass, isTrue);
      expect(r.layer, 'fuzzy');
    });
    test('相似度达标 + 置信度达标(0.5≥0.45) → 放行', () {
      final r = judgeSpeech(
          target: 'I need to finish this report',
          recognized: 'i need to finis this report',
          confidence: 0.5);
      expect(r.pass, isTrue);
    });
    test('相似度达标 + 置信度偏低(0.3<0.45) → 不通过（lowConf）', () {
      final r = judgeSpeech(
          target: 'I need to finish this report',
          recognized: 'i need to finis this report',
          confidence: 0.3);
      expect(r.pass, isFalse);
      expect(r.reason, 'lowConf');
    });
    test('漏词（相似度 6/7≈0.857<0.9）→ 不通过（lowSim）', () {
      final r = judgeSpeech(
          target: 'I need to finish this report today',
          recognized: 'i need to finish this report');
      expect(r.pass, isFalse);
      expect(r.reason, 'lowSim');
    });
    test('乱说（无关词）→ 不通过（核心词全丢）', () {
      final r = judgeSpeech(
          target: 'I need to finish this report today',
          recognized: 'blah blah pizza monkey');
      expect(r.pass, isFalse);
      expect(r.reason, 'lowCore');
      expect(r.coreHitRate, 0.0);
    });
    test('错词标红：targetMatched 标记未命中词', () {
      final r = judgeSpeech(target: 'cat dog bird', recognized: 'cat bird');
      expect(r.pass, isFalse);
      expect(r.targetMatched, [true, false, true]);
    });
  });

  group('内容词加权判定（P0 判定脆弱性修复）', () {
    test('丢冠词 a（核心词全中）→ 通过', () {
      final r = judgeSpeech(
          target: 'Grab a snack, okay?', recognized: 'grab snack okay');
      expect(r.pass, isTrue);
      expect(r.layer, 'fuzzy');
      expect(r.coreHitRate, 1.0);
    });

    test('核心词错音 snack→snake → 不通过', () {
      final r = judgeSpeech(target: 'grab a snack', recognized: 'grab a snake');
      expect(r.pass, isFalse);
      expect(r.reason, 'lowCore');
    });

    test('丢实词 today（核心词命中率 75% 但加权相似度不足）→ 仍不通过', () {
      final r = judgeSpeech(
          target: 'I need to finish this report today',
          recognized: 'i need to finish this report');
      expect(r.pass, isFalse);
      expect(r.reason, 'lowSim');
      expect(r.coreHitRate, 0.75);
    });

    test('虚词混淆 the→this 按同词处理 → 通过', () {
      final r = judgeSpeech(
          target: 'I have the menu', recognized: 'i have this menu');
      expect(r.pass, isTrue);
    });

    test('虚词 to→too 混淆 → 通过', () {
      final r = judgeSpeech(
          target: 'I need to finish', recognized: 'i need too finish');
      expect(r.pass, isTrue);
    });

    test('多说一个虚词（重复 a）→ 仍通过', () {
      final r = judgeSpeech(
          target: 'grab a snack', recognized: 'grab a a snack');
      expect(r.pass, isTrue);
    });

    test('语法限定识别致代词误为实词（me→meet 重复）→ 通过', () {
      final r = judgeSpeech(
          target: 'meet me at the station',
          recognized: 'meet meet at the station');
      expect(r.pass, isTrue);
    });

    test('多说一个实词（sec 重复）→ 通过（多说词轻罚）', () {
      final r = judgeSpeech(
          target: 'just a sec please', recognized: 'just a sec sec please');
      expect(r.pass, isTrue);
    });

    test('核心词错音（snack→snake）在放宽后仍被拒', () {
      final r = judgeSpeech(target: 'grab a snack', recognized: 'grab a snake');
      expect(r.pass, isFalse);
      expect(r.reason, 'lowCore');
    });
  });

  group('L1 空/静音（④）', () {
    test('空结果 → empty，不放行', () {
      final r = judgeSpeech(target: 'good morning', recognized: '');
      expect(r.pass, isFalse);
      expect(r.reason, 'empty');
    });
  });

  group('置信度定标（10 条正确样本 @阈值 0.45）', () {
    // 词级置信度样布（代表值，见 speech_judge.dart 末「阈值定标」）。
    const samples = [0.47, 0.52, 0.61, 0.45, 0.58, 0.66, 0.49, 0.55, 0.72, 0.50];
    test('全部 ≥ kConfThreshold(0.45) → 模糊层全放行', () {
      for (final c in samples) {
        final r = judgeSpeech(
            target: 'I need to finish this report',
            recognized: 'i need to finis this report', // 非完全一致 → 走模糊层
            confidence: c);
        expect(r.pass, isTrue, reason: 'conf=$c');
      }
    });
    test('阈值常量 = 0.45（能通过全部正确样本的最高阈值）', () {
      expect(kConfThreshold, 0.45);
    });
  });
}

import 'dart:io';

import 'package:chunkspoke_flutter/services/asr_budget.dart';
import 'package:chunkspoke_flutter/services/vosk_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// ASR-213（1.8.4 热修波）钉死两条新用户实测抓到的行为。
void main() {
  group('P0-1 识别预算', () {
    test('解码超预算 → 按空转写收口，不是抛错、不是继续等', () async {
      final slow = Future.delayed(
          const Duration(milliseconds: 120), () => const VoskResult('hello', 0.9));
      final sw = Stopwatch()..start();
      final r = await recognizeWithinBudget(() => slow,
          budget: const Duration(milliseconds: 40));
      sw.stop();
      expect(r.text, isEmpty);
      expect(r.confidence, isNull);
      // 收口必须真的发生在预算内（留 60ms 调度余量）。
      expect(sw.elapsed.inMilliseconds, lessThan(100));
    });

    test('预算内出结果 → 原样返回，不许把正常结果吃掉', () async {
      final r = await recognizeWithinBudget(
          () async => const VoskResult('hello there', 0.82),
          budget: const Duration(seconds: 3));
      expect(r.text, 'hello there');
      expect(r.confidence, 0.82);
    });

    test('预算与录音上限是单源常量，且上限 > 最短录音宽限', () {
      expect(kAsrBudget, const Duration(seconds: 3));
      expect(kRecordCap, const Duration(seconds: 12));
      // _graceTo2s 的最短录音是 2 秒；上限必须留足说完一句的余量。
      expect(kRecordCap.inSeconds, greaterThan(2));
    });
  });

  group('ASR-213 防复发闸：识别调用必须过预算', () {
    /// 生产里每一个 `recognizeOpen(` 调用点都必须包在 `recognizeWithinBudget` 内。
    /// 曾经漏过 4 处（含六步第 5 步「定向替换」），差点让 changelog 变成又一例文案超实装。
    /// 按「调用次数 ≤ 包装次数」整体比对，跨行写法也算得准。
    test('lib 下不存在没包预算的 recognizeOpen 调用', () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final p = f.path.replaceAll(r'\', '/');
        if (p.endsWith('services/asr_budget.dart') || p.endsWith('services/speech.dart')) {
          continue; // 前者是定义，后者是服务自身的转发
        }
        final src = f.readAsStringSync();
        final calls = 'recognizeOpen('.allMatches(src).length;
        if (calls == 0) continue;
        final wrapped = 'recognizeWithinBudget'.allMatches(src).length;
        if (wrapped < calls) bad.add('$p: 调用 $calls 处 / 包装 $wrapped 处');
      }
      expect(bad, isEmpty, reason: '这些识别调用没走 3 秒预算，静音会退回无限等待');
    });
  });

  group('P1-1 首启更新说明门控', () {
    test('全新安装（没记过版本、也没有旧一次性标记）→ 不弹', () {
      expect(
          shouldShowChangelog(
              seenForVersion: null,
              legacyOneShot: false,
              currentVersion: '1.8.4'),
          isFalse);
    });

    test('老用户从 ≤1.8.3 升上来（旧一次性标记已置位）→ 弹一次', () {
      expect(
          shouldShowChangelog(
              seenForVersion: null,
              legacyOneShot: true,
              currentVersion: '1.8.4'),
          isTrue);
    });

    test('同版本第二次启动 → 不弹', () {
      expect(
          shouldShowChangelog(
              seenForVersion: '1.8.4',
              legacyOneShot: true,
              currentVersion: '1.8.4'),
          isFalse);
    });

    test('已按版本记账、现在升到新版本 → 弹', () {
      expect(
          shouldShowChangelog(
              seenForVersion: '1.8.3',
              legacyOneShot: true,
              currentVersion: '1.8.4'),
          isTrue);
    });
  });
}

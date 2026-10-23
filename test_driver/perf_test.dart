import 'dart:async';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:test/test.dart';

void main() {
  group('scroll perf (SF same-rhythm)', () {
    late FlutterDriver driver;

    setUpAll(() async {
      driver = await FlutterDriver.connect();
    });

    tearDownAll(() async {
      await driver.close();
    });

    test('scroll list up/down 6 rounds', () async {
      // 等待主界面列表出现（数据保留：onboarding/ftue/ModelGate 均已是通过态）。
      final list = find.byType('ListView');
      await driver.waitFor(list, timeout: const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(seconds: 2));

      // 与 SF 测试同段同节奏：6 轮上滑/下滑，150ms 快速滑动 + 400ms 停顿。
      for (int i = 0; i < 6; i++) {
        await driver.scroll(list, 0.0, -600.0, const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await driver.scroll(list, 0.0, 600.0, const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    });
  });
}

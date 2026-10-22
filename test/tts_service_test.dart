import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/loaders.dart';

/// 可控的 TTS 适配器：按引擎声明语言集合，复现真机检测分支。
class FakeTtsAdapter implements TtsAdapter {
  final Map<String, Set<String>> voices;
  String? defaultEngine;

  /// isLanguageAvailable 误报 false 的引擎（小米小爱等），setLanguage 仍返回成功。
  final Set<String> quirkyEngines;
  int speakResult;
  int speakCalls = 0;
  final List<String> spoken = [];
  String? activeEngine;

  FakeTtsAdapter({
    required this.voices,
    this.defaultEngine,
    this.quirkyEngines = const {},
    this.speakResult = 1,
  }) {
    activeEngine =
        defaultEngine ?? (voices.isNotEmpty ? voices.keys.first : null);
  }

  @override
  Future<String?> getDefaultEngine() async => defaultEngine;

  @override
  Future<List<String>> getEngines() async => voices.keys.toList();

  @override
  Future<bool> isLanguageAvailable(String lang) async =>
      voices[activeEngine]?.contains(lang) ?? false;

  @override
  Future<bool> setLanguage(String lang) async {
    if (voices[activeEngine]?.contains(lang) == true) return true;
    return quirkyEngines.contains(activeEngine);
  }

  @override
  Future<void> setEngine(String engine) async => activeEngine = engine;

  @override
  Future<void> setSpeechRate(double rate) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<int> speak(String text) async {
    speakCalls++;
    spoken.add(text);
    return speakResult;
  }

  @override
  Future<void> stop() async {}
}

void main() {
  group('TtsService 检测分支', () {
    test('初始状态为 unknown', () {
      final s = TtsService(adapter: FakeTtsAdapter(voices: {}));
      expect(s.status, TtsStatus.unknown);
      expect(s.available, isFalse);
    });

    test('无默认引擎且无已安装引擎 → noEngine', () async {
      final adapter = FakeTtsAdapter(voices: {});
      final s = TtsService(adapter: adapter);
      await s.init();
      expect(s.status, TtsStatus.noEngine);
      expect(s.available, isFalse);
      expect(s.lastError, 'no-tts-engine');
      expect(s.diagnostic, contains('noEngine'));
    });

    test('有引擎但无英文语音 → noEnglish，并记录引擎名', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.xiaomi.tts': {'zh-CN'},
        },
        defaultEngine: 'com.xiaomi.tts',
      );
      final s = TtsService(adapter: adapter);
      await s.init();
      expect(s.status, TtsStatus.noEnglish);
      expect(s.available, isFalse);
      expect(s.activeEngine, 'com.xiaomi.tts');
      expect(s.lastError, contains('no-english-voice'));
      expect(s.diagnostic, contains('com.xiaomi.tts'));
    });

    test('默认引擎支持 en-US → ready', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.google.android.tts': {'en-US', 'zh-CN'},
        },
        defaultEngine: 'com.google.android.tts',
      );
      final s = TtsService(adapter: adapter);
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.available, isTrue);
      expect(s.language, 'en-US');
      expect(s.lastError, isNull);
    });

    test('默认引擎无英文 → 枚举切换第二引擎并命中 en-GB', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.xiaomi.tts': {'zh-CN'},
          'com.google.android.tts': {'en-GB'},
        },
        defaultEngine: 'com.xiaomi.tts',
      );
      final s = TtsService(adapter: adapter);
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.activeEngine, 'com.google.android.tts');
      expect(s.language, 'en-GB');
    });

    test('isLanguageAvailable 误报 false 时用 setLanguage 兜底', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.xiaomi.tts': {'zh-CN'},
        },
        defaultEngine: 'com.xiaomi.tts',
        quirkyEngines: {'com.xiaomi.tts'},
      );
      final s = TtsService(adapter: adapter);
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.language, 'en-US');
    });

    test('recheck 返回最新状态', () async {
      final adapter = FakeTtsAdapter(voices: {});
      final s = TtsService(adapter: adapter);
      await s.init();
      expect(await s.recheck(), TtsStatus.noEngine);
      adapter.voices['com.google.android.tts'] = {'en-US'};
      adapter.defaultEngine = 'com.google.android.tts';
      expect(await s.recheck(), TtsStatus.ready);
    });
  });

  group('TtsService 播放', () {
    test('检测失败后安装引擎，首次 speak 会现场重检并成功', () async {
      final adapter = FakeTtsAdapter(voices: {});
      final s = TtsService(adapter: adapter);
      await s.init();
      expect(s.status, TtsStatus.noEngine);

      // 模拟用户装好引擎后直接点朗读：speak 内部重初始化。
      adapter.voices['com.google.android.tts'] = {'en-US'};
      adapter.defaultEngine = 'com.google.android.tts';
      expect(await s.speak('Hello'), isTrue);
      expect(adapter.spoken, ['Hello']);
      expect(s.status, TtsStatus.ready);
    });

    test('引擎返回 0 → 重试一轮后仍失败，lastError 可诊断', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.google.android.tts': {'en-US'},
        },
        defaultEngine: 'com.google.android.tts',
        speakResult: 0,
      );
      final s = TtsService(adapter: adapter);
      expect(await s.speak('Hello'), isFalse);
      expect(adapter.speakCalls, 2);
      expect(s.lastError, 'tts-speak-returned-0');
    });

    test('未检测到引擎时 speak 返回 false 且不抛异常', () async {
      final adapter = FakeTtsAdapter(voices: {});
      final s = TtsService(adapter: adapter);
      expect(await s.speak('Hello'), isFalse);
      expect(adapter.speakCalls, 0);
      expect(s.lastError, 'no-tts-engine');
    });
  });
}

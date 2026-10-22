import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/hd_voice_types.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/tts_voice.dart';

Map<String, String> _v(
  String name, {
  String locale = 'en-US',
  String quality = 'normal',
  bool network = false,
  String latency = 'normal',
  List<String> features = const [],
}) =>
    {
      'name': name,
      'locale': locale,
      'quality': quality,
      'latency': latency,
      'network_required': network ? '1' : '0',
      'features': features.join('\t'),
    };

/// 同时具备检测与音色能力的假适配器。
class FakeVoiceAdapter implements TtsAdapter, TtsVoiceAdapter {
  final Map<String, Set<String>> langs;
  final List<Map<String, String>> voiceMaps;
  String? defaultEngine;
  String? activeEngine;

  int speakResult;
  int speakCalls = 0;
  final List<String> spoken = [];
  final List<String> appliedVoices = [];
  int clearVoiceCalls = 0;
  int fetchVoicesCalls = 0;

  FakeVoiceAdapter({
    required this.langs,
    required this.voiceMaps,
    this.defaultEngine,
    this.speakResult = 1,
  }) {
    activeEngine =
        defaultEngine ?? (langs.isNotEmpty ? langs.keys.first : null);
  }

  @override
  Future<String?> getDefaultEngine() async => defaultEngine;

  @override
  Future<List<String>> getEngines() async => langs.keys.toList();

  @override
  Future<bool> isLanguageAvailable(String lang) async =>
      langs[activeEngine]?.contains(lang) ?? false;

  @override
  Future<bool> setLanguage(String lang) async =>
      langs[activeEngine]?.contains(lang) ?? false;

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

  @override
  Future<List<Map<String, String>>> fetchVoices() async {
    fetchVoicesCalls++;
    return voiceMaps;
  }

  @override
  Future<bool> setVoice(TtsVoice voice) async {
    appliedVoices.add(voice.key);
    return true;
  }

  @override
  Future<void> clearVoice() async => clearVoiceCalls++;
}

void main() {
  group('声音排序', () {
    const order = ['com.google.android.tts', 'com.xiaomi.tts'];

    TtsVoice v(
      String name, {
      String locale = 'en-US',
      String quality = 'normal',
      bool network = false,
      String latency = 'normal',
      bool installed = true,
      String engine = 'com.google.android.tts',
    }) =>
        TtsVoice(
          name: name,
          locale: locale,
          engine: engine,
          quality: quality,
          networkRequired: network,
          latency: latency,
          installed: installed,
        );

    test('质量优先，network 破同分，离线高质排在联网普通之前', () {
      final ranked = rankTtsVoices([
        v('a-normal-net', quality: 'normal', network: true),
        v('b-high-local', quality: 'high'),
        v('c-high-net', quality: 'high', network: true),
        v('d-veryhigh-local', quality: 'very high'),
        v('e-low-net', quality: 'low', network: true),
      ], engineOrder: order);
      expect(ranked.map((e) => e.name).toList(), [
        'd-veryhigh-local',
        'c-high-net',
        'b-high-local',
        'a-normal-net',
        'e-low-net'
      ]);
    });

    test('en-US 永远优先于其他英语变体，即使档位更低', () {
      final ranked = rankTtsVoices([
        v('gb', locale: 'en-GB', quality: 'very high'),
        v('us', quality: 'low'),
      ], engineOrder: order);
      expect(ranked.first.name, 'us');
      expect(ranked.last.name, 'gb');
    });

    test('过滤未安装语音与非英文声音', () {
      final ranked = rankTtsVoices([
        v('missing', quality: 'very high', installed: false),
        v('zh', locale: 'zh-CN', quality: 'very high'),
        v('ok'),
      ], engineOrder: order);
      expect(ranked.map((e) => e.name), ['ok']);
    });

    test('同档位按引擎顺序，其次名称', () {
      final ranked = rankTtsVoices([
        v('z', engine: 'com.xiaomi.tts'),
        v('b', engine: 'com.google.android.tts'),
        v('a', engine: 'com.google.android.tts'),
      ], engineOrder: order);
      expect(ranked.map((e) => e.name), ['a', 'b', 'z']);
    });

    test('延迟参与同分排序', () {
      final ranked = rankTtsVoices([
        v('slow', latency: 'high'),
        v('fast', latency: 'very low'),
      ], engineOrder: order);
      expect(ranked.first.name, 'fast');
    });

    test('持久化键可往返，脏数据返回 null', () {
      final voice = v('x', engine: 'com.google.android.tts');
      expect(TtsVoice.fromKey(voice.key)?.key, voice.key);
      expect(TtsVoice.fromKey(null), isNull);
      expect(TtsVoice.fromKey(''), isNull);
      expect(TtsVoice.fromKey('a|b'), isNull);
      expect(TtsVoice.fromKey('|b|c'), isNull);
    });

    test('标签展示 locale + 口音 + 档位 + 联网/离线', () {
      expect(v('x', quality: 'very high', network: true).label,
          'en-US · 美式 · 极高 · 联网');
      expect(v('x', quality: 'normal').label, 'en-US · 美式 · 标准 · 离线');
      expect(v('x', locale: 'en-GB').label, 'en-GB · 英式 · 标准 · 离线');
      expect(v('x', locale: 'en-GB').isUsEnglish, isFalse);
      expect(v('x').isUsEnglish, isTrue);
    });
  });

  group('TtsService 音色优选与切换', () {
    FakeVoiceAdapter adapter({List<Map<String, String>>? voices}) =>
        FakeVoiceAdapter(
          langs: {
            'com.google.android.tts': {'en-US'},
          },
          defaultEngine: 'com.google.android.tts',
          voiceMaps: voices ??
              [
                _v('v-normal'),
                _v('v-high', quality: 'high'),
                _v('v-high-net', quality: 'high', network: true),
              ],
        );

    test('初始化后自动选中排序第一的声音', () async {
      final a = adapter();
      final s = TtsService(adapter: a);
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.selectedVoice?.name, 'v-high-net');
      expect(a.appliedVoices, ['com.google.android.tts|v-high-net|en-US']);
      expect(s.autoVoice?.name, 'v-high-net');
    });

    test('分支一：设备有 en-US → 语言与自动优选均为美式', () async {
      final a = FakeVoiceAdapter(
        langs: {
          'com.google.android.tts': {'en-US', 'en-GB'},
        },
        defaultEngine: 'com.google.android.tts',
        voiceMaps: [
          _v('us', quality: 'normal'),
          _v('gb', locale: 'en-GB', quality: 'very high'),
        ],
      );
      final s = TtsService(adapter: a);
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.language, 'en-US');
      expect(s.autoVoice?.locale, 'en-US');
      expect(s.selectedVoice?.locale, 'en-US');
      expect(s.selectedVoice?.label, contains('美式'));
    });

    test('分支二：设备仅有 en-GB → 回退英式并在 UI 标注', () async {
      final a = FakeVoiceAdapter(
        langs: {
          'com.google.android.tts': {'en-GB'},
        },
        defaultEngine: 'com.google.android.tts',
        voiceMaps: [_v('gb', locale: 'en-GB', quality: 'high')],
      );
      final s = TtsService(adapter: a);
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.language, 'en-GB');
      expect(s.autoVoice?.locale, 'en-GB');
      expect(s.selectedVoice?.locale, 'en-GB');
      expect(s.selectedVoice?.isUsEnglish, isFalse);
      expect(s.selectedVoice?.label, contains('英式'));
    });

    test('分支三：完全无 en-* → noEnglish，落 TTS 引导页', () async {
      final a = FakeVoiceAdapter(
        langs: {
          'com.google.android.tts': {'zh-CN'},
        },
        defaultEngine: 'com.google.android.tts',
        voiceMaps: [_v('zh', locale: 'zh-CN', quality: 'very high')],
      );
      final s = TtsService(adapter: a);
      await s.init();
      expect(s.status, TtsStatus.noEnglish);
      expect(s.available, isFalse);
      expect(s.language, isNull);
      expect(s.autoVoice, isNull);
      expect(s.selectedVoice, isNull);
      expect(s.voices, isEmpty);
    });

    test('持久化偏好命中时优先于自动优选', () async {
      final a = adapter();
      final s = TtsService(
        adapter: a,
        preferredVoice: () => 'com.google.android.tts|v-normal|en-US',
      );
      await s.init();
      expect(s.selectedVoice?.name, 'v-normal');
    });

    test('持久化偏好失效（换引擎/语音包升级）回落自动优选', () async {
      final a = adapter();
      final s = TtsService(
        adapter: a,
        preferredVoice: () => 'com.other|gone|en-US',
      );
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.selectedVoice?.name, 'v-high-net');
    });

    test('切换指定音色后生效；selectVoice(null) 恢复自动优选', () async {
      final a = adapter();
      final s = TtsService(adapter: a);
      await s.init();
      final target = s.voices.firstWhere((v) => v.name == 'v-normal');
      expect(await s.selectVoice(target), isTrue);
      expect(s.selectedVoice?.name, 'v-normal');
      expect(await s.selectVoice(null), isTrue);
      expect(s.selectedVoice?.name, 'v-high-net');
    });

    test('逐行试听切到该声音并直接走系统引擎（高清启用也不拦截）', () async {
      final a = adapter();
      final hd = _FakeHd();
      final s = TtsService(adapter: a, hdVoice: hd);
      await s.init();
      final target = s.voices.firstWhere((v) => v.name == 'v-normal');
      expect(await s.auditionVoice(target), isTrue);
      expect(s.selectedVoice?.name, 'v-normal');
      expect(a.appliedVoices.last, target.key);
      expect(a.spoken.single, TtsService.kAuditionText);
      expect(hd.speakCalls, 0);
    });

    test('逐行试听失败返回 false 并记录可读原因', () async {
      final a = adapter()..speakResult = 0;
      final s = TtsService(adapter: a);
      await s.init();
      final target = s.voices.firstWhere((v) => v.name == 'v-normal');
      expect(await s.auditionVoice(target), isFalse);
      expect(s.lastError, 'tts-speak-returned-0');
    });

    test('引擎无声音列表时仍为 ready，selected 为空不抛异常', () async {
      final a = adapter(voices: []);
      final s = TtsService(adapter: a);
      await s.init();
      expect(s.status, TtsStatus.ready);
      expect(s.selectedVoice, isNull);
      expect(await s.listVoices(), isEmpty);
    });

    test('语音包未安装的声音不会被自动选中', () async {
      final a = adapter(voices: [
        _v('not-ready', quality: 'very high', features: ['notInstalled']),
        _v('ready', quality: 'normal'),
      ]);
      final s = TtsService(adapter: a);
      await s.init();
      expect(s.selectedVoice?.name, 'ready');
    });

    test('首选音色无声时回落引擎默认声音重试一次', () async {
      final a = adapter()..speakResult = 1;
      final s = TtsService(adapter: a);
      await s.init();
      a.speakResult = 0;
      // 首次返回 0 → 清空音色 → 第二次仍返回 0：共 2 次，且发生过 clearVoice。
      expect(await s.speak('Hello'), isFalse);
      expect(a.speakCalls, 2);
      expect(a.clearVoiceCalls, greaterThanOrEqualTo(1));
      expect(s.lastError, 'tts-speak-returned-0');
    });

    test('切换音色失败时回落引擎默认并返回 false', () async {
      final a = _FailingVoiceAdapter();
      final s = TtsService(adapter: a);
      await s.init();
      final target = s.voices.first;
      expect(await s.selectVoice(target), isFalse);
      expect(s.selectedVoice, isNull);
      expect(a.clearVoiceCalls, greaterThanOrEqualTo(1));
    });
  });

  group('自然朗读参数标定', () {
    test('默认语速 0.22 = Android 0.44，实测 154 wpm（14 词 / 5.46s）', () {
      // flutter_tts 在 Android 侧把 rate×2；0.22 落在真人对话 140–160 wpm。
      expect(TtsService.kRate, 0.22);
      expect(TtsService.kPitch, 1.0);
    });
  });
}

/// 高清包始终可用：验证系统音色试听不会被高清源截走。
class _FakeHd implements HdVoiceSpeaker {
  int speakCalls = 0;

  @override
  bool get active => true;

  @override
  Future<bool> speak(String text) async {
    speakCalls++;
    return true;
  }

  @override
  Future<void> stop() async {}
}

/// setVoice 恒失败：验证回落链路。
class _FailingVoiceAdapter extends FakeVoiceAdapter {
  _FailingVoiceAdapter()
      : super(
          langs: {
            'com.google.android.tts': {'en-US'},
          },
          defaultEngine: 'com.google.android.tts',
          voiceMaps: [_v('v1', quality: 'high')],
        );

  @override
  Future<bool> setVoice(TtsVoice voice) async {
    appliedVoices.add(voice.key);
    return false;
  }
}

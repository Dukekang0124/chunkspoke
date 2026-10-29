import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/hd_voice_types.dart';
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

  /// 下发过的语速/音高序列 + 每次 speak 时刻的实际语速。
  /// 「每次发声前都按档位下发」这条只能这样验，不能只看最后一次调用。
  final List<double> rates = [];
  final List<double> pitches = [];
  final List<double> rateAtSpeak = [];

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
  Future<void> setSpeechRate(double rate) async => rates.add(rate);

  @override
  Future<void> setPitch(double pitch) async => pitches.add(pitch);

  @override
  Future<int> speak(String text) async {
    speakCalls++;
    spoken.add(text);
    rateAtSpeak.add(rates.isEmpty ? -1 : rates.last);
    return speakResult;
  }

  @override
  Future<void> stop() async {}
}

/// 只实现发声接口的高清包假实现（TtsService 只需要 active/speak/stop）。
class FakeHdSpeaker implements HdVoiceSpeaker {
  FakeHdSpeaker({this.active = true, this.speakResult = true});

  @override
  bool active;
  bool speakResult;
  int speakCalls = 0;

  @override
  Future<bool> speak(String text) async {
    speakCalls++;
    return speakResult;
  }

  @override
  Future<void> stop() async {}
}

/// 同时具备「预渲染」与「读到句末」能力的假适配器：
/// 用来钉住「同一档位下，预渲染段与 live 段下发同一语速」。
class FakeFullTts extends FakeTtsAdapter
    implements TtsSynthAdapter, TtsAwaitAdapter {
  FakeFullTts()
      : super(voices: {
          'com.google.android.tts': {'en-US'},
        }, defaultEngine: 'com.google.android.tts');

  final List<double> rateAtSynth = [];
  final List<double> rateAtAwait = [];

  @override
  Future<bool> synthesizeToFile(String text, String fileName) async {
    rateAtSynth.add(rates.isEmpty ? -1 : rates.last);
    return true;
  }

  @override
  Future<bool> speakAndWait(String text) async {
    rateAtAwait.add(rates.isEmpty ? -1 : rates.last);
    return true;
  }
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

  // §30.5 S-1..S-4：语速档位单源化。以下五条是发版前钉死的回归：
  // 1) 标准档参数不变（不回归成 0.9 倍速）；2) 档位真的下发；3) 指定语速后
  // 恢复的是当前档位；4) 高清失败回落=甲（发声成功+一次打点）；5) 禁用高清
  // 不误报回落，且仍按档位发声。
  group('发音参数单源（VoiceProfile）', () {
    TtsService withSpeed(
      TtsSpeed speed, {
      FakeTtsAdapter? adapter,
      HdVoiceSpeaker? hd,
      List<List<Object?>>? events,
    }) {
      final a = adapter ??
          FakeTtsAdapter(
            voices: {
              'com.google.android.tts': {'en-US'},
            },
            defaultEngine: 'com.google.android.tts',
          );
      return TtsService(
        adapter: a,
        readProfile: () => VoiceProfile(speed: speed),
        hdVoice: hd,
        onEvent: events == null ? null : (e, p) => events.add([e, p]),
      );
    }

    test('标准档仍是 0.22 / 1.0，且每次 speak 前都下发', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.google.android.tts': {'en-US'},
        },
        defaultEngine: 'com.google.android.tts',
      );
      final s = withSpeed(TtsSpeed.normal, adapter: adapter);
      expect(s.profile.rate, 0.22);
      expect(s.profile.pitch, 1.0);
      await s.speak('Hello');
      // init 时下发过一次，speak 前又按档位下发一次；发声瞬间必须是档位值。
      expect(adapter.rateAtSpeak.single, closeTo(0.22, 1e-9));
      expect(adapter.pitches.last, 1.0);
    });

    test('慢档 0.75× / 快档 1.25× 真的下发到引擎', () async {
      for (final (speed, want) in [
        (TtsSpeed.slow, 0.165),
        (TtsSpeed.fast, 0.275),
      ]) {
        final adapter = FakeTtsAdapter(
          voices: {
            'com.google.android.tts': {'en-US'},
          },
          defaultEngine: 'com.google.android.tts',
        );
        final s = withSpeed(speed, adapter: adapter);
        expect(await s.speak('Hello'), isTrue);
        expect(adapter.rateAtSpeak.single, closeTo(want, 1e-9),
            reason: '档位 ${speed.name} 未下发');
      }
    });

    test('指定语速播完恢复当前档位，不是写死的 kRate', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.google.android.tts': {'en-US'},
        },
        defaultEngine: 'com.google.android.tts',
      );
      final s = withSpeed(TtsSpeed.slow, adapter: adapter);
      expect(await s.speakAtRate('Hello', 0.32), isTrue);
      expect(adapter.rates, contains(closeTo(0.32, 1e-9)));
      expect(adapter.rates.last, closeTo(0.165, 1e-9));
    });

    test('高清失败 → 回落系统照常发声，只记一次 tts_hd_fallback（甲）', () async {
      final events = <List<Object?>>[];
      final adapter = FakeTtsAdapter(
        voices: {
          'com.google.android.tts': {'en-US'},
        },
        defaultEngine: 'com.google.android.tts',
      );
      final hd = FakeHdSpeaker(speakResult: false);
      final s = withSpeed(TtsSpeed.normal, adapter: adapter, hd: hd, events: events);
      expect(await s.speak('Hello'), isTrue, reason: '高清失败也必须发出声音');
      expect(hd.speakCalls, 1);
      expect(adapter.speakCalls, 1);
      expect(s.hdFellBack, isTrue);
      expect(events.where((e) => e[0] == 'tts_hd_fallback').length, 1);

      // 第二次仍失败：发声照旧，但不重复打点（避免一次故障刷成百条事件）。
      expect(await s.speak('Again'), isTrue);
      expect(events.where((e) => e[0] == 'tts_hd_fallback').length, 1);
    });

    test('禁用高清包 → 不误报回落，仍按档位发声', () async {
      final events = <List<Object?>>[];
      final adapter = FakeTtsAdapter(
        voices: {
          'com.google.android.tts': {'en-US'},
        },
        defaultEngine: 'com.google.android.tts',
      );
      final hd = FakeHdSpeaker(active: false);
      final s = withSpeed(TtsSpeed.fast, adapter: adapter, hd: hd, events: events);
      expect(await s.speak('Hello'), isTrue);
      expect(hd.speakCalls, 0);
      expect(s.hdFellBack, isFalse);
      expect(events, isEmpty);
      expect(adapter.rateAtSpeak.single, closeTo(0.275, 1e-9));
    });

    test('档位非标准时不走高清（固定语速），只走系统引擎', () async {
      final adapter = FakeTtsAdapter(
        voices: {
          'com.google.android.tts': {'en-US'},
        },
        defaultEngine: 'com.google.android.tts',
      );
      final hd = FakeHdSpeaker();
      final s = withSpeed(TtsSpeed.slow, adapter: adapter, hd: hd);
      expect(await s.speak('Hello'), isTrue);
      expect(hd.speakCalls, 0, reason: '高清是固定语速，选了慢就不能播原速');
      expect(adapter.speakCalls, 1);
    });

    test('同档同速：预渲染（synthesizeToFile）与 live（speakAndWait）一致', () async {
      // 磨耳朵同一篇文章里，两段走的都是 VoiceProfile；这里钉死「同档下发同值」，
      // 防其中一条路径以后又自己写死速率（§30.5 回归第 4 条）。
      for (final (speed, want) in [
        (TtsSpeed.slow, 0.165),
        (TtsSpeed.normal, 0.22),
        (TtsSpeed.fast, 0.275),
      ]) {
        final a = FakeFullTts();
        final s = withSpeed(speed, adapter: a);
        expect(await s.synthesizeToFile('A', '/tmp/a.wav', hd: false), isTrue);
        expect(await s.speakAndWait('B'), isTrue);
        expect(a.rateAtSynth.single, closeTo(want, 1e-9));
        expect(a.rateAtAwait.single, closeTo(want, 1e-9));
        expect(a.rateAtSynth.single, a.rateAtAwait.single);
      }
    });

    test('脏档位键回落标准档，不抛异常', () {
      expect(TtsSpeed.fromKey('slower'), TtsSpeed.normal);
      expect(TtsSpeed.fromKey(null), TtsSpeed.normal);
      expect(TtsSpeed.fromKey(''), TtsSpeed.normal);
      expect(TtsSpeed.fromKey('fast'), TtsSpeed.fast);
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chunkspoke_flutter/services/hd_voice.dart';
import 'package:chunkspoke_flutter/services/hd_voice_types.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/vosk_model.dart';
import 'package:chunkspoke_flutter/services/wav_codec.dart';

class _FakeDownloader implements HdVoiceDownloader {
  _FakeDownloader(this.dir);
  final String dir;
  final _progress = StreamController<ModelProgress>.broadcast();
  bool ready = false;
  Object? ensureError;
  int ensureCalls = 0;
  int resetCalls = 0;
  int discardCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<ModelProgress> get progress => _progress.stream;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<String> modelDirPath() async => dir;

  @override
  Future<String> ensureModel() async {
    ensureCalls++;
    if (ensureError != null) throw ensureError!;
    ready = true;
    return dir;
  }

  @override
  Future<void> resetIncomplete() async => resetCalls++;

  @override
  Future<void> discard() async {
    discardCalls++;
    ready = false;
  }

  @override
  void dispose() => disposeCalls++;

  void emit(ModelProgress p) => _progress.add(p);
}

class _FakeSynth implements HdVoiceSynth {
  Object? initError;
  Object? synthError;
  bool inited = false;
  int initCalls = 0;
  int synthCalls = 0;
  int disposeCalls = 0;
  double? lastSpeed;
  String? lastDir;
  HdAudio audio =
      HdAudio(Float32List.fromList([0.0, 0.5, -0.5, 0.25]), 22050);

  @override
  Future<void> init(String modelDir) async {
    initCalls++;
    if (initError != null) throw initError!;
    lastDir = modelDir;
    inited = true;
  }

  @override
  Future<HdAudio> synthesize(String text, {required double speed}) async {
    synthCalls++;
    lastSpeed = speed;
    if (synthError != null) throw synthError!;
    return audio;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    inited = false;
  }
}

class _FakePlayer implements HdVoicePlayer {
  final List<String> played = [];
  int stops = 0;
  int disposed = 0;
  bool failPlay = false;

  @override
  Future<void> playWav(String path) async {
    if (failPlay) throw StateError('player failed');
    played.add(path);
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async => disposed++;
}

ModelManifest _dummyManifest() => ModelManifest(
      name: 'hd-voice',
      modelVersion: 'v1',
      sha256: List.filled(64, 'a').join(),
      size: 1,
      parts: const [ModelPart('https://example.test/voice.part0', 1)],
    );

ModelManifest _voiceManifest(String name, int size) => ModelManifest(
      name: name,
      modelVersion: '$name-v1',
      sha256: List.filled(64, 'd').join(),
      size: size,
      parts: [
        ModelPart('https://cdn.test/$name/voice.part0', size ~/ 2),
        ModelPart('https://cdn.test/$name/voice.part1', size - size ~/ 2),
      ],
      mirrorUrl: 'https://cdn.test/$name.zip',
    );

List<HdVoiceOption> _multiCatalog() => [
      HdVoiceOption(
        label: '清晰女声',
        desc: '标准美音 · 清晰',
        manifest: _voiceManifest('voice-a', 100),
      ),
      HdVoiceOption(
        label: '温暖男声',
        desc: '低沉 · 稍慢',
        manifest: _voiceManifest('voice-b', 200),
      ),
      HdVoiceOption(
        label: '轻快女声',
        desc: '明亮 · 有起伏',
        manifest: _voiceManifest('voice-c', 300),
      ),
    ];

HdVoiceService _service({
  required _FakeDownloader downloader,
  required _FakeSynth synth,
  required _FakePlayer player,
  required bool Function() isEnabled,
  required Future<void> Function(bool) setEnabled,
  required Directory cache,
  void Function(String, Map<String, dynamic>)? onEvent,
}) {
  return HdVoiceService(
    manifest: _dummyManifest(),
    downloader: downloader,
    synthFactory: () => synth,
    player: player,
    cacheDir: () async => cache,
    isEnabled: isEnabled,
    setEnabled: setEnabled,
    onEvent: onEvent,
  );
}

Uint8List _tinyZip() {
  final archive = Archive();
  archive.addFile(ArchiveFile('hdvoice/model.onnx', 0,
      Uint8List.fromList(List.generate(600, (i) => i % 251))));
  archive.addFile(
      ArchiveFile('hdvoice/tokens.txt', 0, Uint8List.fromList([1, 2, 3])));
  archive.addFile(ArchiveFile('hdvoice/espeak-ng-data/phondata', 0,
      Uint8List.fromList(List.generate(50, (i) => i))));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

class _FakeHd implements HdVoiceSpeaker {
  _FakeHd({this.speakResult = true});
  @override
  bool active = true;
  bool speakResult;
  int speakCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> speak(String text) async {
    speakCalls++;
    return speakResult;
  }

  @override
  Future<void> stop() async => stopCalls++;
}

class _SysTts implements TtsAdapter {
  _SysTts({this.english = true});
  final bool english;
  int speakCalls = 0;
  int stopCalls = 0;

  @override
  Future<String?> getDefaultEngine() async => 'sys.tts';
  @override
  Future<List<String>> getEngines() async => ['sys.tts'];
  @override
  Future<bool> isLanguageAvailable(String lang) async => english;
  @override
  Future<bool> setLanguage(String lang) async => english;
  @override
  Future<void> setEngine(String engine) async {}
  @override
  Future<void> setSpeechRate(double rate) async {}
  @override
  Future<void> setPitch(double pitch) async {}
  @override
  Future<int> speak(String text) async {
    speakCalls++;
    return 1;
  }

  @override
  Future<void> stop() async => stopCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WAV 编码', () {
    test('RIFF/WAVE 头字段与 PCM 长度正确', () {
      final bytes = encodeWav(Float32List.fromList([0, 1, -1]), 22050);
      final bd = ByteData.sublistView(bytes);
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
      expect(ascii.decode(bytes.sublist(36, 40)), 'data');
      expect(bd.getUint32(4, Endian.little), bytes.length - 8);
      expect(bd.getUint16(22, Endian.little), 1, reason: 'mono');
      expect(bd.getUint32(24, Endian.little), 22050);
      expect(bd.getUint16(34, Endian.little), 16);
      expect(bd.getUint32(40, Endian.little), 6);
      expect(bd.getInt16(44, Endian.little), 0);
      expect(bd.getInt16(46, Endian.little), 32767);
      expect(bd.getInt16(48, Endian.little), -32767);
    });

    test('时长/峰值/RMS', () {
      final s = Float32List.fromList(List.filled(22050, 0.5));
      expect(wavSeconds(s, 22050), closeTo(1.0, 1e-9));
      final lv = wavLevels(s);
      expect(lv.peak, closeTo(0.5, 1e-6));
      expect(lv.rms, closeTo(0.5, 1e-6));
    });
  });

  group('高清发音包清单', () {
    String fixture() => jsonEncode({
          'voiceModel': {
            'name': 'hd-voice-piper-en-us-medium',
            'modelVersion': 'v1',
            'sha256': List.filled(64, 'b').join(),
            'size': 30,
            'parts': [
              {
                'url': 'https://cdn.example/voice.part0',
                'size': 10,
                'sha256': List.filled(64, 'c').join(),
                'fallbacks': ['https://raw.example/voice.part0'],
              },
              {'url': 'https://cdn.example/voice.part1', 'size': 20},
            ],
            'mirrorUrl': 'https://cdn.example/pack.zip',
          }
        });

    test('解析并校验分块长度之和', () {
      final m = parseHdVoiceManifest(fixture());
      expect(m.name, 'hd-voice-piper-en-us-medium');
      expect(m.parts.length, 2);
      expect(m.isValid, isTrue);
      expect(m.parts.first.fallbacks, contains('https://raw.example/voice.part0'));
    });

    test('本地模拟通道重写全部 URL', () {
      final m = parseHdVoiceManifest(fixture(), base: 'http://10.0.2.2:8899');
      expect(m.parts[0].url, 'http://10.0.2.2:8899/voice.part0');
      expect(m.parts[1].url, 'http://10.0.2.2:8899/voice.part1');
      expect(m.parts[0].sha256, List.filled(64, 'c').join());
      expect(m.mirrorUrl,
          'http://10.0.2.2:8899/hd-voice-piper-en-us-medium.zip');
    });

    test('缺段/坏段', () {
      expect(() => parseHdVoiceManifest('{}'), throwsFormatException);
      expect(
          () => parseHdVoiceManifest(jsonEncode({
                'voiceModel': {
                  'name': 'x',
                  'modelVersion': '1',
                  'sha256': List.filled(64, 'b').join(),
                  'size': 20,
                  'parts': [
                    {'url': 'https://a.test/p0', 'size': 10}
                  ]
                }
              })),
          throwsFormatException);
    });

    test('随包 version.json 的 voiceModel 段自洽', () {
      final raw = File('assets/version.json').readAsStringSync();
      final m = parseHdVoiceManifest(raw);
      expect(m.name, 'hd-voice-piper-en-us-medium');
      expect(m.parts.length, 4);
      expect(m.isValid, isTrue);
      expect(m.size, 58873277);
      for (final p in m.parts) {
        expect(p.sha256.length, 64);
        expect(p.fallbacks.length, 2);
      }
    });

    test('磁盘写满错误统一提示存储不足', () {
      expect(
          friendlyHdError(const FileSystemException(
              'write failed', '/data/x', OSError('No space left on device', 28))),
          contains('存储空间不足'));
      expect(friendlyHdError(StateError('ENOSPC')), contains('存储空间不足'));
    });
  });

  group('自然人声目录', () {
    Map<String, dynamic> voiceJson(String name, String label, String desc) => {
          'name': name,
          'label': label,
          'desc': desc,
          'modelVersion': '$name-v1',
          'sha256': List.filled(64, 'e').join(),
          'size': 30,
          'parts': [
            {'url': 'https://cdn.example/$name/voice.part0', 'size': 10},
            {'url': 'https://cdn.example/$name/voice.part1', 'size': 20},
          ],
          'mirrorUrl': 'https://cdn.example/$name.zip',
        };

    String catalog(List<Map<String, dynamic>> voices) => jsonEncode({
          'voiceModel': {
            'voices': voices,
            'name': 'legacy-single',
            'modelVersion': 'legacy-v1',
            'sha256': List.filled(64, 'f').join(),
            'size': 30,
            'parts': [
              {'url': 'https://cdn.example/voice.part0', 'size': 10},
              {'url': 'https://cdn.example/voice.part1', 'size': 20},
            ],
          }
        });

    test('voices[] 优先：顺序、标签、独立清单', () {
      final list = parseHdVoiceCatalog(catalog([
        voiceJson('voice-a', '清晰女声', '标准美音'),
        voiceJson('voice-b', '温暖男声', '低沉'),
      ]));
      expect(list.map((e) => e.id), ['voice-a', 'voice-b']);
      expect(list.map((e) => e.label), ['清晰女声', '温暖男声']);
      expect(list.map((e) => e.desc), ['标准美音', '低沉']);
      expect(list.every((e) => e.manifest.isValid), isTrue);
      expect(list.first.manifest.modelVersion, 'voice-a-v1');
    });

    test('坏音色跳过；全坏报错；空数组回退顶层单音色', () {
      final list = parseHdVoiceCatalog(catalog([
        voiceJson('voice-a', '清晰女声', ''),
        {
          'name': 'broken',
          'modelVersion': 'x',
          'sha256': List.filled(64, 'e').join(),
          'size': 99,
          'parts': [
            {'url': 'https://cdn.example/broken/voice.part0', 'size': 10}
          ],
        },
      ]));
      expect(list.map((e) => e.id), ['voice-a']);

      expect(
          () => parseHdVoiceCatalog(catalog([
                {
                  'name': 'broken',
                  'modelVersion': 'x',
                  'sha256': List.filled(64, 'e').join(),
                  'size': 99,
                  'parts': [
                    {'url': 'https://cdn.example/broken/voice.part0', 'size': 10}
                  ],
                }
              ])),
          throwsFormatException);

      final legacy = parseHdVoiceCatalog(catalog(const []));
      expect(legacy.single.id, 'legacy-single');
      expect(legacy.single.label, '清晰女声');
    });

    test('本地模拟通道按音色分目录重写 URL', () {
      final list = parseHdVoiceCatalog(
          catalog([voiceJson('voice-a', 'A', ''), voiceJson('voice-b', 'B', '')]),
          base: 'http://10.0.2.2:8899');
      expect(list[0].manifest.parts[0].url,
          'http://10.0.2.2:8899/voice-a/voice.part0');
      expect(list[1].manifest.parts[1].url,
          'http://10.0.2.2:8899/voice-b/voice.part1');
      expect(list[1].manifest.mirrorUrl,
          'http://10.0.2.2:8899/voice-b/voice-b.zip');
    });

    test('随包 version.json 为 3 音色目录，且顶层仍兼容旧单音色', () {
      final raw = File('assets/version.json').readAsStringSync();
      final list = parseHdVoiceCatalog(raw);
      expect(list.map((e) => e.id), [
        'hd-voice-piper-en-us-medium',
        'hd-voice-piper-en-us-kristin-medium',
        'hd-voice-piper-en-us-joe-medium',
      ]);
      expect(list.map((e) => e.label), ['清晰女声', '温和女声', '沉稳男声']);
      expect(list.every((e) => e.manifest.isValid), isTrue);
      expect(list.every((e) => e.desc.isNotEmpty), isTrue);
      // 1.5.7 客户端只读顶层：默认音色必须与 voices[] 首项同字节。
      final legacy = parseHdVoiceManifest(raw);
      expect(legacy.name, list.first.manifest.name);
      expect(legacy.sha256, list.first.manifest.sha256);
      expect(legacy.parts.first.sha256, list.first.manifest.parts.first.sha256);
    });
  });

  group('HdVoiceService 状态机', () {
    late Directory tmp;
    late _FakeDownloader loader;
    late _FakeSynth synth;
    late _FakePlayer player;
    late bool enabled;
    late HdVoiceService svc;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hd_voice_test');
      loader = _FakeDownloader(tmp.path);
      synth = _FakeSynth();
      player = _FakePlayer();
      enabled = false;
      svc = _service(
        downloader: loader,
        synth: synth,
        player: player,
        isEnabled: () => enabled,
        setEnabled: (v) async => enabled = v,
        cache: tmp,
      );
    });

    tearDown(() async {
      svc.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('下载成功自动启用，合成落 WAV 并交给原生播放', () async {
      await svc.init();
      expect(svc.ready, isFalse);
      expect(svc.active, isFalse);

      await svc.download();
      expect(loader.ensureCalls, 1);
      expect(svc.ready, isTrue);
      expect(svc.enabled, isTrue);
      expect(enabled, isTrue);
      expect(svc.active, isTrue);

      final ok = await svc.speak("I'd like a cup of coffee.");
      expect(ok, isTrue);
      expect(synth.initCalls, 1);
      expect(synth.synthCalls, 1);
      expect(synth.lastSpeed, HdVoiceService.kSpeed);
      expect(player.played.length, 1);
      final f = File(player.played.single);
      expect(await f.exists(), isTrue);
      expect(f.readAsBytesSync().sublist(0, 4), 'RIFF'.codeUnits);
      expect(svc.engineUp, isTrue);
    });

    test('下载失败给出友好文案；重试先清残再成功', () async {
      await svc.init();
      loader.ensureError =
          const ModelDownloadException('高清发音包下载失败，请检查网络后重试');
      await svc.download();
      expect(svc.error, '高清发音包下载失败，请检查网络后重试');
      expect(svc.ready, isFalse);
      expect(svc.active, isFalse);

      loader.ensureError = null;
      await svc.download(retry: true);
      expect(loader.resetCalls, 1);
      expect(svc.error, isNull);
      expect(svc.ready, isTrue);
      expect(svc.active, isTrue);
    });

    test('切回系统发音后不再合成/播放', () async {
      loader.ready = true;
      enabled = true;
      await svc.init();
      expect(svc.active, isTrue);

      await svc.setEnabled(false);
      expect(enabled, isFalse);
      expect(svc.active, isFalse);
      expect(await svc.speak('hello'), isFalse);
      expect(synth.synthCalls, 0);
      expect(player.played, isEmpty);
    });

    test('已配置但未下载 → 不接管发音', () async {
      await svc.init();
      expect(svc.ready, isFalse);
      expect(await svc.speak('hello'), isFalse);
    });

    test('引擎初始化失败 → speak 返回 false 并记录可读原因', () async {
      loader.ready = true;
      enabled = true;
      synth.initError = StateError('lib missing');
      await svc.init();
      expect(await svc.speak('hello'), isFalse);
      expect(svc.engineError, contains('删除后重新下载'));
      expect(player.played, isEmpty);
    });

    test('合成失败 → 不播放，错误可读', () async {
      loader.ready = true;
      enabled = true;
      synth.synthError = StateError('infer failed');
      await svc.init();
      expect(await svc.speak('hello'), isFalse);
      expect(svc.error, contains('已切回系统发音'));
      expect(player.played, isEmpty);
    });

    test('播放失败 → speak 返回 false（由上层回落系统）', () async {
      loader.ready = true;
      enabled = true;
      player.failPlay = true;
      await svc.init();
      expect(await svc.speak('hello'), isFalse);
      expect(svc.error, contains('已切回系统发音'));
    });

    test('stop 停止原生播放；删除清理包、关闭开关并释放引擎', () async {
      loader.ready = true;
      enabled = true;
      await svc.init();
      await svc.speak('hello');
      await svc.stop();
      expect(player.stops, greaterThanOrEqualTo(1));

      await svc.delete();
      expect(loader.discardCalls, 1);
      expect(svc.ready, isFalse);
      expect(svc.enabled, isFalse);
      expect(enabled, isFalse);
      expect(synth.disposeCalls, 1);
    });

    test('重启后删除（内存无音频路径）仍清掉缓存 WAV', () async {
      final cached = File('${tmp.path}/last.wav');
      await cached.writeAsBytes([1, 2, 3]);
      loader.ready = true;
      enabled = true;
      await svc.init();
      await svc.delete();
      expect(cached.existsSync(), isFalse);
    });
  });

  group('HdVoiceService 多音色', () {
    late Directory tmp;
    late Map<String, _FakeDownloader> loaders;
    late List<HdVoiceOption> voices;
    late _FakePlayer player;
    late bool enabled;
    late String? persisted;
    late List<List<Object>> events;
    late List<_FakeSynth> created;
    late HdVoiceService svc;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('hd_voice_multi');
      voices = _multiCatalog();
      loaders = {};
      for (final v in voices) {
        final dir = Directory('${tmp.path}/${v.id}');
        await dir.create(recursive: true);
        loaders[v.id] = _FakeDownloader(dir.path);
      }
      player = _FakePlayer();
      enabled = false;
      persisted = null;
      events = [];
      created = [];
      svc = HdVoiceService(
        voices: voices,
        downloaderFactory: (m) => loaders[m.name]!,
        synthFactory: () {
          final s = _FakeSynth();
          created.add(s);
          return s;
        },
        player: player,
        cacheDir: () async => tmp,
        isEnabled: () => enabled,
        setEnabled: (v) async => enabled = v,
        readVoiceId: () => persisted,
        persistVoiceId: (id) async => persisted = id,
        onEvent: (n, p) => events.add([n, p]),
      );
    });

    tearDown(() async {
      svc.dispose();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('启动时优先上次选择，其次第一个已装音色', () async {
      loaders['voice-b']!.ready = true;
      persisted = 'voice-b';
      await svc.init();
      expect(svc.activeVoiceId, 'voice-b');
      expect(svc.activeVoice?.label, '温暖男声');
      expect(svc.ready, isTrue);

      persisted = 'voice-c';
      final svc2 = HdVoiceService(
        voices: voices,
        downloaderFactory: (m) => loaders[m.name]!,
        synthFactory: _FakeSynth.new,
        player: _FakePlayer(),
        cacheDir: () async => tmp,
        isEnabled: () => false,
        setEnabled: (_) async {},
        readVoiceId: () => 'voice-c',
      );
      loaders['voice-c']!.ready = false;
      await svc2.init();
      expect(svc2.activeVoiceId, 'voice-b', reason: '未装的选择不生效，落到已装音色');
      svc2.dispose();
    });

    test('下载指定音色：独立下载、立即生效并持久化', () async {
      await svc.init();
      expect(svc.activeVoiceId, 'voice-a');
      await svc.downloadVoice('voice-b');
      expect(loaders['voice-b']!.ensureCalls, 1);
      expect(loaders['voice-a']!.ensureCalls, 0);
      expect(svc.isReady('voice-b'), isTrue);
      expect(svc.isReady('voice-a'), isFalse);
      expect(svc.activeVoiceId, 'voice-b');
      expect(persisted, 'voice-b');
      expect(svc.enabled, isTrue);
      expect(enabled, isTrue);
      expect(events.map((e) => e[0]), contains('hd_dl_done'));
    });

    test('未下载音色不可切换；切换已装音色重置引擎并持久化', () async {
      loaders['voice-a']!.ready = true;
      loaders['voice-b']!.ready = true;
      enabled = true;
      await svc.init();
      expect(svc.activeVoiceId, 'voice-a');

      await svc.selectVoice('voice-c');
      expect(svc.activeVoiceId, 'voice-a');
      expect(events.map((e) => e[0]), isNot(contains('hd_voice_select')));

      expect(await svc.speak('hello'), isTrue);
      expect(created.single.lastDir, '${tmp.path}/voice-a');
      final firstSynth = created.single;

      await svc.selectVoice('voice-b');
      expect(svc.activeVoiceId, 'voice-b');
      expect(persisted, 'voice-b');
      expect(firstSynth.disposeCalls, 1);
      expect(events.map((e) => e[0]), contains('hd_voice_select'));

      expect(await svc.speak('hello'), isTrue);
      expect(created.last.lastDir, '${tmp.path}/voice-b');
    });

    test('删除生效音色回落到其他已装音色；删光关闭接管', () async {
      loaders['voice-a']!.ready = true;
      loaders['voice-b']!.ready = true;
      enabled = true;
      await svc.init();
      expect(svc.activeVoiceId, 'voice-a');

      await svc.deleteVoice('voice-a');
      expect(loaders['voice-a']!.discardCalls, 1);
      expect(svc.isReady('voice-a'), isFalse);
      expect(svc.activeVoiceId, 'voice-b');
      expect(persisted, 'voice-b');
      expect(svc.enabled, isTrue);

      await svc.deleteVoice('voice-b');
      expect(svc.ready, isFalse);
      expect(svc.enabled, isFalse);
      expect(enabled, isFalse);
    });

    test('单音色下载失败不污染其他音色状态', () async {
      loaders['voice-b']!.ensureError =
          const ModelDownloadException('高清发音包下载失败，请检查网络后重试');
      await svc.init();
      await svc.downloadVoice('voice-b');
      expect(svc.errorFor('voice-b'), '高清发音包下载失败，请检查网络后重试');
      expect(svc.errorFor('voice-a'), isNull);
      expect(svc.isReady('voice-a'), isFalse);
      expect(svc.activeVoiceId, 'voice-a');
      expect(svc.ready, isFalse);
    });

    test('下载进度按音色隔离', () async {
      await svc.init();
      loaders['voice-b']!.emit(const ModelProgress(
          phase: ModelPhase.downloading, received: 5, total: 200));
      await Future<void>.delayed(Duration.zero);
      expect(svc.progressFor('voice-b')?.received, 5);
      expect(svc.progressFor('voice-a'), isNull);
    });

    test('占用统计按音色累加已装包', () async {
      loaders['voice-a']!.ready = true;
      loaders['voice-b']!.ready = true;
      await svc.init();
      await File('${tmp.path}/voice-a/model.bin').writeAsBytes(List.filled(10, 1));
      await File('${tmp.path}/voice-a/tokens.txt').writeAsBytes([1, 2]);
      await File('${tmp.path}/voice-b/model.bin').writeAsBytes(List.filled(20, 1));
      expect(await svc.sizeOf('voice-a'), 12);
      expect(await svc.sizeOf('voice-b'), 20);
      expect(await svc.installedBytes(), 32);
    });

    test('引擎加载失败自动落到另一已装音色并记事件', () async {
      loaders['voice-a']!.ready = true;
      loaders['voice-b']!.ready = true;
      persisted = 'voice-b';
      enabled = true;
      await svc.init();
      expect(svc.activeVoiceId, 'voice-b');
      final firstSynth = created.single;
      firstSynth.initError = StateError('bad model dir');

      expect(await svc.speak('hello'), isTrue);
      expect(svc.activeVoiceId, 'voice-a');
      expect(persisted, 'voice-a');
      expect(firstSynth.disposeCalls, 1);
      expect(created.last.lastDir, '${tmp.path}/voice-a');
      expect(events.map((e) => e[0]), contains('hd_voice_fallback'));
      expect(player.played.length, 1);
    });
  });

  group('TtsService 双源切换', () {
    test('高清启用时优先高清，不调用系统引擎', () async {
      final sys = _SysTts();
      final hd = _FakeHd();
      final tts = TtsService(adapter: sys, hdVoice: hd);
      await tts.init();
      expect(await tts.speak('hello'), isTrue);
      expect(hd.speakCalls, 1);
      expect(sys.speakCalls, 0);
      expect(tts.hdActive, isTrue);
    });

    test('高清失败 → 回落系统引擎且仍成功', () async {
      final sys = _SysTts();
      final hd = _FakeHd(speakResult: false);
      final tts = TtsService(adapter: sys, hdVoice: hd);
      await tts.init();
      expect(await tts.speak('hello'), isTrue);
      expect(hd.speakCalls, 1);
      expect(sys.speakCalls, 1);
    });

    test('系统无英文但高清启用 → available 为 true（引导页放行）', () async {
      final sys = _SysTts(english: false);
      final hd = _FakeHd();
      final tts = TtsService(adapter: sys, hdVoice: hd);
      await tts.init();
      expect(tts.status, TtsStatus.noEnglish);
      expect(tts.available, isTrue);
    });

    test('stop 同时停高清与系统', () async {
      final sys = _SysTts();
      final hd = _FakeHd();
      final tts = TtsService(adapter: sys, hdVoice: hd);
      await tts.init();
      await tts.stop();
      expect(hd.stopCalls, 1);
      expect(sys.stopCalls, 1);
    });
  });

  group('高清包下载观测埋点（首启完成率单独口径）', () {
    test('下载成功 → hd_dl_start + hd_dl_done，带体积', () async {
      final tmp = await Directory.systemTemp.createTemp('hd_evt');
      final loader = _FakeDownloader(tmp.path);
      final events = <List<Object>>[];
      final svc = _service(
        downloader: loader,
        synth: _FakeSynth(),
        player: _FakePlayer(),
        isEnabled: () => false,
        setEnabled: (_) async {},
        cache: tmp,
        onEvent: (n, p) => events.add([n, p]),
      );
      await svc.init();
      await svc.download();
      expect(events.map((e) => e[0]), ['hd_dl_start', 'hd_dl_done']);
      expect((events.first[1] as Map)['size'], _dummyManifest().size);
      expect(svc.ready, isTrue);
      svc.dispose();
    });

    test('下载失败 → hd_dl_fail 带可读原因，且不影响后续重试', () async {
      final tmp = await Directory.systemTemp.createTemp('hd_evt2');
      final loader = _FakeDownloader(tmp.path)..ensureError = 'boom';
      final events = <List<Object>>[];
      final svc = _service(
        downloader: loader,
        synth: _FakeSynth(),
        player: _FakePlayer(),
        isEnabled: () => false,
        setEnabled: (_) async {},
        cache: tmp,
        onEvent: (n, p) => events.add([n, p]),
      );
      await svc.init();
      await svc.download();
      expect(events.map((e) => e[0]), ['hd_dl_start', 'hd_dl_fail']);
      expect(((events.last[1] as Map)['err'] ?? '').toString().isNotEmpty, isTrue);
      expect(svc.ready, isFalse);
      svc.dispose();
    });
  });

  group('高清包下载链（复用 B3）', () {
    test('已有半块 → Range 对齐续传 → 整包校验 → 流式解压', () async {
      final zip = _tinyZip();
      final sizes = [zip.length ~/ 3, zip.length ~/ 3, 0];
      sizes[2] = zip.length - sizes[0] - sizes[1];
      final parts = <ModelPart>[];
      var off = 0;
      for (var i = 0; i < 3; i++) {
        final bytes = zip.sublist(off, off + sizes[i]);
        parts.add(ModelPart('https://cdn.test/voice.part$i', sizes[i],
            sha256: sha256.convert(bytes).toString()));
        off += sizes[i];
      }
      final manifest = ModelManifest(
        name: 'hdvoice',
        modelVersion: 'v1',
        sha256: sha256.convert(zip).toString(),
        size: zip.length,
        parts: parts,
      );

      final base = await Directory.systemTemp.createTemp('hd_dl');
      final resumeAt = sizes[1] ~/ 2;
      // 模拟“续传到一半”：磁盘上已有 part1 前半段。
      final whole2 = zip.sublist(sizes[0], sizes[0] + sizes[1]);
      await File('${base.path}/hdvoice.zip.part1')
          .writeAsBytes(whole2.sublist(0, resumeAt), flush: true);

      final ranges = <String>[];
      final client = MockClient((req) async {
        final i = int.parse(RegExp(r'voice\.part(\d)').firstMatch(req.url.path)!.group(1)!);
        final body = zip.sublist(
            i == 0 ? 0 : i == 1 ? sizes[0] : sizes[0] + sizes[1],
            i == 0
                ? sizes[0]
                : i == 1
                    ? sizes[0] + sizes[1]
                    : zip.length);
        final range = req.headers['range'];
        if (i == 1 && range != null) {
          ranges.add(range);
          final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          expect(from, resumeAt);
          return http.Response.bytes(body.sublist(from), 206, headers: {
            'content-range': 'bytes $from-${sizes[i] - 1}/${sizes[i]}',
          });
        }
        return http.Response.bytes(body, 200);
      });

      final manager = ModelManager(
        manifest: manifest,
        client: client,
        baseDir: () async => base,
        retryDelay: Duration.zero,
        autoRetryRounds: 0,
      );
      final dir = await manager.ensureModel();
      expect(ranges, isNotEmpty);
      expect(await manager.isReady(), isTrue);
      expect(File('$dir/model.onnx').existsSync(), isTrue);
      expect(File('$dir/espeak-ng-data/phondata').existsSync(), isTrue);
      expect(File('${base.path}/hdvoice.zip').existsSync(), isFalse);
      expect(File('${base.path}/hdvoice.zip.part1').existsSync(), isFalse);
      manager.dispose();
      await base.delete(recursive: true);
    });
  });
}

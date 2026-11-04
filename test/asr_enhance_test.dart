import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/services/vosk_model.dart';
import 'package:chunkspoke_flutter/services/zipformer_asr.dart';

ModelManifest _manifest({int size = 43649301}) => ModelManifest(
      name: 'sherpa-onnx-streaming-zipformer-en-20M-2023-02-17',
      modelVersion: '2023-02-17-int8',
      sha256: 'a' * 64,
      size: size,
      parts: [ModelPart('https://example.invalid/asr.part0', size, sha256: 'b' * 64)],
    );

class _FakeStore implements AsrModelStore {
  _FakeStore({this.ready = false, this.fail = false});
  bool ready;
  bool fail;
  int ensured = 0;
  final StreamController<ModelProgress> _progress =
      StreamController<ModelProgress>.broadcast();

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<String> ensureModel() async {
    ensured++;
    if (fail) throw const ModelDownloadException('模拟下载失败');
    ready = true;
    _progress.add(const ModelProgress(
        phase: ModelPhase.downloading, received: 10, total: 10));
    return '/tmp/asr-model';
  }

  @override
  Future<String> modelDirPath() async => '/tmp/asr-model';

  @override
  Stream<ModelProgress> get getProgress => _progress.stream;
}

class _FakeBackend implements AsrBackend {
  _FakeBackend({this.failInit = false, this.text = 'hello world'});
  final bool failInit;
  final String text;
  bool _loaded = false;
  int initCalls = 0;
  int disposeCalls = 0;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> init(String modelDir) async {
    initCalls++;
    if (failInit) throw StateError('模拟加载失败');
    _loaded = true;
  }

  @override
  Future<String> transcribe(String wavPath,
      {List<String> hotwords = const []}) async {
    lastHotwords = hotwords;
    return text;
  }

  List<String> lastHotwords = const [];

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _loaded = false;
  }
}

void main() {
  group('pcm16ToFloat32', () {
    test('小端 16 位按 /32768 归一', () {
      final b = ByteData(8)
        ..setInt16(0, 0, Endian.little)
        ..setInt16(2, 16384, Endian.little)
        ..setInt16(4, -16384, Endian.little)
        ..setInt16(6, 32767, Endian.little);
      final out = pcm16ToFloat32(b.buffer.asUint8List());
      expect(out.length, 4);
      expect(out[0], 0);
      expect(out[1], closeTo(0.5, 1e-6));
      expect(out[2], closeTo(-0.5, 1e-6));
      expect(out[3], closeTo(32767 / 32768, 1e-6));
    });

    test('空音频返回空表，不抛异常', () {
      expect(pcm16ToFloat32(Uint8List(0)), isEmpty);
    });

    test('奇数尾字节被丢弃（保持 16 位对齐）', () {
      expect(pcm16ToFloat32(Uint8List.fromList([1, 2, 3])).length, 1);
    });
  });

  group('AsrBackendPrefs', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('asr_prefs_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('无文件时默认关闭（默认仍 Vosk）', () async {
      final p = AsrBackendPrefs(dir: () async => dir);
      expect(await p.enhancedEnabled(), isFalse);
    });

    test('写入 true 后读回 true，写回 false 后读回 false', () async {
      final p = AsrBackendPrefs(dir: () async => dir);
      await p.setEnhancedEnabled(true);
      expect(await p.enhancedEnabled(), isTrue);
      await p.setEnhancedEnabled(false);
      expect(await p.enhancedEnabled(), isFalse);
    });

    test('文件损坏不抛错，按关闭处理', () async {
      final f = File('${dir.path}/asr_backend.json');
      await f.writeAsString('{not json');
      final p = AsrBackendPrefs(dir: () async => dir);
      expect(await p.enhancedEnabled(), isFalse);
    });
  });

  group('EnhancedAsrService', () {
    late Directory dir;
    late AsrBackendPrefs prefs;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('asr_svc_');
      prefs = AsrBackendPrefs(dir: () async => dir);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('未启用时开放识别直接返回 null（不创建后端、不加载模型）', () async {
      var created = 0;
      final store = _FakeStore(ready: true);
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => store,
        createBackend: () {
          created++;
          return _FakeBackend();
        },
        prefs: prefs,
      );
      await svc.refresh();
      expect(svc.installed, isTrue);
      expect(svc.enabled, isFalse);
      expect(await svc.transcribeOpen('/tmp/a.wav'), isNull);
      expect(created, 0);
    });

    test('已启用且模型在盘：走增强后端并返回文本', () async {
      await prefs.setEnhancedEnabled(true);
      final backend = _FakeBackend(text: 'I would like a cup of coffee');
      final store = _FakeStore(ready: true);
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => store,
        createBackend: () => backend,
        prefs: prefs,
      );
      await svc.refresh();
      final r = await svc.transcribeOpen('/tmp/a.wav');
      expect(r, isNotNull);
      expect(r!.text, 'I would like a cup of coffee');
      // sherpa 不产出置信度 → null，判定层按文本相似度走，不当 0 拒判。
      expect(r.confidence, isNull);
      expect(backend.initCalls, 1);
      // 第二次复用常驻后端，不重复加载。
      await svc.transcribeOpen('/tmp/b.wav');
      expect(backend.initCalls, 1);
    });

    test('ASR-209 B 层：目标热词随开放识别下传到后端', () async {
      await prefs.setEnhancedEnabled(true);
      final backend = _FakeBackend();
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => _FakeStore(ready: true),
        createBackend: () => backend,
        prefs: prefs,
      );
      await svc.refresh();
      await svc.transcribeOpen('/tmp/a.wav',
          hotwords: asrHotwordsFrom("I'd like the menu, please."));
      expect(backend.lastHotwords, ['I', 'D', 'LIKE', 'THE', 'MENU', 'PLEASE']);
    });

    test('ASR-209 B 层：热词归一化=大写纯字母、去重、限量', () {
      expect(asrHotwordsFrom('Good morning, everyone.'),
          ['GOOD', 'MORNING', 'EVERYONE']);
      expect(asrHotwordsFrom("it's a test — a TEST!"),
          ['IT', 'S', 'A', 'TEST']);
      expect(asrHotwordsFrom(''), isEmpty);
      expect(asrHotwordsFrom('one two three four five', max: 3),
          ['ONE', 'TWO', 'THREE']);
    });

    test('后端加载失败 → 返回 null 留给 Vosk，并留下可读原因', () async {
      await prefs.setEnhancedEnabled(true);
      final store = _FakeStore(ready: true);
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => store,
        createBackend: () => _FakeBackend(failInit: true),
        prefs: prefs,
      );
      await svc.refresh();
      expect(await svc.transcribeOpen('/tmp/a.wav'), isNull);
      expect(svc.lastError, contains('回落 Vosk'));
    });

    test('关闭开关会释放常驻识别器（切回默认）', () async {
      await prefs.setEnhancedEnabled(true);
      final backend = _FakeBackend();
      final store = _FakeStore(ready: true);
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => store,
        createBackend: () => backend,
        prefs: prefs,
      );
      await svc.refresh();
      await svc.transcribeOpen('/tmp/a.wav');
      expect(await svc.setEnabled(false), isTrue);
      expect(backend.disposeCalls, 1);
      expect(await prefs.enhancedEnabled(), isFalse);
      expect(await svc.transcribeOpen('/tmp/b.wav'), isNull);
    });

    test('下载并启用：走自家存储 → 初始化后端 → 持久化开关', () async {
      final store = _FakeStore();
      final backend = _FakeBackend();
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => store,
        createBackend: () => backend,
        prefs: prefs,
      );
      await svc.refresh();
      expect(svc.installed, isFalse);
      expect(await svc.downloadAndEnable(), isTrue);
      expect(store.ensured, 1);
      expect(svc.installed, isTrue);
      expect(svc.enabled, isTrue);
      expect(await prefs.enhancedEnabled(), isTrue);
      expect(svc.ready, isTrue);
    });

    test('下载失败：保持关闭并可重试', () async {
      final store = _FakeStore(fail: true);
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => store,
        createBackend: () => _FakeBackend(),
        prefs: prefs,
      );
      await svc.refresh();
      expect(await svc.downloadAndEnable(), isFalse);
      expect(svc.enabled, isFalse);
      expect(svc.lastError, isNotNull);
      expect(await prefs.enhancedEnabled(), isFalse);
    });

    test('清单缺失：下载与识别都失败关闭，不崩', () async {
      final svc = EnhancedAsrService(
        loadManifest: () async => null,
        createStore: (_) async => _FakeStore(),
        createBackend: () => _FakeBackend(),
        prefs: prefs,
      );
      await svc.refresh();
      expect(svc.installed, isFalse);
      expect(await svc.transcribeOpen('/tmp/a.wav'), isNull);
      expect(await svc.downloadAndEnable(), isFalse);
      expect(svc.lastError, contains('清单缺失'));
    });

    test('体积展示用十进制 MB（与 ASR-190 口径一致）', () async {
      final svc = EnhancedAsrService(
        loadManifest: () async => _manifest(),
        createStore: (_) async => _FakeStore(),
        createBackend: () => _FakeBackend(),
        prefs: prefs,
      );
      await svc.refresh();
      expect(svc.modelSizeLabel, '43.65 MB');
    });
  });
}

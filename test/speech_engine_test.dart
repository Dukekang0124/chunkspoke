import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chunkspoke_flutter/services/vosk_engine.dart';
import 'package:chunkspoke_flutter/services/vosk_model.dart';

Uint8List _makeZip() {
  final archive = Archive();
  archive.addFile(
      ArchiveFile('mymodel/conf/mf.conf', 0, Uint8List.fromList([0x61, 0x62, 0x63])));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ModelManifest _manifest(List<int> zip) {
  return ModelManifest(
    name: 'mymodel',
    modelVersion: '0.1',
    sha256: sha256.convert(zip).toString(),
    size: zip.length,
    parts: [
      ModelPart('https://x/m.part0', zip.length,
          sha256: sha256.convert(zip).toString()),
    ],
  );
}

/// 单一分块客户端；[failTimes] > 0 时前几次请求抛错。
MockClient _client(List<int> zip, {int failTimes = 0}) {
  var fails = 0;
  return MockClient((req) async {
    if (fails < failTimes) {
      fails++;
      throw Exception('no net');
    }
    return http.Response.bytes(zip, 200,
        headers: {'content-type': 'application/octet-stream'});
  });
}

Future<(Directory, ModelManager)> _setup({int failTimes = 0}) async {
  final zip = _makeZip();
  final manifest = _manifest(zip);
  final tmp = Directory.systemTemp.createTempSync('engine_');
  final mgr = ModelManager(
      manifest: manifest,
      client: _client(zip, failTimes: failTimes),
      baseDir: () async => tmp,
      retryDelay: Duration.zero,
      autoRetryRounds: 0);
  addTearDown(() => tmp.deleteSync(recursive: true));
  return (tmp, mgr);
}

void main() {
  group('SpeechEngine 六态状态机', () {
    test('缺失 → 下载 → 就绪', () async {
      final (_, mgr) = await _setup();
      final engine = SpeechEngine.forTesting(manager: mgr, createModel: (_) async => true);
      expect(await engine.init(), isTrue);
      expect(engine.state, EngineState.ready);
    });

    test('下载失败 → failed（可读原因）', () async {
      final (_, mgr) = await _setup(failTimes: 99);
      final engine = SpeechEngine.forTesting(manager: mgr, createModel: (_) async => true);
      expect(await engine.init(), isFalse);
      expect(engine.state, EngineState.failed);
      expect(engine.lastError, isNotNull);
    });

    test('失败 → 重试 → 就绪（同 manager 复用进度）', () async {
      // 首轮下载失败落到 failed，再验证第二次 init 成功。
      final (_, mgr) = await _setup(failTimes: 1);
      final engine = SpeechEngine.forTesting(manager: mgr, createModel: (_) async => true);
      expect(await engine.init(), isFalse);
      expect(engine.state, EngineState.failed);
      expect(await engine.init(), isTrue);
      expect(engine.state, EngineState.ready);
    });

    test('createModel 失败 1 次 → failed（可重试），重试 → 就绪', () async {
      final (_, mgr) = await _setup();
      var calls = 0;
      final engine = SpeechEngine.forTesting(manager: mgr, createModel: (_) async {
        calls++;
        return calls > 1; // 第 1 次失败，之后成功
      });
      expect(await engine.init(), isFalse);
      expect(engine.state, EngineState.failed);
      expect(engine.lastError, contains('请重试'));
      expect(await engine.init(), isTrue);
      expect(engine.state, EngineState.ready);
    });

    test('createModel 失败 ≥2 次 → 视为损坏 → discard 回缺失（硬化④）', () async {
      final (_, mgr) = await _setup();
      final engine = SpeechEngine.forTesting(manager: mgr, createModel: (_) async => false);
      expect(await engine.init(), isFalse);
      expect(engine.lastError, contains('请重试'));
      expect(await engine.init(), isFalse);
      expect(engine.lastError, contains('损坏'));
      expect(engine.state, EngineState.failed);
      // 模型目录已被丢弃，回到缺失态。
      expect(await mgr.isReady(), isFalse);
    });
  });
}

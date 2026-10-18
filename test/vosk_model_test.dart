import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:chunkspoke_flutter/services/vosk_model.dart';

/// 生成一个小 zip：顶层目录 mymodel/ 内含两个文件（供解压断言）。
Uint8List _makeZip() {
  final archive = Archive();
  archive.addFile(
      ArchiveFile('mymodel/conf/mf.conf', 0, Uint8List.fromList([0x61, 0x62, 0x63])));
  archive.addFile(
      ArchiveFile('mymodel/am/final.mdl', 0, Uint8List.fromList([0x64, 0x65, 0x66])));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// 分块清单 + 可选的「每分块返回字节」脚本。
ModelManifest _manifest(List<int> zip, int chunks) {
  final size = zip.length;
  final parts = <ModelPart>[];
  var off = 0;
  for (var i = 0; i < chunks; i++) {
    final end = i == chunks - 1 ? size : off + (size ~/ chunks);
    parts.add(ModelPart('https://x/m.part$i', end - off));
    off = end;
  }
  return ModelManifest(
    name: 'mymodel',
    modelVersion: '0.1',
    sha256: sha256.convert(zip).toString(),
    size: size,
    parts: parts,
  );
}

MockClient _chunkClient(List<int> zip, int chunks) {
  final size = zip.length;
  return MockClient((req) async {
    final url = req.url.toString();
    for (var i = 0; i < chunks; i++) {
      if (url.endsWith('m.part$i')) {
        final start = i * (size ~/ chunks);
        final end = i == chunks - 1 ? size : start + (size ~/ chunks);
        return http.Response.bytes(zip.sublist(start, end), 200,
            headers: {'content-type': 'application/octet-stream'});
      }
    }
    return http.Response('not found', 404);
  });
}

void main() {
  group('ModelManager 分块下载 / 校验 / 解压 / 元数据', () {
    test('缺失 → 下载 → 校验 → 解压 → 写 model.json → 返回目录', () async {
      final zip = _makeZip();
      final manifest = _manifest(zip, 3);
      final client = _chunkClient(zip, 3);
      final tmp = Directory.systemTemp.createTempSync('model_ok_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final mgr = ModelManager(manifest: manifest, client: client, baseDir: () async => tmp);
      final modelPath = await mgr.ensureModel();

      expect(modelPath, p.join(tmp.path, 'mymodel'));
      expect(Directory(modelPath).existsSync(), isTrue);
      // 解压产物（zip 顶层目录 + 文件）。
      expect(File('$modelPath/conf/mf.conf').existsSync(), isTrue);
      // 落盘元数据（硬化②）。
      final meta = jsonDecode(File('$modelPath/model.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(meta['modelVersion'], '0.1');
      expect(meta['sha256'], manifest.sha256);
      // zip 校验解压后已删除（硬化①）。
      expect(File('${tmp.path}/mymodel.zip').existsSync(), isFalse);
      // 短路判断生效。
      expect(await mgr.isReady(), isTrue);
    });

    test('SHA-256 不匹配 → 删除 zip 并抛 ModelDownloadException', () async {
      final zip = _makeZip();
      final manifest = _manifest(zip, 2);
      // 篡改 sha256。
      final bad = ModelManifest(
        name: manifest.name,
        modelVersion: manifest.modelVersion,
        sha256: 'deadbeef',
        size: manifest.size,
        parts: manifest.parts,
      );
      final tmp = Directory.systemTemp.createTempSync('model_bad_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final mgr = ModelManager(manifest: bad, client: _chunkClient(zip, 2), baseDir: () async => tmp);

      await expectLater(mgr.ensureModel(), throwsA(isA<ModelDownloadException>()));
      expect(File('${tmp.path}/mymodel.zip').existsSync(), isFalse);
    });

    test('分块全失败 → 切整包兜底源 mirrorUrl', () async {
      final zip = _makeZip();
      final manifest = _manifest(zip, 2);
      final withMirror = ModelManifest(
        name: manifest.name,
        modelVersion: manifest.modelVersion,
        sha256: manifest.sha256,
        size: manifest.size,
        parts: manifest.parts,
        mirrorUrl: 'https://x/m.zip',
      );
      // 分块 404，整包成功。
      final client = MockClient((req) async {
        if (req.url.toString().endsWith('m.zip')) {
          return http.Response.bytes(zip, 200,
              headers: {'content-type': 'application/octet-stream'});
        }
        return http.Response('not found', 404);
      });
      final tmp = Directory.systemTemp.createTempSync('model_mirror_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final mgr = ModelManager(manifest: withMirror, client: client, baseDir: () async => tmp);

      final path = await mgr.ensureModel();
      expect(path, p.join(tmp.path, 'mymodel'));
      expect(await mgr.isReady(), isTrue);
    });

    test('discard：删除目录与 zip 分片，回到缺失态', () async {
      final zip = _makeZip();
      final manifest = _manifest(zip, 2);
      final tmp = Directory.systemTemp.createTempSync('model_discard_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final mgr = ModelManager(manifest: manifest, client: _chunkClient(zip, 2), baseDir: () async => tmp);
      await mgr.ensureModel();
      expect(await mgr.isReady(), isTrue);

      await mgr.discard();
      expect(await mgr.isReady(), isFalse);
      expect(Directory('${tmp.path}/mymodel').existsSync(), isFalse);
    });
  });
}

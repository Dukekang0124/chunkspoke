import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:chunkspoke_flutter/services/vosk_model.dart';

Uint8List _makeZip() {
  final archive = Archive();
  archive.addFile(ArchiveFile(
      'mymodel/conf/mf.conf', 0, Uint8List.fromList([0x61, 0x62, 0x63])));
  archive.addFile(ArchiveFile(
      'mymodel/am/final.mdl', 0, Uint8List.fromList([0x64, 0x65, 0x66])));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

List<int> _partSizes(int total) => [total ~/ 3, total ~/ 3, total - 2 * (total ~/ 3)];

ModelManifest _manifest(Uint8List zip, List<String> urls, {List<List<String>>? fallbacks}) {
  final sizes = _partSizes(zip.length);
  var off = 0;
  final parts = <ModelPart>[];
  for (var i = 0; i < 3; i++) {
    final bytes = zip.sublist(off, off + sizes[i]);
    parts.add(ModelPart(urls[i], sizes[i],
        sha256: sha256.convert(bytes).toString(),
        fallbacks: fallbacks?[i] ?? const []));
    off += sizes[i];
  }
  return ModelManifest(
    name: 'mymodel',
    modelVersion: '0.15.1',
    sha256: sha256.convert(zip).toString(),
    size: zip.length,
    parts: parts,
  );
}

/// 可编排故障的分块服务器：支持 Range、短块、脏块、固定失败。
class _PartServer extends http.BaseClient {
  _PartServer(this.parts);
  final Map<String, List<int>> parts; // URL 后缀 -> 正确内容
  final List<String> log = [];
  final Map<String, int> calls = {};
  String? shortOnce; // 首次请求该分块只回一半
  String? corruptOnce; // 首次请求该分块翻转一个字节
  bool failJsdelivr = false;
  int failFirstN = 0;

  String? _key(String url) {
    for (final k in parts.keys) {
      if (url.contains(k)) return k;
    }
    return null;
  }

  http.StreamedResponse _plain(int status, List<int> body) =>
      http.StreamedResponse(Stream.value(body), status, contentLength: body.length);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest req) async {
    final url = req.url.toString();
    final range = req.headers['range'];
    log.add('$url|$range');
    final key = _key(url);
    calls[key!] = (calls[key] ?? 0) + 1;
    if (failFirstN > 0) {
      failFirstN--;
      return _plain(503, const []);
    }
    if (failJsdelivr && url.contains('jsdelivr.net')) return _plain(503, const []);
    var body = List<int>.of(parts[key]!);
    if (shortOnce == key) {
      shortOnce = null;
      body = body.sublist(0, body.length ~/ 2);
    }
    if (corruptOnce == key) {
      corruptOnce = null;
      body = List<int>.of(body)..[0] ^= 0xFF;
    }
    var start = 0;
    if (range != null) {
      start = int.parse(RegExp(r'bytes=(\d+)').firstMatch(range)!.group(1)!);
    }
    final chunk = body.sublist(start);
    return http.StreamedResponse(Stream.value(chunk), start > 0 ? 206 : 200,
        contentLength: chunk.length,
        headers: start > 0
            ? {'content-range': 'bytes $start-${body.length - 1}/${body.length}'}
            : const {});
  }
}

/// 首个 part0 响应只发一半后抛连接重置；下一次带 Range 正常续传。
class _FlakyServer extends http.BaseClient {
  _FlakyServer(this.parts);
  final Map<String, List<int>> parts;
  int p0 = 0;
  final List<String?> ranges = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest req) async {
    final url = req.url.toString();
    ranges.add(req.headers['range']);
    final isP0 = url.endsWith('part0');
    if (isP0) {
      p0++;
      if (p0 == 1) {
        final ctrl = StreamController<List<int>>();
        final body = parts['part0']!;
        scheduleMicrotask(() async {
          ctrl.add(body.sublist(0, body.length ~/ 2));
          await Future<void>.delayed(const Duration(milliseconds: 10));
          ctrl.addError(const SocketException('Connection reset by peer'));
          await ctrl.close();
        });
        return http.StreamedResponse(ctrl.stream, 200, contentLength: body.length);
      }
    }
    final key = parts.keys.firstWhere((k) => url.contains(k));
    final body = parts[key]!;
    var start = 0;
    if (req.headers['range'] != null) {
      start = int.parse(RegExp(r'bytes=(\d+)').firstMatch(req.headers['range']!)!.group(1)!);
    }
    final chunk = body.sublist(start);
    return http.StreamedResponse(Stream.value(chunk), start > 0 ? 206 : 200,
        contentLength: chunk.length,
        headers: start > 0
            ? {'content-range': 'bytes $start-${body.length - 1}/${body.length}'}
            : const {});
  }
}

Map<String, List<int>> _partsFor(Uint8List zip) {
  final sizes = _partSizes(zip.length);
  var off = 0;
  final map = <String, List<int>>{};
  for (var i = 0; i < 3; i++) {
    map['part$i'] = zip.sublist(off, off + sizes[i]);
    off += sizes[i];
  }
  return map;
}

void main() {
  group('B3 模型下载韧性', () {
    test('续传偏移对齐：从落盘字节数发 Range，不从头也不跳过', () async {
      final zip = _makeZip();
      final parts = _partsFor(zip);
      final server = _PartServer(parts);
      final tmp = Directory.systemTemp.createTempSync('b3_resume_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip, ['https://x/part0', 'https://y/part1', 'https://z/part2']);
      final block0 = File('${tmp.path}/mymodel.zip.part0');
      final half = parts['part0']!.length ~/ 2;
      await block0.writeAsBytes(parts['part0']!.sublist(0, half));

      final mgr = ModelManager(
          manifest: manifest,
          client: server,
          baseDir: () async => tmp,
          retryDelay: Duration.zero,
          autoRetryRounds: 0);
      final modelPath = await mgr.ensureModel();

      expect(File('$modelPath/conf/mf.conf').existsSync(), isTrue);
      expect(server.log.any((e) => e.contains('part0') && e.endsWith('|bytes=$half-')),
          isTrue, reason: '续传必须从已落盘 $half 字节处对齐');
      expect(File('${tmp.path}/mymodel.zip.part0').existsSync(), isFalse);
    });

    test('双写不复现：连接中断后按落盘偏移续传，最终内容无重复', () async {
      final zip = _makeZip();
      final parts = _partsFor(zip);
      final server = _FlakyServer(parts);
      final tmp = Directory.systemTemp.createTempSync('b3_double_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip, ['https://x/part0', 'https://y/part1', 'https://z/part2'],
          fallbacks: [
            ['https://x/part0.retry'], const [], const []
          ]);
      final mgr = ModelManager(
          manifest: manifest,
          client: server,
          baseDir: () async => tmp,
          retryDelay: Duration.zero,
          autoRetryRounds: 0);
      final modelPath = await mgr.ensureModel();

      final half = parts['part0']!.length ~/ 2;
      expect(server.ranges, contains('bytes=$half-'));
      expect(File('$modelPath/conf/mf.conf').readAsBytesSync(), [0x61, 0x62, 0x63]);
      expect(File('$modelPath/am/final.mdl').readAsBytesSync(), [0x64, 0x65, 0x66]);
    });

    test('块级校验失败：脏块整块作废并换源重下', () async {
      final zip = _makeZip();
      final parts = _partsFor(zip);
      final server = _PartServer(parts)..corruptOnce = 'part1';
      final tmp = Directory.systemTemp.createTempSync('b3_block_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip, ['https://x/part0', 'https://y/part1', 'https://z/part2'],
          fallbacks: [
            const [], ['https://y/part1.raw'], const []
          ]);
      final mgr = ModelManager(
          manifest: manifest,
          client: server,
          baseDir: () async => tmp,
          retryDelay: Duration.zero,
          autoRetryRounds: 0);
      final modelPath = await mgr.ensureModel();

      expect(server.calls['part1'], 2, reason: '脏块必须被作废后重下一次');
      expect(File('$modelPath/conf/mf.conf').existsSync(), isTrue);
    });

    test('双源切换：jsDelivr 四边缘均失败后切 raw 分块源', () async {
      final zip = _makeZip();
      final parts = _partsFor(zip);
      final server = _PartServer(parts)..failJsdelivr = true;
      final tmp = Directory.systemTemp.createTempSync('b3_fallback_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip,
          [
            'https://cdn.jsdelivr.net/gh/u/r@main/part0',
            'https://cdn.jsdelivr.net/gh/u/r@main/part1',
            'https://cdn.jsdelivr.net/gh/u/r@main/part2',
          ],
          fallbacks: [
            ['https://raw.githubusercontent.com/u/r/main/part0'],
            ['https://raw.githubusercontent.com/u/r/main/part1'],
            ['https://raw.githubusercontent.com/u/r/main/part2'],
          ]);
      final mgr = ModelManager(
          manifest: manifest,
          client: server,
          baseDir: () async => tmp,
          retryDelay: Duration.zero,
          autoRetryRounds: 0);
      final modelPath = await mgr.ensureModel();

      final jsdelivrPart0 = server.log
          .where((e) => e.contains('part0') && e.contains('jsdelivr.net'))
          .length;
      expect(jsdelivrPart0, 4, reason: '四个 jsDelivr 边缘域名都应尝试过');
      expect(server.log.any((e) => e.contains('raw.githubusercontent.com')), isTrue);
      expect(File('$modelPath/conf/mf.conf').existsSync(), isTrue);
    });

    test('短块回归：CDN 短响应不再造成精确长度但 SHA 失败', () async {
      final zip = _makeZip();
      final parts = _partsFor(zip);
      final server = _PartServer(parts)..shortOnce = 'part0';
      final tmp = Directory.systemTemp.createTempSync('b3_short_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip, ['https://x/part0', 'https://y/part1', 'https://z/part2'],
          fallbacks: [
            ['https://x/part0.retry'], const [], const []
          ]);
      final mgr = ModelManager(
          manifest: manifest,
          client: server,
          baseDir: () async => tmp,
          retryDelay: Duration.zero,
          autoRetryRounds: 0);
      final modelPath = await mgr.ensureModel();

      expect(server.calls['part0'], 2, reason: '短块必须作废后整块重下');
      expect(File('$modelPath/conf/mf.conf').existsSync(), isTrue);
    });

    test('自动重试 2 轮：失败两轮后第三轮成功，并发出修复文案', () async {
      final zip = _makeZip();
      final parts = _partsFor(zip);
      final server = _PartServer(parts)..failFirstN = 2;
      final tmp = Directory.systemTemp.createTempSync('b3_autoretry_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip, ['https://x/part0', 'https://y/part1', 'https://z/part2']);
      final mgr = ModelManager(
          manifest: manifest,
          client: server,
          baseDir: () async => tmp,
          retryDelay: Duration.zero,
          autoRetryRounds: 2);
      final messages = <String?>[];
      final sub = mgr.progress.listen((p) => messages.add(p.message));
      addTearDown(sub.cancel);

      final modelPath = await mgr.ensureModel();

      expect(File('$modelPath/conf/mf.conf').existsSync(), isTrue);
      expect(
          messages.where((m) => m == '语音包下载损坏，正在自动重新下载').length, 2,
          reason: '两轮自动修复各发一次文案');
      expect(messages.any((m) => m?.contains('SHA-256') ?? false), isFalse);
    });

    test('最终失败文案不含密码学术语', () async {
      final zip = _makeZip();
      final parts = _partsFor(zip);
      final server = _PartServer(parts)..failFirstN = 3;
      final tmp = Directory.systemTemp.createTempSync('b3_copy_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip, ['https://x/part0', 'https://y/part1', 'https://z/part2']);
      final mgr = ModelManager(
          manifest: manifest,
          client: server,
          baseDir: () async => tmp,
          retryDelay: Duration.zero,
          autoRetryRounds: 2);

      Object? error;
      try {
        await mgr.ensureModel();
      } catch (e) {
        error = e;
      }
      expect(error, isA<ModelDownloadException>());
      expect('$error', isNot(contains('SHA-256')));
      expect('$error', contains('语音包下载失败'));
    });

    test('手动重试清残：删除全部分块、拼接临时文件与未就绪目录', () async {
      final zip = _makeZip();
      final tmp = Directory.systemTemp.createTempSync('b3_reset_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final manifest = _manifest(
          zip, ['https://x/part0', 'https://y/part1', 'https://z/part2']);
      for (final name in [
        'mymodel.zip',
        'mymodel.zip.part',
        'mymodel.zip.part0',
        'mymodel.zip.part1',
        'mymodel.zip.assembling',
        'mymodel.zip.whole.part',
      ]) {
        File('${tmp.path}/$name').writeAsBytesSync([1, 2, 3]);
      }
      Directory('${tmp.path}/mymodel').createSync();

      final mgr = ModelManager(
          manifest: manifest, client: _PartServer(<String, List<int>>{}), baseDir: () async => tmp);
      await mgr.resetIncomplete();

      expect(File('${tmp.path}/mymodel.zip').existsSync(), isFalse);
      expect(File('${tmp.path}/mymodel.zip.part0').existsSync(), isFalse);
      expect(File('${tmp.path}/mymodel.zip.assembling').existsSync(), isFalse);
      expect(Directory('${tmp.path}/mymodel').existsSync(), isFalse);
    });
  });
}

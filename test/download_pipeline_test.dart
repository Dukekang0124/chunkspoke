import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:chunkspoke_flutter/services/download/download_diag.dart';
import 'package:chunkspoke_flutter/services/download/segment_fetch.dart';
import 'package:chunkspoke_flutter/services/update/sha256_util.dart';
import 'package:chunkspoke_flutter/services/update/update_service.dart';

/// 可脚本化的假服务器：按请求返回预置响应（可检查 Range 头）。
class _Srv extends http.BaseClient {
  _Srv(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest req) handler;
  final List<http.BaseRequest> seen = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    seen.add(request);
    return handler(request);
  }
}

http.StreamedResponse _resp(int code, List<int> body,
    {Map<String, String>? headers}) {
  return http.StreamedResponse(
    Stream.value(body),
    code,
    headers: {'content-type': 'application/octet-stream', ...?headers},
    contentLength: body.length,
  );
}

Uint8List _bytes(int n, {int seed = 0}) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 7 + seed) % 251));

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('seg_test_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('fetchSegment 416 特判（热修核心路径）', () {
    test('本地长度 == 预期总长 → 不再发请求，直接交给上层做 sha 校验', () async {
      final f = File('${tmp.path}/a.part');
      await f.writeAsBytes(_bytes(100));
      final srv = _Srv((_) async => _resp(416, const []));

      final r = await fetchSegment(
          client: srv, url: 'https://x/a', file: f, expectedSize: 100);

      expect(r.bytes, 100);
      expect(r.reachedExpected, isTrue);
      expect(srv.seen, isEmpty, reason: '已全长时连 416 都不该打出来');
      expect(await f.length(), 100, reason: '不得删除已全长的文件');
    });

    test('本地长度不符 → 416 删档从零，同源重发一次后成功', () async {
      final f = File('${tmp.path}/b.part');
      await f.writeAsBytes(_bytes(30)); // 残片：30/100
      final body = _bytes(100);
      var calls = 0;
      final srv = _Srv((req) async {
        calls++;
        if (calls == 1) return _resp(416, const []);
        // 第二次请求：删档后应无 Range（从零）
        expect(req.headers['range'], isNull);
        return _resp(200, body);
      });
      final diag = DownloadDiag(task: 't', expectedBytes: 100);

      final r = await fetchSegment(
          client: srv, url: 'https://x/b', file: f, expectedSize: 100, diag: diag);

      expect(r.bytes, 100);
      expect(calls, 2);
      expect(await f.readAsBytes(), body);
      expect(diag.entries.first.http, 416);
      expect(diag.entries.first.note, contains('删档从零'));
    });

    test('416 且清单未给总长（expectedSize=0）→ 删档重下，不当作完成', () async {
      final f = File('${tmp.path}/c.part');
      await f.writeAsBytes(_bytes(20));
      var calls = 0;
      final srv = _Srv((_) async {
        calls++;
        return calls == 1 ? _resp(416, const []) : _resp(200, _bytes(50));
      });
      final r = await fetchSegment(
          client: srv, url: 'https://x/c', file: f, expectedSize: 0);
      expect(calls, 2);
      expect(r.bytes, 50);
    });
  });

  group('传输中断 → 保留残片 → 续传 → 全长校验', () {
    test('中断只留已落盘字节；重试按 Range 续传并拼成全长', () async {
      final f = File('${tmp.path}/d.part');
      final full = _bytes(100, seed: 3);
      var calls = 0;
      final srv = _Srv((req) async {
        calls++;
        if (calls == 1) {
          // 首轮：无 Range，发 40 字节后网络中断
          expect(req.headers['range'], isNull);
          final ctl = StreamController<List<int>>();
          ctl.add(full.sublist(0, 40));
          ctl.addError(const SocketException('connection reset'));
          unawaited(ctl.close());
          return http.StreamedResponse(ctl.stream, 200, headers: const {
            'content-type': 'application/octet-stream',
          }, contentLength: 100);
        }
        // 续传：Range 必须按磁盘真实长度
        expect(req.headers['range'], 'bytes=40-');
        return _resp(206, full.sublist(40), headers: {
          'content-range': 'bytes 40-99/100',
        });
      });
      final diag = DownloadDiag(task: 't', expectedBytes: 100);

      // 首轮：中断 → SourceMiss，但残片保留
      await expectLater(
          fetchSegment(
              client: srv, url: 'https://x/d', file: f, expectedSize: 100, diag: diag),
          throwsA(isA<SourceMiss>()));
      final kept = await f.length();
      expect(kept, greaterThan(0));
      expect(kept, lessThan(100));
      expect(diag.entries.last.note, contains('传输中断'));

      // 第二轮：续传补齐
      final r = await fetchSegment(
          client: srv, url: 'https://x/d', file: f, expectedSize: 100, diag: diag);
      expect(r.bytes, 100);
      expect(r.reachedExpected, isTrue);
      expect(await f.readAsBytes(), full);
    });
  });

  group('篡改/长度不符的包必须被拒绝（换源前置条件）', () {
    test('verifySha256 不符 → 删档并返回 false（上层据此换下一源从零）', () async {
      final f = File('${tmp.path}/e.apk');
      await f.writeAsBytes(_bytes(64));
      final wrong = 'a' * 64;
      final ok = await UpdateService().verifySha256(f.path, wrong);
      expect(ok, isFalse);
      expect(await f.exists(), isFalse, reason: '坏包必须删掉，绝不能续传或安装');
    });

    test('verifySha256 相符 → 保留文件', () async {
      final f = File('${tmp.path}/f.apk');
      final data = _bytes(64);
      await f.writeAsBytes(data);
      final right = await fileSha256(f.path);
      expect(await UpdateService().verifySha256(f.path, right), isTrue);
      expect(await f.exists(), isTrue);
      expect(await f.readAsBytes(), data);
    });

    test('分块下到「长度正好但内容被篡改」→ chunk sha 校验可识别', () async {
      final f = File('${tmp.path}/g.block');
      final good = _bytes(80, seed: 1);
      final tampered = Uint8List.fromList(good)
        ..[10] = (good[10] + 1) % 256;
      await f.writeAsBytes(tampered);
      final expectSha = await _shaOf(good);
      expect(await fileSha256(f.path), isNot(expectSha));
    });
  });
}

Future<String> _shaOf(List<int> bytes) async {
  final f = await Directory.systemTemp.createTemp('sha_');
  try {
    final p = File('${f.path}/x');
    await p.writeAsBytes(bytes);
    return await fileSha256(p.path);
  } finally {
    try {
      await f.delete(recursive: true);
    } catch (_) {}
  }
}

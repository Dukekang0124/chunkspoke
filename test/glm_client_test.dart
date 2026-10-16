import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/glm_client.dart';

// 假 Client：可控返回 200 / 500 / 抛异常，并捕获请求以便断言。
class _Fake extends http.BaseClient {
  final int status;
  final bool throwIt;
  http.BaseRequest? last;
  _Fake({this.status = 200, this.throwIt = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    last = request;
    if (throwIt) throw Exception('boom'); // 模拟网络/超时失败
    final body = jsonEncode({
      'choices': [
        {'message': {'content': '诊断文本'}}
      ]
    });
    // 带真实的内容类型头（含 charset=utf-8），模拟 GLM 实际响应。
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

void main() {
  group('GlmClient 降级与红线', () {
    test('无 Key → 直接返回 null，且不发任何请求', () async {
      final fake = _Fake();
      final g = GlmClient(client: fake);
      final r = await g.chat('', 'hi');
      expect(r, isNull);
      expect(fake.last, isNull); // 无 Key 不发网络请求
    });

    test('200 → 返回模型文本，且 URL / 模型 / 鉴权头正确', () async {
      final fake = _Fake();
      final g = GlmClient(client: fake);
      final r = await g.chat('SECRET', 'prompt');
      expect(r, '诊断文本');
      expect(fake.last!.url.toString(),
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
      // Key 通过 Authorization 头传输（不写日志，代码审查保证）。
      expect(fake.last!.headers['Authorization'], 'Bearer SECRET');
    });

    test('非 200 → 静默降级返回 null，不抛', () async {
      final fake = _Fake(status: 500);
      final g = GlmClient(client: fake);
      final r = await g.chat('KEY', 'p');
      expect(r, isNull);
    });

    test('网络/超时异常 → 静默降级返回 null，不抛、不阻塞', () async {
      final fake = _Fake(throwIt: true);
      final g = GlmClient(client: fake);
      final r = await g.chat('KEY', 'p');
      expect(r, isNull);
    });

    test('chatDetailed：200 回传状态码与文本', () async {
      final fake = _Fake();
      final g = GlmClient(client: fake);
      final r = await g.chatDetailed('SECRET', 'prompt');
      expect(r.status, 200);
      expect(r.text, '诊断文本');
    });

    test('chatDetailed：非 200 回传状态码且文本为 null', () async {
      final fake = _Fake(status: 500);
      final g = GlmClient(client: fake);
      final r = await g.chatDetailed('KEY', 'p');
      expect(r.status, 500);
      expect(r.text, isNull);
    });
  });
}

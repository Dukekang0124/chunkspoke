import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/glm_client.dart';
import 'package:chunkspoke_flutter/services/llm_provider.dart';
import 'package:chunkspoke_flutter/services/llm_config.dart';

// 受控假客户端：按 Key 脚本返回（状态码, 文本）。
class _FakeGlm extends GlmClient {
  final Map<String, ({int status, String? text})> script;
  _FakeGlm({this.script = const {}});
  @override
  Future<({String? text, int status})> chatDetailed(
      String apiKey, String prompt) async {
    final hit = script[apiKey];
    if (hit != null) return hit;
    return (text: 'ok:$apiKey', status: 200);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('LlmProvider 双层解析与降级', () {
    late ProgressService p;
    setUp(() async {
      p = ProgressService();
      await p.init();
      // 默认 DB 在用例间持久化：清除自定义 / 内置状态，避免配置泄漏串扰。
      await p.clearCustomLlm();
      for (var i = 0; i < 4; i++) {
        await p.setBuiltinFailTs(i, 0);
      }
      await p.setBuiltinUnavailable(false);
    });

    test('无内置且无自定义 → resolveActive 为 null，chatFallback 降级 null', () async {
      final prov = LlmProvider(p, builtinsOverride: const []);
      expect(prov.resolveActive(), isNull);
      expect(await prov.chatFallback('x'), isNull);
    });

    test('自定义层启用且 Key 有效 → resolveActive 返回自定义配置', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmUrl('https://x.example/v1');
      await p.setCustomLlmModel('m1');
      await p.setCustomLlmKey('K_CUSTOM');
      final prov = LlmProvider(p, builtinsOverride: const []);
      final cfg = prov.resolveActive();
      expect(cfg, isNotNull);
      expect(cfg!.key, 'K_CUSTOM');
      expect(cfg.model, 'm1');
      expect(cfg.baseUrl, 'https://x.example/v1');
    });

    test('内置兜底链：首个 401 自动跳到下一个成功', () async {
      const a = LlmConfig(baseUrl: 'b', model: 'A', key: 'K_A');
      const b = LlmConfig(baseUrl: 'b', model: 'B', key: 'K_B');
      final fake = _FakeGlm(script: {
        'K_A': (status: 401, text: null),
      });
      final prov = LlmProvider(p, client: fake, builtinsOverride: [a, b]);
      final r = await prov.chatFallback('x');
      expect(r, 'ok:K_B');
      expect(p.builtinFailTs(0), greaterThan(0)); // K_A 标记失败
      expect(prov.builtinUnavailable, isFalse); // K_B 成功 → 整体可用
    });

    test('全部内置 401/403 → 降级 null 且标记内置不可用', () async {
      const a = LlmConfig(baseUrl: 'b', model: 'A', key: 'K_A');
      const b = LlmConfig(baseUrl: 'b', model: 'B', key: 'K_B');
      final fake = _FakeGlm(script: {
        'K_A': (status: 401, text: null),
        'K_B': (status: 403, text: null),
      });
      final prov = LlmProvider(p, client: fake, builtinsOverride: [a, b]);
      final r = await prov.chatFallback('x');
      expect(r, isNull);
      expect(prov.builtinUnavailable, isTrue);
    });

    test('自定义层失败不自动回退内置（验收②语义）', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K_CUSTOM');
      const a = LlmConfig(baseUrl: 'b', model: 'A', key: 'K_A');
      final fake = _FakeGlm(script: {
        'K_CUSTOM': (status: 401, text: null),
      });
      final prov = LlmProvider(p, client: fake, builtinsOverride: [a]);
      final r = await prov.chatFallback('x', customOnly: true);
      expect(r, isNull);
    });

    test('testCustom：成功返回模型名，Key 无效返回原因', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmUrl('https://x.example/v1');
      await p.setCustomLlmModel('m1');
      await p.setCustomLlmKey('K');
      final ok = _FakeGlm(script: {'K': (status: 200, text: 'hi')});
      final r1 = await LlmProvider(p, client: ok).testCustom(tmp: ok);
      expect(r1.ok, isTrue);
      expect(r1.reason, 'm1');
      final bad = _FakeGlm(script: {'K': (status: 401, text: null)});
      final r2 = await LlmProvider(p, client: bad).testCustom(tmp: bad);
      expect(r2.ok, isFalse);
      expect(r2.reason, contains('Key 无效'));
    });

    test('清除自定义配置回落内置', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K');
      await p.clearCustomLlm();
      expect(p.customLlmEnabled, isFalse);
      expect(p.customLlmKey, isNull);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/glm_client.dart';
import 'package:chunkspoke_flutter/services/llm_provider.dart';
import 'package:chunkspoke_flutter/services/llm_config.dart';
import 'support/fake_key_cipher.dart';

// 受控假客户端：按 Key 脚本返回（状态码, 文本），并记录调用次数。
class _FakeGlm extends GlmClient {
  final Map<String, ({int status, String? text})> script;
  final List<String> calls = [];
  _FakeGlm({this.script = const {}});
  @override
  Future<({String? text, int status})> chatDetailed(
      String apiKey, String prompt) async {
    calls.add(apiKey);
    final hit = script[apiKey];
    if (hit != null) return hit;
    return (text: 'ok:$apiKey', status: 200);
  }
}

// 按顺序返回预设结果的假客户端（用于 429 退避序列）。
class _SeqGlm extends GlmClient {
  _SeqGlm(this.seq);
  final List<({int status, String? text})> seq;
  int calls = 0;
  @override
  Future<({String? text, int status})> chatDetailed(
      String apiKey, String prompt) async {
    final r = seq[calls < seq.length ? calls : seq.length - 1];
    calls++;
    return r;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('LlmProvider 单层解析（1.5.8 起无内置 Key）', () {
    late ProgressService p;
    setUp(() async {
      // 每个用例独立的内存库：避免与其它测试文件共用磁盘库互相污染。
      p = ProgressService(
          db: AppDatabase(path: inMemoryDatabasePath),
          cipher: FakeKeyCipher());
      await p.init();
      // 默认 DB 在用例间持久化：清掉自定义配置，避免串扰。
      await p.clearCustomLlm();
    });

    test('未配置 → resolveActive 为 null，chatFallback 不联网', () async {
      final fake = _FakeGlm();
      final prov = LlmProvider(p, client: fake);
      expect(prov.customEnabled, isFalse);
      expect(prov.resolveActive(), isNull);
      expect(await prov.chatFallback('x'), isNull);
      expect(fake.calls, isEmpty);
    });

    test('地址/模型留空 → 用智谱 GLM 预设补齐（用户只粘 Key）', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K_GLM');
      final cfg = LlmProvider(p).resolveActive();
      expect(cfg, isNotNull);
      expect(cfg!.baseUrl, glmPreset.baseUrl);
      expect(cfg.model, 'glm-4.7-flash');
      expect(cfg.key, 'K_GLM');
    });

    test('自定义全字段 → 原样生效', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmUrl('https://x.example/v1');
      await p.setCustomLlmModel('m1');
      await p.setCustomLlmKey('K_CUSTOM');
      final cfg = LlmProvider(p).resolveActive();
      expect(cfg!.baseUrl, 'https://x.example/v1');
      expect(cfg.model, 'm1');
      expect(cfg.key, 'K_CUSTOM');
    });

    test('自定义 401 → 返回 null，且不偷偷换服务商（只调一次）', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K_BAD');
      final fake = _FakeGlm(script: {
        'K_BAD': (status: 401, text: null),
      });
      final prov = LlmProvider(p, client: fake);
      expect(await prov.chatFallback('x'), isNull);
      expect(fake.calls, ['K_BAD']);
    });

    test('自定义 200 → 返回文本', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K_OK');
      final fake = _FakeGlm(script: {
        'K_OK': (status: 200, text: 'hi'),
      });
      expect(await LlmProvider(p, client: fake).chatFallback('x'), 'hi');
    });

    test('429 退避后成功 → 返回文本（最多重试 2 次）', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K');
      final seq = _SeqGlm([
        (status: 429, text: null),
        (status: 429, text: null),
        (status: 200, text: 'hi'),
      ]);
      final prov = LlmProvider(p, client: seq, retryBase: Duration.zero);
      expect(await prov.chatFallback('x'), 'hi');
      expect(seq.calls, 3);
    });

    test('持续 429 → 重试上限后返回 null，不无限重试', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K');
      final seq = _SeqGlm([(status: 429, text: null)]);
      final prov = LlmProvider(p, client: seq, retryBase: Duration.zero);
      expect(await prov.chatFallback('x'), isNull);
      expect(seq.calls, LlmProvider.kMaxRateLimitRetries + 1);
    });

    test('超时不重试（只调一次），避免主流程长时间阻塞', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K');
      final seq = _SeqGlm([(status: -1, text: null)]);
      final prov = LlmProvider(p, client: seq, retryBase: Duration.zero);
      expect(await prov.chatFallback('x'), isNull);
      expect(seq.calls, 1);
    });

    test('清除自定义配置 → 回到本地统计', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K');
      await p.clearCustomLlm();
      expect(p.customLlmEnabled, isFalse);
      expect(p.customLlmKey, isNull);
      expect(LlmProvider(p).resolveActive(), isNull);
    });

    test('开关开着但 Key 为空 → 视为未配置（不发起空鉴权请求）', () async {
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey(null);
      final fake = _FakeGlm();
      expect(await LlmProvider(p, client: fake).chatFallback('x'), isNull);
      expect(fake.calls, isEmpty);
    });
  });

  group('testCustom 状态分类（401/429/超时/协议）', () {
    late ProgressService p;
    setUp(() async {
      // 每个用例独立的内存库：避免与其它测试文件共用磁盘库互相污染。
      p = ProgressService(
          db: AppDatabase(path: inMemoryDatabasePath),
          cipher: FakeKeyCipher());
      await p.init();
      await p.clearCustomLlm();
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmModel('m1');
      await p.setCustomLlmKey('K');
    });

    test('200 → 成功并返回模型名', () async {
      final ok = _FakeGlm(script: {'K': (status: 200, text: 'hi')});
      final r = await LlmProvider(p, client: ok).testCustom(tmp: ok);
      expect(r.ok, isTrue);
      expect(r.reason, 'm1');
    });

    test('401 → Key 无效', () async {
      final bad = _FakeGlm(script: {'K': (status: 401, text: null)});
      final r = await LlmProvider(p, client: bad).testCustom(tmp: bad);
      expect(r.ok, isFalse);
      expect(r.reason, contains('Key 无效'));
    });

    test('429 → 限流提示（不当作 Key 无效）', () async {
      final slow = _FakeGlm(script: {'K': (status: 429, text: null)});
      final r = await LlmProvider(p, client: slow).testCustom(tmp: slow);
      expect(r.ok, isFalse);
      expect(r.reason, contains('429'));
      expect(r.reason, contains('稍后'));
    });

    test('空 Key → 不发请求，提示先填 Key', () async {
      await p.setCustomLlmKey(null);
      final fake = _FakeGlm();
      final r = await LlmProvider(p, client: fake).testCustom(tmp: fake);
      expect(r.ok, isFalse);
      expect(r.reason, contains('API Key'));
      expect(fake.calls, isEmpty);
    });
  });

  group('classifyChatStatus', () {
    test('200 → ok', () => expect(classifyChatStatus(200, 'm').ok, isTrue));
    test('403 → Key 无效',
        () => expect(classifyChatStatus(403, 'm').reason, contains('Key 无效')));
    test('429 → 限流',
        () => expect(classifyChatStatus(429, 'm').reason, contains('429')));
    test('-1 → 超时',
        () => expect(classifyChatStatus(-1, 'm').reason, contains('超时')));
    test('500 → 服务异常',
        () => expect(classifyChatStatus(500, 'm').reason, contains('500')));
  });
}

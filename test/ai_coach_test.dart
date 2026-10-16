import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/ai_coach.dart';
import 'package:chunkspoke_flutter/services/glm_client.dart';
import 'package:chunkspoke_flutter/services/llm_provider.dart';
import 'package:chunkspoke_flutter/services/llm_config.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';

// 受控假客户端：固定返回文本（200）。
class _FakeGlm extends GlmClient {
  final String? out;
  _FakeGlm([this.out = 'AI文本']);
  @override
  Future<({String? text, int status})> chatDetailed(
      String apiKey, String prompt) async =>
      (text: out, status: 200);
}

// 最小 ContentPack（3 个词块），用于 studyPlan 本地逻辑。
ContentPack _pack() => ContentPack(
      version: '1.0',
      levels: [
        Level(
          id: 'A',
          theme: 't',
          sceneImage: 's',
          chunks: [
            Chunk(id: 'a', text: 'hello', type: 'function', meaningCN: '你好', sentence: _s('hello')),
            Chunk(id: 'b', text: 'thanks', type: 'content', meaningCN: '谢谢', sentence: _s('thanks')),
            Chunk(id: 'c', text: 'bye', type: 'content', meaningCN: '再见', sentence: _s('bye')),
          ],
        ),
      ],
    );

ChunkSentence _s(String t) => ChunkSentence(
    text: t, slots: [Slot(text: t, type: 'function')], coreWords: [t], swapSlotIndex: 0, swapOptions: []);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('AiCoach 降级与本地逻辑', () {
    late ProgressService p;
    setUp(() async {
      p = ProgressService();
      await p.init();
    });

    test('无可用模型 → weeklyReport / variantTask 返回 null（降级、不阻塞）', () async {
      // 内置编译期未注入 + 自定义关 → 自动降级。
      final coach = AiCoach(p);
      expect(await coach.weeklyReport(p, _pack()), isNull);
      expect(await coach.variantTask(p, _pack()), isNull);
    });

    test('studyPlan 返回 7 天，每日新学 ≤5', () async {
      final coach = AiCoach(p);
      final plan = await coach.studyPlan(p, _pack());
      expect(plan.length, 7);
      for (final d in plan) {
        expect(d.newCount, lessThanOrEqualTo(5));
      }
    });

    test('variantTask 已掌握词块不足 2 → null', () async {
      // 即便开了自定义但无 mastered，仍降级。
      await p.setCustomLlmEnabled(true);
      await p.setCustomLlmKey('K');
      final coach = AiCoach(p,
          provider: LlmProvider(p, client: _FakeGlm(), builtinsOverride: const []));
      expect(await coach.variantTask(p, _pack()), isNull);
      await p.clearCustomLlm();
    });

    test('有可用模型 → weeklyReport 返回文本（内置或自定义）', () async {
      const cfg = LlmConfig(baseUrl: 'b', model: 'A', key: 'K');
      final coach = AiCoach(p,
          provider: LlmProvider(p,
              client: _FakeGlm('诊断文本'), builtinsOverride: [cfg]));
      final r = await coach.weeklyReport(p, _pack());
      expect(r, '诊断文本');
    });
  });
}

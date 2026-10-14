/// ============================================================================
/// ChunkSpoke · LLM 层（v1.1 候选 · 未验收）
/// ----------------------------------------------------------------------------
/// 状态：2026-10-13 被摘除出构建分支（R2 指令）。
/// 原因：违反 v2.0 第十节第 7 条红线「禁止越界实现：不做 AI 对话、不做自然度
///       判定」，且违反「versionCode=2 零功能改动」指令。judgeSay 属语义/自然度
///       判定，hint 属 AI 提示，二者均属 Roadmap v3，未经验收不得进构建。
/// 隔离：本目录为代码存档（项目未启用 git，故以目录代替 feature 分支），供将来
///       v1.1 评审后恢复。恢复前须走完下方「恢复前置条件」。
/// 硬性政策：
///   1) 四个 API Key 不得硬编码进源码/打包进 APK（APK 可反编译提取 = 公开配额），
///      须与 Azure Key 一致由用户在设置页自行填入（新增 provider 配置 UI）。
///   2) judgeSay 仅作附加信息展示，永不作为通过/失败判据，不得破坏 L1/L2/L3 降级链。
///   3) 必须定义全部 provider 失败时静默降级行为（回到 Text Match / L3）。
///   4) 四个模型 ID 与 Key 的真实归属、配额、有效性需逐个验证（尤其 agnes-2.5-flash）。
/// ============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;

/// 单个模型供应商（OpenAI 兼容 /chat/completions 协议）。
class LlmProvider {
  final String name; // 展示名
  final String baseUrl; // 完整 chat/completions 端点
  final String model; // 模型 ID
  final String apiKey; // 密钥
  const LlmProvider({
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });
}

/// 密钥（仅用于本产品内测；正式发布建议改为服务端代理，避免客户端可提取）。
/// ⚠️ 接入设置页前不得启用；硬编码为越界期临时写法，已随 R2 摘除。
const String _kG53 = '***REMOVED***';
const String _kDsV4 = '***REMOVED***';
const String _kAgnes = '***REMOVED***';
const String _kGlm4 = '***REMOVED***';

/// 默认模型链：优先级从高到低，最后 GLM-4-Flash 兜底。
/// 若某模型的端点/模型 ID 有出入，只需改这里的 baseUrl/model 一行即可。
const List<LlmProvider> kDefaultProviders = [
  LlmProvider(
    name: 'GLM-5.3-Flash',
    baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
    model: 'z-ai/glm-5.3-flash',
    apiKey: _kG53,
  ),
  LlmProvider(
    name: 'deepseek-v4-flash',
    baseUrl: 'https://api.deepseek.com/chat/completions',
    model: 'deepseek-v4-flash',
    apiKey: _kDsV4,
  ),
  LlmProvider(
    name: 'agnes-2.5-flash',
    baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
    model: 'agnes-2.5-flash',
    apiKey: _kAgnes,
  ),
  LlmProvider(
    name: 'GLM-4-Flash',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    model: 'glm-4-flash',
    apiKey: _kGlm4,
  ),
];

class LlmReply {
  final String text;
  final String provider;
  LlmReply(this.text, this.provider);
}

/// Say 步语义复核结果。
class SayJudgement {
  final bool passed;
  final String feedback;
  SayJudgement(this.passed, this.feedback);
}

/// 多模型 LLM 服务：按 4 模型优先降级调用，首个成功即返回。
class LlmService {
  final List<LlmProvider> providers;
  LlmService([List<LlmProvider>? providers])
      : providers = providers ?? kDefaultProviders;

  /// 依次尝试各模型；返回首个成功响应，全部失败返回 null。
  /// 同时通过 [onTry] 回调汇报当前尝试的模型名，便于 UI 展示降级过程。
  Future<LlmReply?> chat(
    String prompt, {
    double temperature = 0.3,
    int maxTokens = 300,
    void Function(String provider)? onTry,
  }) async {
    for (final p in providers) {
      onTry?.call(p.name);
      try {
        final resp = await http
            .post(
              Uri.parse(p.baseUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${p.apiKey}',
              },
              body: jsonEncode({
                'model': p.model,
                'messages': [
                  {'role': 'user', 'content': prompt}
                ],
                'temperature': temperature,
                'max_tokens': maxTokens,
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          final data =
              jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final choices = data['choices'] as List?;
          final content = (choices != null && choices.isNotEmpty)
              ? (choices[0]['message']?['content'] as String?)
              : null;
          if (content != null && content.trim().isNotEmpty) {
            return LlmReply(content.trim(), p.name);
          }
        }
      } catch (_) {
        // 该模型失败 → 降级到下一个
      }
    }
    return null;
  }

  /// Say 步语义复核：判断学习者是否表达了正确意思（比 Text Match 更宽容）。
  Future<SayJudgement?> judgeSay({
    required String expected,
    required String heard,
  }) async {
    if (heard.trim().isEmpty || heard == '(no speech)') return null;
    final prompt = 'You are an English speaking coach for Chinese learners.\n'
        'Target sentence: "$expected"\n'
        'The learner said: "$heard"\n'
        'Decide if the learner conveyed the SAME meaning as the target '
        '(ignore minor grammar/punctuation/casing differences).\n'
        'Reply ONLY valid JSON, no markdown: '
        '{"pass": true or false, "feedback": "<one short encouraging Chinese sentence, <=24 chars>"}';
    final r = await chat(prompt, temperature: 0.2, maxTokens: 200);
    if (r == null) return null;
    try {
      final s = r.text;
      final start = s.indexOf('{');
      final end = s.lastIndexOf('}');
      if (start < 0 || end <= start) return null;
      final j = jsonDecode(s.substring(start, end + 1)) as Map<String, dynamic>;
      return SayJudgement(j['pass'] == true, (j['feedback'] ?? '').toString());
    } catch (_) {
      return null;
    }
  }

  /// 生成一条简短中文提示，帮助学习者说出目标句。
  Future<String?> hint({required String sentence, String? heard}) async {
    final extra = (heard != null && heard.isNotEmpty && heard != '(no speech)')
        ? ' The learner said: "$heard".'
        : '';
    final prompt = 'You are an English coach for Chinese learners. '
        'Target sentence: "$sentence".$extra '
        'Give ONE short encouraging Chinese hint (<=20 chars) to help them say it correctly. '
        'Reply with the hint only.';
    final r = await chat(prompt, temperature: 0.6, maxTokens: 120);
    return r?.text;
  }
}

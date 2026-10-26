import 'package:chunkspoke_flutter/services/glm_client.dart';
import 'package:chunkspoke_flutter/services/llm_config.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';

/// 单层 LLM 服务解析器（1.5.8 起取消内置密钥层）。
///
/// 优先级：用户自定义（已开启且 Key 有效） ＞ 降级本地统计。
///   - 不内置任何 Key：用户未配置时 AI 仅走本机规则引擎，不走网络。
///   - 不静默换服务商：自定义层失败只在 UI 上分类提示（Key 无效 / 限流 / 超时 / 协议），
///     绝不偷偷改用别的模型或代用户调用其它服务。
///   - 任意失败不崩溃、不阻塞主流程、不写日志（Key 只进 Authorization 头）。
class LlmProvider {
  final ProgressService p;
  final GlmClient client;
  final Duration _retryBase;

  /// [retryBase] 仅 429 限流退避的基准间隔（测试可注入 0；生产 2s → 4s）。
  LlmProvider(this.p, {GlmClient? client, Duration retryBase = const Duration(seconds: 2)})
      : client = client ?? GlmClient(),
        _retryBase = retryBase;

  /// 429 最多再试 2 次（指数退避），鉴权/协议/超时不重试。
  static const int kMaxRateLimitRetries = 2;

  /// 用户自定义层是否启用且 Key 有效。
  bool get customEnabled =>
      p.customLlmEnabled && (p.customLlmKey ?? '').isNotEmpty;

  /// 解析当前生效配置；未启用返回 null（调用方降级本地统计）。
  /// 地址/模型留空时用智谱 GLM 预设补齐（用户只需粘 Key）。
  LlmConfig? resolveActive() {
    if (!customEnabled) return null;
    return LlmConfig(
      baseUrl: (p.customLlmUrl ?? '').isNotEmpty
          ? p.customLlmUrl!
          : glmPreset.baseUrl,
      model: (p.customLlmModel ?? '').isNotEmpty
          ? p.customLlmModel!
          : glmPreset.model,
      key: p.customLlmKey ?? '',
    );
  }

  /// 统一对话入口。无可用配置或任意失败返回 null（调用方静默降级本地）。
  /// 429 按 2s → 4s 退避重试至多 2 次；其余失败不重试、不换服务商。
  Future<String?> chatFallback(String prompt) async {
    final cfg = resolveActive();
    if (cfg == null) return null;
    var delay = _retryBase;
    for (var attempt = 0;; attempt++) {
      final r = await client.chatDetailed(cfg.key, prompt);
      if ((r.text ?? '').isNotEmpty) return r.text;
      if (r.status != 429 || attempt >= kMaxRateLimitRetries) return null;
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }

  /// 仅对自定义层做连通性测试，返回（是否成功，原因/模型名）。
  /// 失败原因按状态码分类：401/403 Key 无效、429 限流、-1 超时、其它协议不兼容。
  /// [tmp] 仅用于测试注入；缺省时按配置新建 GlmClient。
  Future<({bool ok, String reason})> testCustom({GlmClient? tmp}) async {
    final cfg = resolveActive() ??
        LlmConfig(
          baseUrl: (p.customLlmUrl ?? '').isNotEmpty
              ? p.customLlmUrl!
              : glmPreset.baseUrl,
          model: (p.customLlmModel ?? '').isNotEmpty
              ? p.customLlmModel!
              : glmPreset.model,
          key: p.customLlmKey ?? '',
        );
    if (cfg.key.isEmpty) return (ok: false, reason: '请先填写 API Key');
    if (cfg.model.isEmpty) return (ok: false, reason: '请先填写模型名');
    final created = tmp == null;
    final c = tmp ?? GlmClient(endpoint: cfg.baseUrl, model: cfg.model);
    try {
      final r = await c.chatDetailed(cfg.key, 'ping');
      if (created) c.dispose();
      return classifyChatStatus(r.status, cfg.model);
    } on Object {
      if (created) c.dispose();
      return (ok: false, reason: '连接超时');
    }
  }
}

/// 把一次 chat 调用的状态码翻成给用户看的一句话。
({bool ok, String reason}) classifyChatStatus(int status, String model) {
  if (status == 200) return (ok: true, reason: model);
  if (status == 401 || status == 403) return (ok: false, reason: 'Key 无效（$status）');
  if (status == 429) return (ok: false, reason: '请求过于频繁（429），请稍后再试');
  if (status == -1) return (ok: false, reason: '连接超时');
  return (ok: false, reason: '协议不兼容或服务异常（$status）');
}

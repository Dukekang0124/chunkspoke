/// 单个 OpenAI 兼容 LLM 配置（chat/completions）。
///
/// 三红线约束（贯穿内置层与自定义层）：
///   - Key 只用于 Authorization 头，绝不打印 / 写日志 / 落源码。
///   - 调用方只传统计摘要 + 词块 ID / 词块自身文本，绝不传录音原文。
///   - 任何失败（无 Key / 超时 / 401·403 / 协议不兼容）一律静默降级。
class LlmConfig {
  final String baseUrl; // 不含末尾 /chat/completions
  final String model;
  final String key;

  const LlmConfig({
    required this.baseUrl,
    required this.model,
    required this.key,
  });

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'model': model,
        'key': key,
      };

  factory LlmConfig.fromJson(Map<String, dynamic> j) => LlmConfig(
        baseUrl: (j['baseUrl'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        key: (j['key'] as String?) ?? '',
      );
}

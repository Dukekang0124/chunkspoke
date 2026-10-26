/// 单个 OpenAI 兼容 LLM 配置（chat/completions）。
///
/// 三红线约束（1.5.8 起取消内置层，Key 全部来自用户自配）：
///   - Key 只用于 Authorization 头，绝不打印 / 写日志 / 落源码；
///     落库为 Android Keystore 密文（见 `secure_store.dart`）。
///   - 调用方只传统计摘要 + 词块 ID / 词块自身文本，绝不传录音原文。
///   - 任意失败（无 Key / 超时 / 401·403 / 429 / 协议不兼容）都不改走别的服务商，
///     只在 UI 上分类提示；核心链路零依赖 AI。
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

/// 预设服务商。`baseUrl` 与默认模型由产品给定，用户只需粘 Key。
class LlmPreset {
  final String id;
  final String label;
  final String baseUrl;
  final String model;

  /// 该服务商的备选模型（主模型不可用时可手动切换，不做静默换服务商）。
  final String fallbackModel;
  final String urlHint;
  final String modelHint;

  const LlmPreset({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.model,
    required this.fallbackModel,
    required this.urlHint,
    required this.modelHint,
  });
}

/// 智谱开放平台（OpenAI 兼容端点）。三个值单独提出来，
/// 便于作为编译期默认参数（const 对象属性不能用于默认参数）。
const String kGlmBaseUrl = 'https://open.bigmodel.cn/api/paas/v4';
const String kGlmModel = 'glm-4.7-flash';
const String kGlmFallbackModel = 'glm-4-flash-250414';

/// 智谱开放平台预设。
const LlmPreset glmPreset = LlmPreset(
  id: 'glm',
  label: '智谱 GLM',
  baseUrl: kGlmBaseUrl,
  model: kGlmModel,
  fallbackModel: kGlmFallbackModel,
  urlHint: kGlmBaseUrl,
  modelHint: kGlmModel,
);

/// 任意 OpenAI 兼容服务（自填地址与模型名）。
const LlmPreset customPreset = LlmPreset(
  id: 'custom',
  label: '自定义（OpenAI 兼容）',
  baseUrl: '',
  model: '',
  fallbackModel: '',
  urlHint: 'https://your-service/v1',
  modelHint: '模型名，例如 gpt-4o-mini',
);

const List<LlmPreset> kLlmPresets = [glmPreset, customPreset];


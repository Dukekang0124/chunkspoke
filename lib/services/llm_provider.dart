import 'package:chunkspoke_flutter/services/builtin_llm.dart';
import 'package:chunkspoke_flutter/services/glm_client.dart';
import 'package:chunkspoke_flutter/services/llm_config.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';

/// 内置层鉴权失败后的退避间隔：≥60s，避免重试风暴。
const Duration _backoff = Duration(seconds: 60);

/// 双层 LLM 服务解析器（M7 补充指令）。
///
/// 优先级：用户自定义（有效） ＞ 内置兜底链 ＞ 降级本地统计。
///   - 自定义层：用户自配 OpenAI 兼容 baseUrl + model + key，开关默认关。
///   - 内置层：编译期注入的按优先级排列模型列表；某模型 401/403 时跳到下一个，
///     全部退避/失败时整体置「内置暂不可用」并降级本地。
///   - 任何失败一律静默降级，绝不崩溃、绝不阻塞主流程、绝不记日志。
class LlmProvider {
  final ProgressService p;
  final GlmClient client;
  final List<LlmConfig> _builtinsOverride;

  LlmProvider(
    this.p, {
    GlmClient? client,
    List<LlmConfig>? builtinsOverride,
  })  : client = client ?? GlmClient(),
        _builtinsOverride = builtinsOverride ?? builtinModels();

  List<LlmConfig> get _builtins => _builtinsOverride;

  /// 用户自定义层是否启用且 Key 有效。
  bool get customEnabled =>
      p.customLlmEnabled && (p.customLlmKey ?? '').isNotEmpty;

  /// 解析当前生效配置（不含可用性兜底细节）。
  /// 自定义优先；否则内置首个可用（非退避期）模型；都没有返回 null（降级）。
  LlmConfig? resolveActive() {
    if (customEnabled) {
      return LlmConfig(
        baseUrl: (p.customLlmUrl ?? '').isNotEmpty
            ? p.customLlmUrl!
            : 'https://open.bigmodel.cn/api/paas/v4',
        model: p.customLlmModel ?? '',
        key: p.customLlmKey ?? '',
      );
    }
    return _firstAvailableBuiltin();
  }

  bool _isBlocked(int i) {
    final ts = p.builtinFailTs(i);
    if (ts <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch - ts < _backoff.inMilliseconds;
  }

  LlmConfig? _firstAvailableBuiltin() {
    for (var i = 0; i < _builtins.length; i++) {
      if (!_isBlocked(i)) return _builtins[i];
    }
    return null; // 全部处于退避期
  }

  /// 内置是否整体不可用（所有模型都在退避期 / 曾失败未恢复）。
  bool get builtinUnavailable => p.builtinUnavailable;

  void _markAuthFail(int i) {
    p.setBuiltinFailTs(i, DateTime.now().millisecondsSinceEpoch);
    final now = DateTime.now().millisecondsSinceEpoch;
    final allBlocked = _builtins.asMap().entries.every((e) =>
        p.builtinFailTs(e.key) > 0 &&
        now - p.builtinFailTs(e.key) < _backoff.inMilliseconds);
    p.setBuiltinUnavailable(allBlocked);
  }

  /// 恢复内置可用性（如测试连接成功或配置变更时调用）。
  void clearBuiltinAuthFail() {
    for (var i = 0; i < _builtins.length; i++) {
      p.setBuiltinFailTs(i, 0);
    }
    p.setBuiltinUnavailable(false);
  }

  /// 统一对话入口：自动走「自定义 > 内置兜底链 > 降级」。
  ///
  /// 返回模型文本；无可用配置或任意失败返回 null（调用方静默降级）。
  /// [customOnly] 为 true 时仅尝试自定义层（用于「测试连接」语义与自定义失败不自动回退内置）。
  Future<String?> chatFallback(String prompt, {bool customOnly = false}) async {
    if (customEnabled) {
      final cfg = resolveActive()!;
      final r = await client.chatDetailed(cfg.key, prompt);
      // 自定义层 401/403 或任意失败 → 不自动回退内置，直接降级（详见验收②）。
      return r.text;
    }
    if (customOnly) return null;
    for (var i = 0; i < _builtins.length; i++) {
      if (_isBlocked(i)) continue;
      final r = await client.chatDetailed(_builtins[i].key, prompt);
      if (r.text != null) return r.text;
      if (r.status == 401 || r.status == 403) {
        _markAuthFail(i); // 该内置模型失效，跳下一个
        continue;
      }
      break; // 其它错误（超时/协议）→ 直接降级，避免重试风暴
    }
    return null;
  }

  /// 仅针对自定义层做连通性测试，返回（是否成功，原因/模型名）。
  /// 成功：reason 为模型名；失败：reason 为中文原因（超时/Key 无效/协议不兼容）。
  /// [tmp] 仅用于测试注入；缺省时按配置新建 GlmClient。
  Future<({bool ok, String reason})> testCustom({GlmClient? tmp}) async {
    final url = (p.customLlmUrl ?? '').isNotEmpty
        ? p.customLlmUrl!
        : 'https://open.bigmodel.cn/api/paas/v4';
    final model = p.customLlmModel ?? '';
    final key = p.customLlmKey ?? '';
    if (key.isEmpty) return (ok: false, reason: '请先填写 API Key');
    if (model.isEmpty) return (ok: false, reason: '请先填写模型名');
    final created = tmp == null;
    final c = tmp ?? GlmClient(endpoint: url, model: model);
    try {
      final r = await c.chatDetailed(key, 'ping');
      if (created) c.dispose();
      if (r.text != null) return (ok: true, reason: model);
      if (r.status == 401 || r.status == 403) {
        return (ok: false, reason: 'Key 无效（${r.status}）');
      }
      if (r.status == -1) return (ok: false, reason: '连接超时');
      return (ok: false, reason: '协议不兼容（${r.status}）');
    } on Object {
      if (created) c.dispose();
      return (ok: false, reason: '连接超时');
    }
  }
}

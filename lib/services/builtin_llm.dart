import 'dart:convert';
import 'package:chunkspoke_flutter/services/llm_config.dart';

/// 内置层：构建期经 `--dart-define=BUILTIN_LLM_KEYS` 注入。
///
/// 红线（务必遵守）：
///   - 明文只存在于「编译产物常量区」（libapp.so），绝不出现在任何源码文件、
///     绝不提交进 git、绝不打印 / 写日志。
///   - 值为 JSON 数组，按优先级排序；首个可用，失败（401/403）自动跳到下一个，
///     全部失败则整体降级本地统计。
///   形如：
///   [
///     {"baseUrl":"https://open.bigmodel.cn/api/paas/v4","model":"glm-5.3-flash","key":"..."},
///     {"baseUrl":"https://open.bigmodel.cn/api/paas/v4","model":"glm-4-flash","key":"..."}
///   ]
const String _builtinRaw =
    String.fromEnvironment('BUILTIN_LLM_KEYS', defaultValue: '');

/// 编译期注入的内置模型列表（按优先级）。未注入时返回空列表。
List<LlmConfig> builtinModels() {
  if (_builtinRaw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(_builtinRaw);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().map(LlmConfig.fromJson).toList();
  } catch (_) {
    // 注入格式异常：宁可降级也不让崩溃。
    return const [];
  }
}

/// 是否有任何内置模型可用（注入非空即视为有）。
bool hasBuiltin() => builtinModels().isNotEmpty;

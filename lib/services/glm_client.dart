import 'dart:convert';
import 'package:http/http.dart' as http;

/// GLM-4-Flash 可选 AI 助手客户端（M7）。
///
/// 红线（务必遵守）：
///   - 不传任何录音原文；调用方只传词块 ID 与统计摘要（见 ai_coach.dart）。
///   - API Key 只用于 Authorization 头，绝不打印 / 写入日志。
///   - 任何失败（无 Key / 超时 / 非 200 / 解析异常）一律静默降级返回 null，
///     绝不抛出，绝不阻塞主流程。
///
/// 端点遵循 OpenAI 兼容协议： POST {endpoint}/chat/completions
class GlmClient {
  final String endpoint;
  final String model;
  final Duration timeout;
  final http.Client _client;

  GlmClient({
    this.endpoint = 'https://open.bigmodel.cn/api/paas/v4',
    this.model = 'glm-4-flash',
    this.timeout = const Duration(seconds: 10),
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// 发送一条 user 消息，返回模型文本；任何异常返回 null（降级）。
  Future<String?> chat(String apiKey, String prompt) async {
    final r = await chatDetailed(apiKey, prompt);
    return r.text;
  }

  /// 与 [chat] 相同，但额外回传 HTTP 状态码，便于调用方区分鉴权失败（401/403）
  /// 与网络异常（用于退避 / 兜底链切换）。异常或空 Key 时 status 为 -1。
  Future<({String? text, int status})> chatDetailed(
      String apiKey, String prompt) async {
    if (apiKey.isEmpty) return (text: null, status: -1); // 无 Key → 静默降级
    try {
      final resp = await _client
          .post(
            Uri.parse('$endpoint/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey', // Key 仅在此处，从不日志
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'user', 'content': prompt}
              ],
              'temperature': 0.6,
            }),
          )
          .timeout(timeout);
      if (resp.statusCode != 200) {
        return (text: null, status: resp.statusCode);
      }
      // 显式按 UTF-8 解码，避免响应缺 charset 头时被错误地用 latin1 解码（中文乱码）。
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) return (text: null, status: 200);
      final msg = choices[0]['message'] as Map<String, dynamic>;
      return (text: msg['content'] as String?, status: 200);
    } on Object {
      return (text: null, status: -1); // 网络/超时/解析失败：静默降级
    }
  }

  void dispose() => _client.close();
}

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'llm_config.dart';

/// 一次调用（含失败）的完整回包信息，供设置页「测试连接」如实展示。
///
/// 红线：只回传服务端自己给的错误码/错误信息与「是否超时」，
/// 不打印、不落盘、不上传；API Key 绝不进入本结构。
class GlmReply {
  /// HTTP 状态码；-1 = 没拿到响应（超时/断网/解析失败/无 Key）。
  final int status;

  /// 成功时的模型文本。
  final String? text;

  /// 服务端错误码（如智谱的 1302），缺失为空串。
  final String code;

  /// 服务端错误信息（已截断到 200 字），缺失为空串。
  final String message;

  /// 是否因超时失败（用于给「高峰期可能较慢」的专门提示）。
  final bool timedOut;

  const GlmReply({
    required this.status,
    this.text,
    this.code = '',
    this.message = '',
    this.timedOut = false,
  });
}

/// OpenAI 兼容客户端（默认智谱 GLM，1.5.8 起不再有任何内置 Key）。
///
/// 红线（务必遵守）：
///   - 不传任何录音原文；调用方只传词块 ID 与统计摘要（见 ai_coach.dart）。
///   - API Key 只用于 Authorization 头，绝不打印 / 写入日志。
///   - 失败一律返回状态码由调用方分类提示（401/403 鉴权、429 限流、-1 超时），
///     绝不抛出，绝不阻塞主流程，也不自动改走别的服务商。
///
/// 端点遵循 OpenAI 兼容协议： POST {endpoint}/chat/completions
class GlmClient {
  final String endpoint;
  final String model;
  final Duration timeout;
  final http.Client _client;

  GlmClient({
    this.endpoint = kGlmBaseUrl,
    this.model = kGlmModel,
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
    final r = await chatProbe(apiKey, prompt);
    return (text: r.text, status: r.status);
  }

  /// 带错误码/错误信息的调用（设置页「测试连接」用）。
  /// 非 200 时解析服务端返回的 `error.code` / `error.message`，原样透出给用户；
  /// 超时单独标记 [GlmReply.timedOut]，便于给出「高峰期请勿重复点击」的提示。
  Future<GlmReply> chatProbe(String apiKey, String prompt) async {
    if (apiKey.isEmpty) {
      return const GlmReply(status: -1, message: '未填写 API Key');
    }
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
        var code = '';
        var msg = '';
        try {
          final data = jsonDecode(utf8.decode(resp.bodyBytes));
          if (data is Map) {
            final err = data['error'];
            if (err is Map) {
              code = (err['code'] ?? '').toString();
              msg = (err['message'] ?? '').toString();
            } else if (err != null) {
              msg = err.toString();
            } else if (data['message'] != null) {
              msg = data['message'].toString();
            }
          }
        } catch (_) {
          // 错误体不是 JSON（网关 HTML/空体）：只回状态码，不干扰用户。
        }
        if (msg.length > 200) msg = '${msg.substring(0, 200)}…';
        return GlmReply(
          status: resp.statusCode,
          code: code,
          message: msg,
        );
      }
      // 显式按 UTF-8 解码，避免响应缺 charset 头时被错误地用 latin1 解码（中文乱码）。
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        return const GlmReply(status: 200);
      }
      final msg = choices[0]['message'] as Map<String, dynamic>;
      return GlmReply(status: 200, text: msg['content'] as String?);
    } on TimeoutException {
      return const GlmReply(status: -1, timedOut: true);
    } on Object {
      return const GlmReply(status: -1); // 网络/解析失败：静默降级
    }
  }

  void dispose() => _client.close();
}

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ai_models.dart';

/// baseUrl / appToken 通过编译期 --dart-define 注入（见 chunkspoke-ai/README.md），
/// 不要硬编码真实值到源码或注释里。
const String _kDefaultBaseUrl = String.fromEnvironment(
  'AI_BASE_URL',
  defaultValue: 'https://chunkspoke-ai.pages.dev',
);
const String _kDefaultAppToken = String.fromEnvironment(
  'AI_APP_TOKEN',
  defaultValue: 'chunkspoke_2026_secure_token_change_me',
);

/// AI 后端抽象接口（Retrofit 风格契约）。实现见 [AIServiceImpl]。
abstract class AIService {
  /// 智能周报：返回中文报告文本；失败/降级时返回兜底文案（不抛异常）。
  Future<String> fetchWeeklyReport(UserData data);

  /// 错因分析：返回中文建议文本；失败返回兜底文案。
  /// 调用方应仅在「同一句连续错 2 次」时调用（节流由调用方控制）。
  Future<String> analyzeError(ErrorData data);

  /// 自由造句评判：返回结构化 [JudgeResult]；失败/无网络返回 null（调用方回退规则引擎）。
  Future<JudgeResult?> judgeFreeBuild(BuildData data);

  /// 释放底层 http.Client（实现类持有连接池）。
  void dispose();
}

class AIServiceImpl implements AIService {
  final String baseUrl;
  final String appToken;
  final http.Client _client;

  AIServiceImpl({
    String? baseUrl,
    String? appToken,
    http.Client? client,
  })  : baseUrl = (baseUrl ?? _kDefaultBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        appToken = appToken ?? _kDefaultAppToken,
        _client = client ?? http.Client();

  static String get _today => DateTime.now().toIso8601String().substring(0, 10);

  // 周报每日仅请求一次（内存缓存，跨启动持久化见 README）。
  static String? _weeklyCache;
  static String? _weeklyCacheDate;

  Future<AIResponse?> _post(AIRequest req) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$baseUrl/api/ai'),
            headers: {
              'Content-Type': 'application/json',
              'X-App-Token': appToken,
            },
            body: jsonEncode(req.toJson()),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 401) {
        return const AIResponse(success: false, error: 'unauthorized', fallback: '请更新到最新版本');
      }
      if (resp.statusCode == 429) {
        return const AIResponse(success: false, error: 'quota', fallback: '今日 AI 次数已用完，明天再来吧');
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return AIResponse.fromJson(j);
    } on http.ClientException catch (e) {
      // 断网 / DNS 失败：交给调用方降级
      return AIResponse(success: false, error: e.message, fallback: '网络开小差了，请检查网络');
    } catch (e) {
      return AIResponse(success: false, error: e.toString(), fallback: 'AI 正在休息，请稍后再试');
    }
  }

  @override
  Future<String> fetchWeeklyReport(UserData data) async {
    if (_weeklyCache != null && _weeklyCacheDate == _today) return _weeklyCache!;
    final resp = await _post(AIRequest(action: 'weekly_report', userData: data));
    final text = resp?.success == true ? (resp!.data?.content?.trim() ?? '') : '';
    if (text.isNotEmpty) {
      _weeklyCache = text;
      _weeklyCacheDate = _today;
      return text;
    }
    return resp?.fallback ?? 'AI 正在休息，请稍后再试';
  }

  @override
  Future<String> analyzeError(ErrorData data) async {
    final resp = await _post(AIRequest(action: 'error_analysis', errorData: data));
    final text = resp?.success == true ? (resp!.data?.content?.trim() ?? '') : '';
    if (text.isNotEmpty) return text;
    return resp?.fallback ?? 'AI 正在休息，请稍后再试';
  }

  @override
  Future<JudgeResult?> judgeFreeBuild(BuildData data) async {
    final resp = await _post(AIRequest(action: 'free_build_judge', buildData: data));
    if (resp?.success == true && resp!.data?.result != null) return resp.data!.result;
    return null; // 调用方（free_build_screen）回退到离线规则引擎
  }

  @override
  void dispose() => _client.close();
}

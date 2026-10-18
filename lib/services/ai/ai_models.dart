// ChunkSpoke AI 后端数据模型（对应 POST /api/ai 契约）。
// 后端：Cloudflare Workers（代调智谱 GLM-4-Flash）。详见 chunkspoke-ai/。

/// 周报输入
class UserData {
  final int totalChunks;
  final int practiceDays;
  final int completedScenarios;
  final List<String> weakChunks;
  final int freeBuildCount;
  final int streakDays;

  const UserData({
    this.totalChunks = 0,
    this.practiceDays = 0,
    this.completedScenarios = 0,
    this.weakChunks = const [],
    this.freeBuildCount = 0,
    this.streakDays = 0,
  });

  Map<String, dynamic> toJson() => {
        'totalChunks': totalChunks,
        'practiceDays': practiceDays,
        'completedScenarios': completedScenarios,
        'weakChunks': weakChunks,
        'freeBuildCount': freeBuildCount,
        'streakDays': streakDays,
      };
}

/// 错因分析输入
class ErrorData {
  final String scenario;
  final String targetSentence;
  final String userSpeech;

  const ErrorData({
    this.scenario = '',
    this.targetSentence = '',
    this.userSpeech = '',
  });

  Map<String, dynamic> toJson() => {
        'scenario': scenario,
        'targetSentence': targetSentence,
        'userSpeech': userSpeech,
      };
}

/// 自由造句评判输入
class BuildData {
  final String scenario;
  final String chinesePrompt;
  final List<String> availableChunks;
  final String userSpeech;

  const BuildData({
    this.scenario = '',
    this.chinesePrompt = '',
    this.availableChunks = const [],
    this.userSpeech = '',
  });

  Map<String, dynamic> toJson() => {
        'scenario': scenario,
        'chinesePrompt': chinesePrompt,
        'availableChunks': availableChunks,
        'userSpeech': userSpeech,
      };
}

/// 统一请求体
class AIRequest {
  final String action;
  final UserData? userData;
  final ErrorData? errorData;
  final BuildData? buildData;

  const AIRequest({
    required this.action,
    this.userData,
    this.errorData,
    this.buildData,
  });

  Map<String, dynamic> toJson() => {
        'action': action,
        if (userData != null) 'userData': userData!.toJson(),
        if (errorData != null) 'errorData': errorData!.toJson(),
        if (buildData != null) 'buildData': buildData!.toJson(),
      };
}

/// 自由造句评判结果（data.result）
class JudgeResult {
  final int score; // 1-5
  final String feedback;
  final String corrected;

  const JudgeResult({
    this.score = 0,
    this.feedback = '',
    this.corrected = '',
  });

  factory JudgeResult.fromJson(Map<String, dynamic> j) => JudgeResult(
        score: (j['score'] as num?)?.toInt() ?? 0,
        feedback: (j['feedback'] as String?) ?? '',
        corrected: (j['corrected'] as String?) ?? '',
      );
}

/// data 字段
class AIData {
  final String? type;
  final String? content; // weekly_report / error_analysis 的文本
  final JudgeResult? result; // free_build_judge 的结构化结果

  const AIData({this.type, this.content, this.result});

  factory AIData.fromJson(Map<String, dynamic> j) {
    JudgeResult? r;
    if (j['result'] != null && j['type'] == 'free_build_judge') {
      r = JudgeResult.fromJson(j['result'] as Map<String, dynamic>);
    }
    return AIData(
      type: j['type'] as String?,
      content: j['content'] as String?,
      result: r,
    );
  }
}

/// 统一响应体
class AIResponse {
  final bool success;
  final AIData? data;
  final String? error;
  final String? fallback;

  const AIResponse({
    this.success = false,
    this.data,
    this.error,
    this.fallback,
  });

  factory AIResponse.fromJson(Map<String, dynamic> j) => AIResponse(
        success: j['success'] as bool? ?? false,
        data: j['data'] != null ? AIData.fromJson(j['data'] as Map<String, dynamic>) : null,
        error: j['error'] as String?,
        fallback: j['fallback'] as String?,
      );
}

import 'dart:convert';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/llm_provider.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';

/// 单日学习计划：复习 M 个 + 新学 N 个。
class DayPlan {
  final DateTime day;
  final int reviewCount;
  final int newCount;
  DayPlan(this.day, this.reviewCount, this.newCount);
}

/// AI 教练（M7 / 双层 LLM 服务）。
///
/// 三条红线（在 LlmProvider 与调用方共同保证）：
///   1) 绝不传录音原文 —— 周报只发统计摘要 + 词块 ID；变式只发词块自身文本。
///   2) Key 不进日志 —— GlmClient 只在 Authorization 头使用。
///   3) LLM 失败不阻塞主流程 —— 任何一步返回 null 即降级。
class AiCoach {
  final LlmProvider _provider;

  AiCoach(ProgressService p, {LlmProvider? provider})
      : _provider = provider ?? LlmProvider(p);

  /// 周报：仅用统计摘要 + 词块 ID（无录音原文），LLM 生成 ≤200 字中文诊断+建议。
  /// 返回文本或 null（无可用模型 / 降级）。
  Future<String?> weeklyReport(ProgressService p, ContentPack c) async {
    final store = p.chunkStore;
    final spoken = await store.spokenCount();
    final avg = (await store.avgScore()).round();
    final stuck = await store.topFail(5);
    final stuckIds = stuck.map((r) => r.chunkKey).toList();
    final weak = await _weakScenes(p, c);
    // 仅统计 + 词块 ID，绝不出现任何录音文本。
    final summary = const JsonEncoder().convert({
      'task': 'weekly_cn_diagnosis',
      'spoken_sentences': spoken,
      'avg_score': avg,
      'top_stuck_chunk_ids': stuckIds,
      'weak_scenes': weak,
    });
    const sys = '你是英语口语教练。下面是学员一周的学习统计摘要'
        '（只有数字与词块ID，没有任何录音原文）。请用不超过200字中文给出：'
        '1）诊断；2）下周建议。只输出诊断与建议正文。';
    return _provider.chatFallback('$sys\n$summary');
  }

  Future<List<String>> _weakScenes(ProgressService p, ContentPack c) async {
    final mastered = (await p.chunkStore.allMasteredKeys()).toSet();
    final weak = <String>[];
    for (final lv in c.levels) {
      final m = lv.chunks.where((ch) => mastered.contains(ch.id)).length;
      if (lv.chunks.isNotEmpty && m / lv.chunks.length < 0.5) weak.add(lv.id);
    }
    return weak;
  }

  /// 学习计划：本地按 due_date + fail_count 生成未来 7 天（复习 M + 新学 N≤5）。
  /// 不依赖网络；LLM 仅作可选润色（此处返回本地安排，稳定可离线）。
  Future<List<DayPlan>> studyPlan(ProgressService p, ContentPack c) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var due = (await p.chunkStore
            .dueChunkKeys(today.millisecondsSinceEpoch))
        .length;
    final mastered = (await p.chunkStore.allMasteredKeys()).toSet();
    var fresh = c.levels
        .expand((l) => l.chunks)
        .where((ch) => !mastered.contains(ch.id))
        .length;

    final plans = <DayPlan>[];
    for (var i = 0; i < 7; i++) {
      final d = today.add(Duration(days: i));
      // 剩余复习均摊到剩余天数；新学每日 ≤5。
      final review = due > 0 ? ((due / (7 - i)).ceil()) : 0;
      final gotReview = review.clamp(0, due);
      final gotNew = fresh > 0 ? 5.clamp(0, fresh) : 0;
      plans.add(DayPlan(d, gotReview, gotNew));
      due -= gotReview;
      fresh -= gotNew;
    }
    return plans;
  }

  /// 变式造句：取 2 个已掌握词块，让 LLM 生成新中文场景提示 + 目标英文句。
  /// 返回 {cn_prompt, target, a, b} 或 null（无可用模型 / 不足 2 个已掌握 / 降级）。
  /// 注意：只发送词块自身文本（学习素材），绝不发送用户录音原文。
  Future<Map<String, String>?> variantTask(
      ProgressService p, ContentPack c) async {
    final mastered = (await p.chunkStore.allMasteredKeys()).toSet();
    final pool = c.levels
        .expand((l) => l.chunks)
        .where((ch) => mastered.contains(ch.id))
        .toList();
    if (pool.length < 2) return null; // 不足 2 个已掌握 → 降级（不阻塞）
    pool.shuffle();
    final a = pool[0];
    final b = pool[1];
    final prompt = '用这两个英文词块造一个真实场景的中文提示，并给出目标英文句子。'
        '词块A="${a.text}"(中文:${a.meaningCN})；词块B="${b.text}"(中文:${b.meaningCN})。'
        '严格只返回 JSON：{"cn_prompt":"中文场景提示","target":"English target sentence"}。';
    final out = await _provider.chatFallback(prompt);
    if (out == null) return null;
    try {
      final m = jsonDecode(out) as Map<String, dynamic>;
      return {
        'cn_prompt': (m['cn_prompt'] as String?) ?? '',
        'target': (m['target'] as String?) ?? '',
        'a': a.text,
        'b': b.text,
      };
    } on Object {
      return null; // 解析失败降级
    }
  }
}

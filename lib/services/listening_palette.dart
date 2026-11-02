import 'dart:ui' show Color;

import '../models/listening_article.dart';
import '../ui/theme.dart';
import 'chunk_asset.dart';

/// 文章内词块的三色阶梯（Q-4 裁定）：
/// 蓝（候选）→ 琥珀（在学）→ 金（已掌握）。
///
/// 候选块没有词块资产行，颜色只由 [ListeningChunk.candidate] 决定；
/// 既有块只有真正存在资产行时才着色，未知 id 不渲染任何强调。
enum ListeningChunkTone { none, candidate, learning, mastered }

/// 三色取值集中在此，页面与 E2E 探针共用，避免改色时断言各说各话。
/// 1.7.0 起改为令牌 getter：色相语义不变（蓝/琥珀/金），明暗随主题走，
/// 浅色下不会出现白字白底。
Color get kListeningCandidateText => kInfo;
Color get kListeningCandidateBg => kInfoTint;
Color get kListeningLearningText => kPrimary;
Color get kListeningLearningBg => kPrimaryTint;
Color get kListeningMasteredText => kWarning;
Color get kListeningMasteredBg => kWarningTint;

ListeningChunkTone listeningChunkTone(
  ListeningChunk chunk,
  Map<String, ChunkAssetState> states,
) {
  if (chunk.candidate) return ListeningChunkTone.candidate;
  final state = states[chunk.id];
  if (state == null) return ListeningChunkTone.none;
  return state == ChunkAssetState.mastered
      ? ListeningChunkTone.mastered
      : ListeningChunkTone.learning;
}

/// CEFR 级别徽标色（指令 S §一.4）。与三色阶梯刻意分开：
/// 级别是「篇目属性」，三色是「块状态」，两套语义不得混用同一颜色含义。
/// 级别色相是固定语义（绿→青→蓝→紫→橙），不随主题换色相；
/// 只在浅色主题下统一压暗，保证白底可读。用 getter：切主题后立刻重新取值。
Color get kListeningLevelA1 => adaptiveAccent(const Color(0xFF8BC34A));
Color get kListeningLevelA2 => adaptiveAccent(const Color(0xFF4DD0E1));
Color get kListeningLevelB1 => adaptiveAccent(const Color(0xFF90CAF9));
Color get kListeningLevelB2 => adaptiveAccent(const Color(0xFFB39DDB));
Color get kListeningLevelC1 => adaptiveAccent(const Color(0xFFFF8A65));

Color listeningLevelColor(ListeningLevel level) {
  switch (level) {
    case ListeningLevel.a1:
      return kListeningLevelA1;
    case ListeningLevel.a2:
      return kListeningLevelA2;
    case ListeningLevel.b1:
      return kListeningLevelB1;
    case ListeningLevel.b2:
      return kListeningLevelB2;
    case ListeningLevel.c1:
      return kListeningLevelC1;
  }
}

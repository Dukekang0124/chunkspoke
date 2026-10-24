import 'dart:ui' show Color;

import '../models/listening_article.dart';
import 'chunk_asset.dart';

/// 文章内词块的三色阶梯（Q-4 裁定）：
/// 蓝（候选）→ 琥珀（在学）→ 金（已掌握）。
///
/// 候选块没有词块资产行，颜色只由 [ListeningChunk.candidate] 决定；
/// 既有块只有真正存在资产行时才着色，未知 id 不渲染任何强调。
enum ListeningChunkTone { none, candidate, learning, mastered }

/// 三色取值集中在此，页面与 E2E 探针共用，避免改色时断言各说各话。
const Color kListeningCandidateText = Color(0xFF90CAF9);
const Color kListeningCandidateBg = Color(0x3364B5F6);
const Color kListeningLearningText = Color(0xFFFFB84D);
const Color kListeningLearningBg = Color(0x1FFFB84D);
const Color kListeningMasteredText = Color(0xFFFFD54F);
const Color kListeningMasteredBg = Color(0x40FFD54F);

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
const Color kListeningLevelA1 = Color(0xFF8BC34A);
const Color kListeningLevelA2 = Color(0xFF4DD0E1);
const Color kListeningLevelB1 = Color(0xFF90CAF9);
const Color kListeningLevelB2 = Color(0xFFB39DDB);
const Color kListeningLevelC1 = Color(0xFFFF8A65);

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

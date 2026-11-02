import 'package:flutter/material.dart';

import '../services/pronunciation_score.dart';
import 'theme.dart';

/// 发音评测结果卡（1.5.9）：整体分 + 档位徽标 + 逐词三档着色。
/// 抽成公开组件，仅为可被 widget 测试直接渲染三档配色；
/// 行为与 `pronunciation_screen` 内原私有实现一致，不改判定口径。
class PronResultCard extends StatelessWidget {
  final PronScoreResult result;
  const PronResultCard({super.key, required this.result});

  static Color tierColor(PronTier t) {
    switch (t) {
      case PronTier.good:
        return kUnlocked;
      case PronTier.near:
        return kPrimary;
      case PronTier.miss:
        return kError;
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r.noSpeech) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kCard, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('没听到声音',
                style: TextStyle(color: kText, fontSize: 15)),
            const SizedBox(height: 6),
            Text('靠近一点、正常语速再读一遍；也可以先点「听示范」。',
                style: TextStyle(
                    color: kTextMuted, fontSize: 12, height: 1.5)),
            if (r.recognized.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('识别到：${r.recognized}',
                  style: TextStyle(color: kTextFaint, fontSize: 11)),
            ],
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration:
          BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${r.overall}',
                  style: TextStyle(
                      color: kText,
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      height: 1)),
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 4),
                child: Text('分', style: TextStyle(color: kTextMuted)),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      (r.passed ? kUnlocked : kPrimary).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  r.passed ? '通过 · ${r.band}' : '再练一次 · ${r.band}',
                  style: TextStyle(
                      color: r.passed ? kUnlocked : kPrimary, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final w in r.words)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: tierColor(w.tier).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: tierColor(w.tier).withValues(alpha: 0.55)),
                  ),
                  child: Text(w.word,
                      style: TextStyle(
                          color: tierColor(w.tier),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('绿 ${r.goodCount} · 黄 ${r.nearCount} · 红 ${r.missCount}',
              style: TextStyle(color: kTextFaint, fontSize: 11)),
          if (r.recognized.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('听到：${r.recognized}',
                style: TextStyle(color: kTextFaint, fontSize: 11)),
          ],
          const SizedBox(height: 10),
          Text('黄档是缩读、连读或虚词——能听懂就不算错；红了才需要再说一遍。',
              style:
                  TextStyle(color: kBorderStrong, fontSize: 11, height: 1.4)),
        ],
      ),
    );
  }
}

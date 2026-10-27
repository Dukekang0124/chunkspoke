// Web ↔ App SRS 对拍：直接 import 两端真实逻辑文件（App 只读，不修改其工作树）。
// App 侧：lib/services/review_scheduler.dart + chunk_asset.dart（HEAD 1d4468e）
// Web 侧：lib/data/review_rules.dart
import 'file:///D:/cs_build/lib/services/chunk_asset.dart';
import 'file:///D:/cs_build/lib/services/review_scheduler.dart';
import 'file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/data/review_rules.dart';
import 'file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/data/vocab.dart';
import 'file:///D:/写作工具/知识管理/01-Projects-项目/求职与作品集/03-作品集/chunkspoke/web-app/lib/storage/records.dart';

const int day = 24 * 60 * 60 * 1000;
const int t0 = 1730000000000; // 固定时钟，序列可复算

Map<ChunkAssetState, AssetState> toWeb = {
  ChunkAssetState.learning: AssetState.learning,
  ChunkAssetState.consolidating: AssetState.consolidating,
  ChunkAssetState.consolidated: AssetState.consolidated,
  ChunkAssetState.longTerm: AssetState.longTerm,
  ChunkAssetState.mastered: AssetState.mastered,
  ChunkAssetState.relearning: AssetState.relearning,
};

/// 20 块 × 3 档自评：每块走 12 步，前 10 块用纯通过链到已掌握，
/// 后 10 块混入重学/保留（含从「需重修」回位）。
List<List<ReviewGrade>> patterns() {
  const g = ReviewGrade.values; // retry, keep, pass（wire 1/2/3）
  final pure = <ReviewGrade>[g[2], g[2], g[2], g[2], g[2], g[2]];
  final mixed = <ReviewGrade>[
    g[2], g[1], g[2], g[0], g[2], g[2], g[1], g[0], g[2], g[2], g[2], g[2],
  ];
  return [for (var i = 0; i < 20; i++) i < 10 ? pure : mixed];
}

class Case {
  Case(this.id, this.web, this.app, this.startDue);
  final String id;
  ChunkRecord web;
  ChunkAssetSnapshot app;
  int startDue;
}

int appDue(DateTime at, ChunkAssetSnapshot s, int prevDue) {
  switch (s.state) {
    case ChunkAssetState.learning:
    case ChunkAssetState.mastered:
      return prevDue; // 不排期：KEEP 命中原值
    default:
      return prevDue;
  }
}

void main() {
  final cases = <Case>[];
  for (var i = 0; i < 20; i++) {
    final due = t0 + day;
    if (i < 15) {
      // 学完之后：巩固中 stage 0，首次到期 +1d
      cases.add(Case('c${i + 1}',
          ChunkRecord(id: 'c${i + 1}', tier: 'T0', assetState: AssetState.consolidating, reviewStage: 0, dueDate: due),
          const ChunkAssetSnapshot(state: ChunkAssetState.consolidating, stage: 0),
          due));
    } else {
      // 从 App 导入的「需重修 + 回退点（已巩固 stage 1）」
      const back = ChunkAssetState.consolidated;
      const backStage = 1;
      cases.add(Case('c${i + 1}',
          ChunkRecord(
            id: 'c${i + 1}', tier: 'T0', assetState: AssetState.relearning,
            assetReturnStateIndex: AssetState.values.indexOf(AssetState.consolidated),
            assetReturnStage: backStage, reviewStage: backStage, dueDate: due,
          ),
          const ChunkAssetSnapshot(
            state: ChunkAssetState.relearning, stage: 0,
            returnState: back, returnStage: backStage,
          ),
          due));
    }
  }

  final pats = patterns();
  var checks = 0, bad = 0;
  for (var i = 0; i < cases.length; i++) {
    final c = cases[i];
    var now = c.startDue;
    final seq = <String>[];
    for (final grade in pats[i]) {
      // —— Web：真实函数
      final webOut = applyReviewGrade(c.web, grade, now);
      // —— App：真实状态机 + 方案 §六-2 的三档映射
      late int appOut;
      late ChunkAssetSnapshot appSnap;
      if (grade == ReviewGrade.pass) {
        appSnap = ChunkAssetMachine.reviewPass(c.app);
        appOut = ChunkAssetMachine.nextDue(DateTime.fromMillisecondsSinceEpoch(now), appSnap)
                ?.millisecondsSinceEpoch ??
            0;
      } else {
        // 重学 / 保留 → App 的 deferReview：状态档位不动，到期推到明天
        appSnap = c.app;
        appOut = c.app.state.isReviewable ? now + day : c.web.dueDate;
      }
      checks++;
      final same = webOut.dueDate == appOut;
      if (!same) bad++;
      seq.add('${grade.wire}:${webOut.dueDate}${same ? '' : "≠$appOut"}');
      if (!same || webOut.dueDate == 0) {
        if (!same) {
          print('MISMATCH ${c.id} grade=${grade.wire} web=${webOut.dueDate} app=$appOut');
        }
        break; // 已掌握（due=0）后不再排期
      }
      c.web = webOut.copyWith(lastReviewAt: 0, updatedAt: 0);
      c.app = appSnap;
      now = webOut.dueDate;
      if (c.web.reviewStage >= kMasteredStage) break;
    }
    print('${c.id}: ${seq.join(' ')}');
  }
  print('\nchecks=$checks mismatches=$bad');
  print(bad == 0 ? 'PARITY RESULT: PASS' : 'PARITY RESULT: FAIL');
}

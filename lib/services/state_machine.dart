// L1-L4 chunk state machine for the practice loop.
// Pure logic — no I/O — fully unit-testable.
//
// Transition semantics (M1 spec):
//   L1  learn/assemble      -> L2 on assembleCorrect
//   L2  drag/assemble        -> L3 on dragCorrect; dragWrong = retry in place
//   L3  speak (scored)       -> L4 on accuracyPass (Accuracy>=70); accuracyFail = retry
//   L4  open speak           -> review on speakSuccess; speakFail counts toward failx2
//   review                   -> mastered on speakSuccess; else stays in review
//   mastered                 -> terminal
// Counter-driven demotion (L4 fail x2 -> back to L3) is owned by ChunkProgressStore,
// which holds per-chunk state; this class models single-step transitions only.

enum ChunkLevel { l1, l2, l3, l4, review, mastered }

enum ChunkEvent {
  assembleCorrect, // L1 -> L2
  dragCorrect, // L2 -> L3
  dragWrong, // L2 fail (retry)
  accuracyPass, // L3 -> L4 (Accuracy >= 70)
  accuracyFail, // L3 fail (retry)
  speakSuccess, // L4 -> review
  speakFail, // L4 fail (counts toward fail x2)
  scheduleReview, // 学习阶段主动跳过/延期 -> review（次日到期）
  deferReview, // 复习阶段主动跳过 -> 不改资产状态，仅次日再到期
}

class ChunkStateMachine {
  static ChunkLevel transition(ChunkLevel current, ChunkEvent event) {
    if (event == ChunkEvent.scheduleReview) return ChunkLevel.review;
    switch (current) {
      case ChunkLevel.l1:
        return event == ChunkEvent.assembleCorrect ? ChunkLevel.l2 : ChunkLevel.l1;
      case ChunkLevel.l2:
        if (event == ChunkEvent.dragCorrect) return ChunkLevel.l3;
        return ChunkLevel.l2; // dragWrong or others: retry in place
      case ChunkLevel.l3:
        if (event == ChunkEvent.accuracyPass) return ChunkLevel.l4;
        return ChunkLevel.l3; // accuracyFail or others: retry
      case ChunkLevel.l4:
        if (event == ChunkEvent.speakSuccess) return ChunkLevel.review;
        return ChunkLevel.l4; // speakFail: store tracks the fail count
      case ChunkLevel.review:
        return event == ChunkEvent.speakSuccess ? ChunkLevel.mastered : ChunkLevel.review;
      case ChunkLevel.mastered:
        return ChunkLevel.mastered;
    }
  }
}

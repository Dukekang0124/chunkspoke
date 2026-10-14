// Spaced-repetition scheduler: 1/3/7/14 day intervals (M1 spec).
// Pure logic — no I/O — fully unit-testable.
class ReviewScheduler {
  static const List<int> intervalsDays = [1, 3, 7, 14];

  // Due date for the (reviewStage)-th review, counting from `from`.
  // Stage is clamped so an over-range stage still yields the longest interval.
  static DateTime nextDue(DateTime from, int reviewStage) {
    final idx = reviewStage.clamp(0, intervalsDays.length - 1);
    return from.add(Duration(days: intervalsDays[idx]));
  }

  // A chunk is mastered once it has cleared all scheduled reviews.
  static bool isMastered(int completedReviews) =>
      completedReviews >= intervalsDays.length;

  // Advance the review stage; returns the new stage (capped at interval count).
  static int advanceStage(int stage) =>
      (stage + 1).clamp(0, intervalsDays.length);
}

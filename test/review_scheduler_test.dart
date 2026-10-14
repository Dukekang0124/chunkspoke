import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/review_scheduler.dart';

void main() {
  test('intervals are 1/3/7/14', () {
    expect(ReviewScheduler.intervalsDays, [1, 3, 7, 14]);
  });
  test('nextDue adds the correct number of days', () {
    final base = DateTime(2026, 1, 1);
    expect(ReviewScheduler.nextDue(base, 0), DateTime(2026, 1, 2));
    expect(ReviewScheduler.nextDue(base, 1), DateTime(2026, 1, 4));
    expect(ReviewScheduler.nextDue(base, 2), DateTime(2026, 1, 8));
    expect(ReviewScheduler.nextDue(base, 3), DateTime(2026, 1, 15));
  });
  test('stage clamps to the longest interval', () {
    final base = DateTime(2026, 1, 1);
    expect(ReviewScheduler.nextDue(base, 99).difference(base).inDays, 14);
  });
  test('isMastered after all four reviews', () {
    expect(ReviewScheduler.isMastered(3), isFalse);
    expect(ReviewScheduler.isMastered(4), isTrue);
  });
}

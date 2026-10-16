import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

void main() {
  group('ChunkStateMachine full transition table', () {
    test('L1', () {
      expect(ChunkStateMachine.transition(ChunkLevel.l1, ChunkEvent.assembleCorrect),
          ChunkLevel.l2);
      expect(ChunkStateMachine.transition(ChunkLevel.l1, ChunkEvent.dragWrong),
          ChunkLevel.l1);
    });
    test('L2', () {
      expect(ChunkStateMachine.transition(ChunkLevel.l2, ChunkEvent.dragCorrect),
          ChunkLevel.l3);
      expect(ChunkStateMachine.transition(ChunkLevel.l2, ChunkEvent.dragWrong),
          ChunkLevel.l2);
    });
    test('L3', () {
      expect(ChunkStateMachine.transition(ChunkLevel.l3, ChunkEvent.accuracyPass),
          ChunkLevel.l4);
      expect(ChunkStateMachine.transition(ChunkLevel.l3, ChunkEvent.accuracyFail),
          ChunkLevel.l3);
    });
    test('L4', () {
      expect(ChunkStateMachine.transition(ChunkLevel.l4, ChunkEvent.speakSuccess),
          ChunkLevel.review);
      expect(ChunkStateMachine.transition(ChunkLevel.l4, ChunkEvent.speakFail),
          ChunkLevel.l4);
    });
    test('review', () {
      expect(ChunkStateMachine.transition(ChunkLevel.review, ChunkEvent.speakSuccess),
          ChunkLevel.mastered);
      expect(ChunkStateMachine.transition(ChunkLevel.review, ChunkEvent.speakFail),
          ChunkLevel.review);
    });
    test('mastered is terminal', () {
      expect(ChunkStateMachine.transition(ChunkLevel.mastered, ChunkEvent.speakSuccess),
          ChunkLevel.mastered);
    });
  });

  group('per-chunk closed loop (M8 in-block transition chain)', () {
    test('L1->L2->L3->L4->review->mastered walks the full chain', () {
      var lvl = ChunkLevel.l1;
      lvl = ChunkStateMachine.transition(lvl, ChunkEvent.assembleCorrect);
      expect(lvl, ChunkLevel.l2);
      lvl = ChunkStateMachine.transition(lvl, ChunkEvent.dragCorrect);
      expect(lvl, ChunkLevel.l3);
      lvl = ChunkStateMachine.transition(lvl, ChunkEvent.accuracyPass);
      expect(lvl, ChunkLevel.l4);
      lvl = ChunkStateMachine.transition(lvl, ChunkEvent.speakSuccess);
      expect(lvl, ChunkLevel.review);
      lvl = ChunkStateMachine.transition(lvl, ChunkEvent.speakSuccess);
      expect(lvl, ChunkLevel.mastered);
    });
    test('fail never skips: L2 wrong stays L2, L4 fail stays L4', () {
      expect(ChunkStateMachine.transition(ChunkLevel.l2, ChunkEvent.dragWrong),
          ChunkLevel.l2);
      expect(ChunkStateMachine.transition(ChunkLevel.l4, ChunkEvent.speakFail),
          ChunkLevel.l4);
    });
  });
}

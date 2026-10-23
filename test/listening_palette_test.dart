import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/listening_palette.dart';

ListeningChunk _chunk({String id = 'c01', bool candidate = false}) =>
    ListeningChunk(id: id, text: 'go', meaningCN: '去', candidate: candidate);

void main() {
  test('三色阶梯：候选蓝优先，其余按资产状态分在学/已掌握', () {
    expect(
      listeningChunkTone(_chunk(candidate: true), const {}),
      ListeningChunkTone.candidate,
    );
    expect(
      listeningChunkTone(
          _chunk(candidate: true), {'c01': ChunkAssetState.mastered}),
      ListeningChunkTone.candidate,
    );
    for (final state in [
      ChunkAssetState.learning,
      ChunkAssetState.consolidating,
      ChunkAssetState.consolidated,
      ChunkAssetState.longTerm,
      ChunkAssetState.relearning,
    ]) {
      expect(
        listeningChunkTone(_chunk(), {'c01': state}),
        ListeningChunkTone.learning,
        reason: '${state.name} 应归入琥珀在学',
      );
    }
    expect(
      listeningChunkTone(_chunk(), {'c01': ChunkAssetState.mastered}),
      ListeningChunkTone.mastered,
    );
  });

  test('未知 id 不渲染任何强调', () {
    expect(
      listeningChunkTone(_chunk(id: 'unknown'), const {}),
      ListeningChunkTone.none,
    );
  });
}

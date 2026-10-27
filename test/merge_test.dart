import 'package:chunkspoke_web/data/merge.dart';
import 'package:chunkspoke_web/data/protocol.dart';
import 'package:chunkspoke_web/data/vocab.dart';
import 'package:chunkspoke_web/storage/records.dart';
import 'package:flutter_test/flutter_test.dart';

const int _now = 1730000000000;

DataPackage _incoming({
  List<ChunkExchange> chunks = const [],
  List<EventRecord> events = const [],
  Map<String, Object?> stats = const {},
  Map<String, Object?> settings = const {},
  Map<String, String> packs = const {'content': '1.2.0'},
}) =>
    DataPackage(
      origin: 'android',
      originVersion: '1.5.10',
      exportedAt: '2026-11-03T12:00:00+08:00',
      deviceTag: 'beef01',
      packs: packs,
      chunks: chunks,
      events: events,
      stats: stats,
      settings: settings,
    );

ChunkExchange _exchange({
  String id = 'get up',
  AssetState state = AssetState.consolidating,
  int reviewStage = 1,
  int updatedAt = _now,
  int streak = 2,
}) =>
    ChunkExchange(
      id: id,
      tier: 'T0',
      assetState: state,
      reviewStage: reviewStage,
      updatedAt: updatedAt,
      correctStreak: streak,
    );

ChunkRecord _local({
  int updatedAt = _now - 1000,
  int streak = 1,
  int l4 = 0,
  int l2 = -1,
  int score = 0,
}) =>
    ChunkRecord(
      id: 'get up',
      tier: 'T0',
      assetState: AssetState.consolidating,
      updatedAt: updatedAt,
      correctStreak: streak,
      l4SelfEval: l4,
      l2OneTry: l2,
      lastScore: score,
    );

void main() {
  test('LWW：本机更新则跳过，入站更新则覆盖', () {
    final newerLocal = mergePackage(
      incoming: _incoming(chunks: [_exchange(updatedAt: _now - 5000)]),
      localChunks: {'get up': _local()},
      knownChunkIds: {'get up'},
    );
    expect(newerLocal.report.skipped, 1);
    expect(newerLocal.chunks['get up']!.updatedAt, _now - 1000);

    final newerIncoming = mergePackage(
      incoming: _incoming(chunks: [_exchange(updatedAt: _now)]),
      localChunks: {'get up': _local()},
      knownChunkIds: {'get up'},
    );
    expect(newerIncoming.report.updated, 1);
    expect(newerIncoming.chunks['get up']!.updatedAt, _now);
  });

  test('updated_at 相等时保留本机（导入方不覆盖）', () {
    final outcome = mergePackage(
      incoming: _incoming(chunks: [_exchange(updatedAt: _now - 1000)]),
      localChunks: {'get up': _local()},
      knownChunkIds: {'get up'},
    );
    expect(outcome.report.skipped, 1);
  });

  test('mastered 派生补齐：l4_self_eval=1 且 l2_one_try=1', () {
    final outcome = mergePackage(
      incoming: _incoming(chunks: [_exchange(state: AssetState.mastered, reviewStage: 4)]),
      localChunks: {},
      knownChunkIds: {'get up'},
    );
    final row = outcome.chunks['get up']!;
    expect(row.l4SelfEval, 1);
    expect(row.l2OneTry, 1);
    expect(outcome.report.added, 1);
  });

  test('review_stage==4 也触发派生补齐（不看 asset_state）', () {
    final outcome = mergePackage(
      incoming: _incoming(chunks: [_exchange(reviewStage: 4)]),
      localChunks: {},
      knownChunkIds: {'get up'},
    );
    expect(outcome.chunks['get up']!.l4SelfEval, 1);
    expect(outcome.chunks['get up']!.l2OneTry, 1);
  });

  test('本机痕迹永不被打回：last_score / l4_self_eval 保留', () {
    final outcome = mergePackage(
      incoming: _incoming(chunks: [_exchange(updatedAt: _now)]),
      localChunks: {'get up': _local(l4: 1, l2: 1, score: 88)},
      knownChunkIds: {'get up'},
    );
    final row = outcome.chunks['get up']!;
    expect(row.lastScore, 88);
    expect(row.l4SelfEval, 1);
    expect(row.l2OneTry, 1);
  });

  test('correct_streak 只增不减', () {
    final outcome = mergePackage(
      incoming: _incoming(chunks: [_exchange(updatedAt: _now, streak: 2)]),
      localChunks: {'get up': _local(streak: 5)},
      knownChunkIds: {'get up'},
    );
    expect(outcome.chunks['get up']!.correctStreak, 5);
  });

  test('未知块保留为孤儿，不静默丢弃', () {
    final outcome = mergePackage(
      incoming: _incoming(chunks: [_exchange(id: 'ghost chunk')]),
      localChunks: {},
      knownChunkIds: {'get up'},
    );
    expect(outcome.chunks['ghost chunk']!.orphan, isTrue);
    expect(outcome.report.orphan, 1);
    expect(outcome.report.added, 0);
    final exported = exportChunks(outcome.chunks.values);
    expect(exported.map((c) => c.id), contains('ghost chunk'));
  });

  test('events 按 event_id 去重', () {
    final outcome = mergePackage(
      incoming: _incoming(
        events: const [
          EventRecord(eventId: 'e1', at: 1, name: 'x'),
          EventRecord(eventId: 'e2', at: 2, name: 'x'),
        ],
      ),
      localChunks: {},
      knownChunkIds: {},
      localEvents: const [EventRecord(eventId: 'e1', at: 1, name: 'x')],
    );
    expect(outcome.events.length, 2);
    expect(outcome.events.where((e) => e.eventId == 'e1').length, 1);
  });

  test('events 超出 500 条按 at 保留最新', () {
    final local = [
      for (var i = 0; i < 500; i++) EventRecord(eventId: 'e$i', at: i, name: 'x'),
    ];
    final outcome = mergePackage(
      incoming: _incoming(
        events: const [EventRecord(eventId: 'new', at: 1000, name: 'x')],
      ),
      localChunks: {},
      knownChunkIds: {},
      localEvents: local,
    );
    expect(outcome.events.length, 500);
    expect(outcome.events.first.eventId, 'e1');
    expect(outcome.events.last.eventId, 'new');
    expect(outcome.events.any((e) => e.eventId == 'e0'), isFalse);
  });

  test('stats / settings：null 与缺键不覆盖', () {
    final outcome = mergePackage(
      incoming: _incoming(stats: {'streak': null, 'daily_goal': 8}),
      localChunks: {},
      knownChunkIds: {},
      localStats: {'streak': 4, 'daily_goal': 5, 'reviewed_today': 2},
      localSettings: {'tts_enabled': true},
    );
    expect(outcome.stats['streak'], 4);
    expect(outcome.stats['daily_goal'], 8);
    expect(outcome.stats['reviewed_today'], 2);
    expect(outcome.settings['tts_enabled'], true);
  });

  test('内容包版本不一致只在报告里明示，不阻断导入', () {
    final outcome = mergePackage(
      incoming: _incoming(packs: {'content': '2.0.0'}),
      localChunks: {},
      knownChunkIds: {},
      localPacks: {'content': '1.2.0'},
    );
    expect(outcome.report.packsMismatch, isTrue);
  });

  test('未知块集合可与内容包比对', () {
    final pkg = _incoming(chunks: [_exchange(), _exchange(id: 'ghost')]);
    expect(unknownChunkIds(pkg, {'get up'}), {'ghost'});
  });
}

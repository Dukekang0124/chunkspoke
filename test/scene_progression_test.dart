import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/scene_progression.dart';

Level _level(String id, String theme, int count) => Level(
      id: id,
      theme: theme,
      sceneImage: '',
      chunks: List.generate(
        count,
        (i) => Chunk.fromJson({
          'id': '${id.toLowerCase()}$i',
          'text': '$id chunk $i',
          'type': 'content',
          'meaningCN': '',
        }),
      ),
    );

Set<String> _mastered(Level level, int count) =>
    level.chunks.take(count).map((c) => c.id).toSet();

void main() {
  final a = _level('A', 'Greetings', 12);
  final b = _level('B', 'Asking for things', 25);
  final c = _level('C', 'Coffee & Cafe', 25);
  final levels = [a, b, c];

  group('B4 场景推进状态机（complete → unlock → map → enter）', () {
    test('通关打招呼（12/12）→ 解锁判定 → 地图可进入索取东西', () {
      final keys = _mastered(a, 12);

      final next = nextSceneState(levels, a.id, keys);
      expect(next, isNotNull);
      expect(next!.level.id, b.id);
      expect(next.unlocked, isTrue);
      expect(next.missing, 0);

      // 地图渲染读同一判定；点击进入解析出真实场景。
      expect(isSceneUnlocked(levels, 1, keys), isTrue);
      expect(enterableScene(levels, 1, keys)?.id, b.id);
      expect(progressionTarget(levels, keys)?.id, b.id);
    });

    test('80% 边界：9/12 锁定，10/12 解锁（索取东西）', () {
      final nine = _mastered(a, 9);
      expect(isSceneUnlocked(levels, 1, nine), isFalse);
      expect(missingForUnlock(a, nine), 1);
      expect(enterableScene(levels, 1, nine), isNull);

      final ten = _mastered(a, 10);
      expect(isSceneUnlocked(levels, 1, ten), isTrue);
      expect(missingForUnlock(a, ten), 0);
      expect(enterableScene(levels, 1, ten)?.id, b.id);
    });

    test('半途退出/跳过（9/12）时完成页不得宣称解锁', () {
      final nine = _mastered(a, 9);
      final next = nextSceneState(levels, a.id, nine);
      expect(next!.unlocked, isFalse);
      expect(next.missing, 1);
    });

    test('主推进不被补练抢占：A 10/12 已解锁 B → 继续学习目标是 B', () {
      final ten = _mastered(a, 10);
      expect(masteredInLevel(a, ten), 10); // A 仍有未掌握块（补练对象）
      expect(progressionTarget(levels, ten)?.id, b.id);
    });

    test('重复通关/跨场景不丢解锁：A 12/12 → B 20/25 → C 解锁', () {
      final keys = <String>{..._mastered(a, 12), ..._mastered(b, 20)};
      expect(isSceneUnlocked(levels, 1, keys), isTrue);
      expect(isSceneUnlocked(levels, 2, keys), isTrue);
      expect(progressionTarget(levels, keys)?.id, c.id);
      // 再次计算仍稳定（重复通关不改变判定）。
      expect(nextSceneState(levels, a.id, keys)!.level.id, b.id);
      expect(progressionTarget(levels, keys)?.id, c.id);
    });

    test('最后一关全掌握 → 无下一场景，主 CTA 收口', () {
      final keys = <String>{
        ..._mastered(a, 12),
        ..._mastered(b, 25),
        ..._mastered(c, 25),
      };
      expect(nextSceneState(levels, c.id, keys), isNull);
      expect(progressionTarget(levels, keys), isNull);
    });
  });
}

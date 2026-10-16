import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';

void main() {
  late ContentPack pack;
  setUpAll(() async {
    final str = await File('assets/content_pack.json').readAsString();
    pack = ContentPack.fromJson(jsonDecode(str) as Map<String, dynamic>);
  });

  group('词块拼装体系 · 首场景内容', () {
    test('首场景(A) 含 12 词块 / 14 目标句', () {
      final lvl = pack.levels.firstWhere((l) => l.id == 'A');
      expect(lvl.chunks.length, 12);
      expect(lvl.sentences.length, 14);
    });

    test('每个目标句的 chunkIds 都存在且顺序展开正确', () {
      final lvl = pack.levels.firstWhere((l) => l.id == 'A');
      final byId = {for (final c in lvl.chunks) c.id: c};
      for (final s in lvl.sentences) {
        for (final id in s.chunkIds) {
          expect(byId.containsKey(id), isTrue,
              reason: '句 ${s.id} 引用未知词块 $id');
        }
        final texts = s.orderedChunkTexts(byId);
        expect(texts.length, s.chunkIds.length);
        expect(s.text, startsWith(texts.first));
      }
    });

    test('每个词块至少出现在 1 个目标句中（块拼句有靶句）', () {
      final lvl = pack.levels.firstWhere((l) => l.id == 'A');
      final used = <String>{};
      for (final s in lvl.sentences) used.addAll(s.chunkIds);
      for (final c in lvl.chunks) {
        expect(used.contains(c.id), isTrue, reason: '词块 ${c.id} 无靶句');
      }
    });

    test('缺省 sentence 的 Chunk 回退为自身文本', () {
      final lvl = pack.levels.firstWhere((l) => l.id == 'A');
      final c = lvl.chunks.first;
      expect(c.sentence.text, c.text);
    });
  });

  group('拼句环节状态机 · assemblyCorrect', () {
    test('顺序一致才通过', () {
      expect(assemblyCorrect(['a', 'b'], ['a', 'b']), isTrue);
      expect(assemblyCorrect(['b', 'a'], ['a', 'b']), isFalse); // 顺序错
      expect(assemblyCorrect(['a', null], ['a', 'b']), isFalse); // 未填满
      expect(assemblyCorrect(['a'], ['a', 'b']), isFalse); // 长度不一
    });
  });
}

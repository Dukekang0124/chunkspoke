import 'package:chunkspoke_flutter/services/clip_linkage.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/user_package.dart';
import 'package:chunkspoke_flutter/services/user_package_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

/// 词块联动 · 派生归档 / 阈值 / 播单的钉子。
///
/// 口径红线：归档是**派生**的，不落库；阈值只存一个数字；官方读点零影响。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  UserPackageRecord pkg(String name, List<String> fronts) => UserPackageRecord(
        moduleKey: userModuleKey(name),
        moduleName: name,
        importedAt: 1,
        entries: [
          for (final (i, f) in fronts.indexed)
            UserChunkEntry(
              row: i + 1,
              front: f,
              back: '',
              moduleName: name,
            ),
        ],
      );

  group('派生归档', () {
    test('只认句子：单词条目、中文、网址不参与', () {
      final a = buildClipArchive([
        pkg('本一', [
          'plate',
          'I look forward to it.',
          '今天天气很好，我们去公园吧。',
          'https://example.com/a',
        ]),
      ]);
      expect(a.chunkCount, 1);
      expect(a.sentenceCount, 1);
      expect(a.chunks.first.text, 'look forward to');
      expect(a.sentences.first.text, 'I look forward to it.');
    });

    test('同一个词块跨句合并，上下文按首次出现排序', () {
      final a = buildClipArchive([
        pkg('本一', [
          'I look forward to it.',
          'We look forward to hearing from you.',
        ]),
      ]);
      final c = a.chunks.firstWhere((x) => x.key == 'look forward to');
      expect(c.count, 2);
      expect(c.sentences.first.text, 'I look forward to it.');
      expect(c.contextSentence, 'I look forward to it.');
    });

    test('同一句话在两个本子里只算一次（大小写/标点归一）', () {
      final a = buildClipArchive([
        pkg('本一', ['I look forward to it.']),
        pkg('本二', ['i LOOK forward to it']),
      ]);
      expect(a.sentenceCount, 1);
      expect(a.chunks.firstWhere((c) => c.key == 'look forward to').count, 1);
    });

    test('认过但没有可学词块的句子单独计数，不冒充已收录', () {
      final a = buildClipArchive([
        pkg('本一', ['The cat sat on the mat.', 'I look forward to it.']),
      ]);
      expect(a.sentenceCount, 1);
      expect(a.unmatchedSentences, 1);
      expect(a.totalScanned, 2);
    });

    test('删包后归档自动少掉（派生，无孤儿）', () {
      final all = [
        pkg('本一', ['I look forward to it.']),
        pkg('本二', ['Take care of yourself.']),
      ];
      expect(buildClipArchive(all).sentenceCount, 2);
      expect(buildClipArchive([all.first]).sentenceCount, 1);
      expect(buildClipArchive(const []).isEmpty, isTrue);
    });

    test('词块按出现句数降序稳定排序', () {
      final a = buildClipArchive([
        pkg('本一', [
          'I look forward to it.',
          'We look forward to it.',
          'Take care of yourself.',
        ]),
      ]);
      expect(a.chunks.first.key, 'look forward to');
      expect(a.chunks.first.count, 2);
      expect(a.chunks.last.key, 'take care of');
    });

    test('类型计数覆盖四类且总数=词块数', () {
      final a = buildClipArchive([
        pkg('本一', [
          'I look forward to it.',
          'We met in the morning.',
          'Make sure you lock the door.',
          'He was able to solve it.',
        ]),
      ]);
      final k = a.kindCounts;
      expect(k.values.reduce((x, y) => x + y), a.chunkCount);
      expect(k.keys.toList(), ['动词短语', '固定搭配', '介词短语', '常用句型']);
    });
  });

  group('阈值', () {
    test('默认 10，只接受 5/10/20/0，脏值回落默认', () async {
      final db = AppDatabase(path: inMemoryDatabasePath);
      expect(await loadClipThreshold(db), 10);
      await db.setKv(kClipThresholdKvKey, '7');
      expect(await loadClipThreshold(db), 10);
      expect(await saveClipThreshold(db, 20), 20);
      expect(await loadClipThreshold(db), 20);
      expect(await saveClipThreshold(db, 0), 0);
      expect(await loadClipThreshold(db), 0);
    });

    test('9 句未到 / 10 句到阈值 / 关闭时不推', () {
      List<String> sents(int n) =>
          [for (var i = 0; i < n; i++) 'I look forward to number $i.'];
      final nine = ClipLinkageState(
          archive: buildClipArchive([pkg('本一', sents(9))]), threshold: 10);
      expect(nine.sentenceCount, 9);
      expect(nine.ready, isFalse);
      expect(nine.remaining, 1);
      expect(nine.progress, closeTo(0.9, 1e-9));

      final ten = ClipLinkageState(
          archive: buildClipArchive([pkg('本一', sents(10))]), threshold: 10);
      expect(ten.ready, isTrue);
      expect(ten.remaining, 0);

      final off = ClipLinkageState(
          archive: buildClipArchive([pkg('本一', sents(10))]), threshold: 0);
      expect(off.enabled, isFalse);
      expect(off.ready, isFalse);
      expect(off.hasSilentArchive, isTrue);
    });

    test('阈值走库：save → loadClipLinkage 读到同一数字', () async {
      final db = AppDatabase(path: inMemoryDatabasePath);
      await saveClipThreshold(db, 5);
      final st = await loadClipLinkage(db);
      expect(st.threshold, 5);
      expect(st.archive.isEmpty, isTrue);
    });

    test('归档确实从库里的包档案派生（写包 → 读联动）', () async {
      final db = AppDatabase(path: inMemoryDatabasePath);
      final store = UserPackageStore(db);
      final v = parseAndValidateUserPackage(
          'front,module_name\n'
          '"I look forward to it.",本一\n'
          '"Take care of yourself.",本一\n');
      expect(v.ok, isTrue, reason: v.issues.join(' | '));
      final r = await store.importValidation(v, allowed: true);
      expect(r.ok, isTrue, reason: r.note);

      final st = await loadClipLinkage(db);
      expect(st.archive.sentenceCount, 2);
      expect(st.archive.chunkCount, 2);

      await store.removePackage(userModuleKey('本一'));
      final after = await loadClipLinkage(db);
      expect(after.archive.isEmpty, isTrue);
    });
  });

  group('播单', () {
    test('每个词块念两遍 + 原句一遍，顺序稳定', () {
      final a = buildClipArchive([
        pkg('本一', ['I look forward to it.', 'Take care of yourself.']),
      ]);
      final q = buildClipListeningQueue(a);
      expect(q.length, 6);
      expect(q[0].kind, 'chunk');
      expect(q[0].speak, q[1].speak);
      expect(q[2].kind, 'sentence');
      expect(q[2].speak, q.firstWhere((x) => x.kind == 'chunk').sub);
    });

    test('超过上限只带前 N 个词块，避免一次念太久', () {
      final fronts = [
        for (var i = 0; i < 80; i++) 'I look forward to item $i.',
        for (var i = 0; i < 80; i++) 'I take care of item $i.',
      ];
      final a = buildClipArchive([pkg('本一', fronts)]);
      expect(a.chunkCount, 2);
      final q = buildClipListeningQueue(a, maxChunks: 1);
      expect(q.where((x) => x.kind == 'chunk').length, 2); // 1 个词块 × 2 遍
    });
  });
}

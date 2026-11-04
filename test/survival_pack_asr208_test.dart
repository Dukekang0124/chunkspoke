import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/models/listening_article.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/license_code.dart';
import 'package:chunkspoke_flutter/services/license_state.dart';
import 'package:chunkspoke_flutter/services/scene_progression.dart';

/// ASR-208 · L0 生存先行包与解锁/免费口径回归。
///
/// 钉死的四件事（任一条被改坏都直接红）：
///  1. S0 是链首、30 块、可选模块（optional=true）、stage=L0/cefr=A1；
///  2. 新用户第一站 = S0；**老用户不被 S0 卡住**（A 的前置跳过可选模块）；
///  3. 免费区 = 生存 S0 + A–F（7 关 = 167 块），G 起仍要 PRO/老用户；
///  4. 9 篇慢速新篇全部符合 A1 档标尺，且 ≥80% 标注块出自 S0（实为 100%）。
void main() {
  final pack = ContentPack.fromJson(
      jsonDecode(File('assets/content_pack.json').readAsStringSync())
          as Map<String, dynamic>);
  final listen = ListeningPack.fromJson(
      jsonDecode(File('assets/listening_articles.json').readAsStringSync())
          as Map<String, dynamic>);
  final levels = pack.levels;
  final s0 = levels.first;
  Set<String> ids(Level l) => l.chunks.map((c) => c.id).toSet();

  test('S0 链首与规格：30 块 / 可选 / L0 / A1', () {
    expect(s0.id, 'S0');
    expect(s0.theme, 'Survival First');
    expect(s0.optional, isTrue, reason: '可选模块：不进解锁链');
    expect(s0.chunks.length, 30);
    expect(s0.stage, 'L0');
    expect(s0.cefr, 'A1');
    expect(s0.chunks.every((c) => kCefrKeys.contains(c.cefr)), isTrue,
        reason: '新块同样要有 CEFR 档（与 487 块同标准）');
    expect(s0.chunks.every((c) => c.sources.isNotEmpty), isTrue);
    expect(s0.requiresChunks, isEmpty);
  });

  test('解锁链：A 的前置跳过可选模块，老用户不受扰', () {
    final aKeys = ids(levels[1]);
    expect(levels[1].id, 'A');
    // 零基础：S0 与 A 都可进（A 没有非可选前置）。
    expect(isSceneUnlocked(levels, 0, {}), isTrue);
    expect(isSceneUnlocked(levels, 1, {}), isTrue,
        reason: 'A 不得被「先学完 S0 80%」卡住 —— 这是解锁类 P0');
    // 新用户第一站 = S0。
    expect(progressionTarget(levels, {})!.id, 'S0');
    // 只要有任何进度，就不再把 S0 当第一站（不催老用户）。
    final oldUser = {aKeys.first};
    expect(progressionTarget(levels, oldUser)!.id, 'A',
        reason: '老用户第一站仍是 A，不被生存模块截胡');
    // A 学到 80% 才开 B —— 链长没因插入 S0 而错位。
    final target = sceneUnlockTarget(levels[1]);
    expect(isSceneUnlocked(levels, 2, oldUser), isFalse);
    expect(isSceneUnlocked(levels, 2, aKeys.take(target).toSet()), isTrue);
  });

  test('免费口径：生存 S0 + A–F = 7 关 167 块，G 起需权益', () {
    expect(kFreeLevelCount, 7);
    final freeChunks =
        levels.take(kFreeLevelCount).fold(0, (s, l) => s + l.chunks.length);
    expect(freeChunks, 167, reason: 'ASR-208 §一.4：137 → 167');
    expect(levels.length, 21, reason: '20 关 + 生存 S0');
    final state = LicenseState(
        db: AppDatabase(path: ':memory:'),
        legacyEligible: false,
        secrets: ['0' * 64]);
    expect(state.allowsLevel(0), isTrue);
    expect(state.allowsLevel(6), isTrue);
    expect(state.allowsLevel(7), isFalse, reason: 'G 关（index 7）仍需码/老用户');
  });

  test('9 篇慢速新篇：A1 档标尺 + 80% 出自 S0（构造保证）', () {
    final fresh = listen.articles
        .where((a) => a.moduleIds.contains('S0'))
        .toList(growable: false);
    expect(fresh.length, 9);
    for (final a in fresh) {
      expect(a.kind, 'slow_dialog');
      expect(a.levelRaw, 'A1');
      expect(a.baseRate, 0.75, reason: '慢速走合成级速率，不用播放端拉伸');
      expect(a.moduleIds, ['S0']);
      final annotated = <String>{
        for (final s in a.sentences)
          for (final c in s.chunks) c.id
      };
      expect(annotated.length, inInclusiveRange(1, 6),
          reason: '${a.id} 标注块数越出 A1 档 1..6');
      expect(a.wordCount, inInclusiveRange(100, 180),
          reason: '${a.id} 总词数 ${a.wordCount} 越出 A1 档 100..180');
      expect(a.avgWordsPerSentence, lessThanOrEqualTo(6.0));
      final s0Ids = ids(s0);
      final inS0 = annotated.where(s0Ids.contains).length;
      expect(inS0 / annotated.length, greaterThanOrEqualTo(0.80),
          reason: '${a.id} 只有 $inS0/${annotated.length} 出自 S0');
    }
  });

  test('旧 24 篇保持泛听：不声明 moduleIds（ASR-208 §一.1 裁定 B）', () {
    final old = listen.articles.where((a) => !a.moduleIds.contains('S0'));
    expect(old.length, 24);
    expect(old.every((a) => a.moduleIds.isEmpty), isTrue,
        reason: '泛听篇不硬塞 moduleIds，80% 规则由新篇承担');
    expect(listen.articles.length, 33);
  });

  /// 指令只写「30 词块」，实装的六步与句子闯关都要目标句撑：
  /// 没句 → 块拼句退化成单块复读、句子闯关被 `sentenceTotal > 0` 静默跳过。
  /// 这一条把「L0 也有完整靶句」钉死，后续 L1/L2 新模块同理。
  test('S0 靶句：30 句 · 每块至少 1 句 · chunkIds 全在篇内 · 块文本逐字在句中', () {
    expect(s0.sentences.length, 30, reason: 'L0 句子闯关总数 = 30（空则整关被跳过）');
    final s0Ids = ids(s0);
    final byId = {for (final c in s0.chunks) c.id: c};
    final used = <String>{};
    for (final st in s0.sentences) {
      expect(st.chunkIds, isNotEmpty, reason: '${st.id} 无成分块');
      for (final id in st.chunkIds) {
        expect(s0Ids.contains(id), isTrue, reason: '${st.id} 引用篇外块 $id');
        expect(st.text.toLowerCase(), contains(byId[id]!.text.toLowerCase()),
            reason: '${st.id} 未逐字包含「${byId[id]!.text}」');
        used.add(id);
      }
      expect(st.meaningCN.trim(), isNotEmpty, reason: '${st.id} 缺中文提示');
    }
    for (final c in s0.chunks) {
      expect(used.contains(c.id), isTrue, reason: '词块 ${c.id}（${c.text}）无靶句');
    }
  });

  test('慢速新句是成句，不是补齐串（生成器指纹回归）', () {
    // 补齐生成器的产物长相：`Hello there, please, now.` —— 连续 ≥2 个语气词挂在句尾。
    final filler = RegExp(
        r'(?:,\s*(?:please|now|today|sorry|friend|thanks)\b){2,}', caseSensitive: false);
    final fresh = listen.articles.where((a) => a.moduleIds.contains('S0'));
    expect(fresh, isNotEmpty);
    for (final a in fresh) {
      for (final s in a.sentences) {
        expect(filler.hasMatch(s.text), isFalse,
            reason: '${a.id}/${s.id} 出现补齐串：「${s.text}」');
        expect(s.meaningCN.trim(), isNotEmpty, reason: '${a.id}/${s.id} 缺中文');
      }
    }
  });

  test('内容校验器 0 错（引用完整性 + 收听档）', () {
    expect(validateContentPackReferences(pack), isEmpty);
    expect(validateListeningPack(listen, pack), isEmpty);
  });
}

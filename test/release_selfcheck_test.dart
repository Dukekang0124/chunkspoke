import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/services/chunk_asset.dart';
import 'package:chunkspoke_flutter/services/database.dart';
import 'package:chunkspoke_flutter/services/learning_flow.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/progress_integrity.dart';
import 'package:chunkspoke_flutter/services/self_check.dart';
import 'package:chunkspoke_flutter/services/state_machine.dart';

/// ASR-205 三闸②：发版前全模块扫描（进度四项）零红并归档。
///
/// 这里用「真实内容包 + 进程内 SQLite」模拟一个 1.7.2 存量库：
/// 每个模块按序掌握 55%–95% 的块，再把断点写回一个与台账不同位的旧索引
/// （1.7.2 的复习完成不回写快照即会留下这种分布）。
/// 期望：扫描先看到红名单 → healAll 后红 0 → 归档到 release/selfcheck/。
///
/// 资源完整性与更新链路不在本进程内检查，由真机「设置 → 诊断」覆盖；
/// 归档里如实标注扫描口径，避免把「没查」写成「通过」。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('全模块扫描：存量陈旧锚点先红，healAll 后零红并归档', () async {
    final raw = File('assets/content_pack.json').readAsStringSync();
    final content =
        ContentPack.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    final levels = [for (final l in content.levels) if (l.chunks.isNotEmpty) l];
    expect(levels, isNotEmpty);

    final pub = RegExp(r'^version:\s*([^+\s]+)\+(\d+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(pub, isNotNull, reason: 'pubspec.yaml 缺少 version: x.y.z+N');
    final versionName = pub!.group(1)!;
    final versionCode = int.parse(pub.group(2)!);

    final dir = await Directory.systemTemp.createTemp('selfcheck_scan');
    final db = AppDatabase(path: '${dir.path}/scan.db');
    final p = ProgressService(db: db);
    p.setChunkTiers(content);
    await p.init();

    final rnd = Random(20261103);
    var seededChunks = 0;
    for (final lv in levels) {
      final keys = [for (final c in lv.chunks) c.id];
      // 模拟存量：按序掌握 55%–95%，分数/一次过留痕随机。
      final n = (keys.length * (55 + rnd.nextInt(41)) ~/ 100)
          .clamp(1, keys.length);
      for (var i = 0; i < n; i++) {
        await db.upsertChunk(ChunkRow(
          chunkKey: keys[i],
          level: ChunkLevel.mastered,
          dueDate: 0,
          failCount: 0,
          lastScore: 60 + rnd.nextInt(41),
          l2OneTry: rnd.nextInt(5) == 0 ? 0 : 1,
          assetState: ChunkAssetState.mastered,
          firstLearnedAt: 1,
        ));
        seededChunks++;
      }
      // 1.7.2 遗留：快照停在一个旧索引（这里取第 10 块，越界则取首块）。
      final stale = min(10, keys.length - 1);
      if (n > 0 && stale != (n < keys.length ? n : keys.length)) {
        await p.setLearnResume(
            lv.id,
            LearnResume(
              chunkIndex: stale,
              chunkId: keys[stale],
              phase: 0,
              stars: StarBoard.empty,
              savedAt: 1,
            ).encode());
      }
    }

    final before = await ProgressIntegrity.auditAll(p, content);
    final redBefore = ProgressIntegrity.reds(before);
    expect(redBefore, isNotEmpty,
        reason: '存量样本必须复现「台账推进、锚点陈旧」的红名单');

    final healed = await ProgressIntegrity.healAll(p, content, before);
    final after = await ProgressIntegrity.auditAll(p, content);
    expect(ProgressIntegrity.reds(after), isEmpty, reason: 'healAll 后必须零红');
    expect(after.every((a) => a.consistent), isTrue);
    expect(healed.every((a) => a.consistent), isTrue);
    for (final a in after) {
      // 不变量：锚点 = 首个未完成块；整关完成则快照清空。
      // 从未写过断点的模块（没有可续的位置）视作与台账同位。
      expect(a.snapshotIndex < 0 || a.snapshotIndex == a.ledgerNextIndex || a.complete,
          isTrue,
          reason: '${a.theme}：锚点 ${a.snapshotIndex} != 首个未完成 ${a.ledgerNextIndex}');
    }

    final report = SelfCheckReport(
      at: DateTime.now(),
      audits: after,
      localVersion: versionName,
      localVersionCode: versionCode + 2000, // arm64 主发布槽位
      sections: [
        SelfCheck.progressSection(after),
        CheckSection('扫描口径', [
          CheckRow('数据来源',
              '进程内 SQLite + 真实内容包（${levels.length} 模块 / $seededChunks 块已掌握）',
              CheckState.pass),
          CheckRow('修复路径', '模拟 1.7.2 陈旧锚点：红 ${redBefore.length} → healAll → 红 0',
              CheckState.pass),
          const CheckRow('覆盖范围',
              '仅进度四项（台账/锚点/环/分数）；资源与更新链路由真机「设置 → 诊断」覆盖',
              CheckState.warn),
        ]),
      ],
    );

    expect(report.reds, isEmpty);
    expect(report.needsAction, isFalse,
        reason: '归档必须 needsAction=false（零红）才允许 bump 清单');

    if (Platform.environment['CS_SELFCHECK_ARCHIVE'] == '1') {
      final out = Directory('release/selfcheck');
      await out.create(recursive: true);
      final f = File('${out.path}/selfcheck-$versionName.json')
        ..writeAsStringSync(report.encode());
      stdout.writeln('selfcheck archived: ${f.path}');
    }
  });
}

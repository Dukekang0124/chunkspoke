import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/content_pack.dart';
import 'chunk_asset.dart';
import 'loaders.dart';

/// 导出头部的版本号：发版时与 pubspec.yaml 同 bump。
/// library_export_test 里有一条用例把它和 pubspec 对齐，漏改会让回归变红。
const String kExportAppVersion = '1.5.5';

/// 学习数据导出（波 2 · 模块 D）：只生成本机文本，不上报、不联网。
/// 内容：资产分组、六步漏斗、复习保持率、节奏指标。
class LearningExport {
  final String text;
  final String filename;
  const LearningExport({required this.text, required this.filename});
}

Future<LearningExport> buildLearningExport({
  required ProgressService progress,
  required ContentPack content,
  DateTime? now,
}) async {
  final at = now ?? progress.now;
  final contentIds = <String>{
    for (final lv in content.levels)
      for (final c in lv.chunks) c.id,
  };
  final rows = (await progress.chunkStore.allRows())
      .where((r) => contentIds.contains(r.chunkKey))
      .toList();
  final stateCount = <ChunkAssetState, int>{
    for (final s in ChunkAssetState.values) s: 0,
  };
  for (final r in rows) {
    stateCount[r.assetState] = (stateCount[r.assetState] ?? 0) + 1;
  }
  // 从未开始学的块没有行，仍属于「新学」资产，不能漏计。
  stateCount[ChunkAssetState.learning] =
      (stateCount[ChunkAssetState.learning] ?? 0) +
          (contentIds.length - rows.length);
  final learned =
      rows.where((r) => r.assetState != ChunkAssetState.learning).length;

  final all = await progress.chunkStore.sessionOutcomeCounts();
  final learn = await progress.chunkStore.sessionOutcomeCounts(review: false);
  final review = await progress.chunkStore.sessionOutcomeCounts(review: true);

  int n(Map<String, int> m, String k) => m[k] ?? 0;
  final reviewPass = n(review, 'speakSuccess');
  final reviewFail = n(review, 'speakFail');
  final reviewSkip = n(review, 'deferReview');
  final reviewDone = reviewPass + reviewFail;
  final retention = reviewDone == 0
      ? '—'
      : '${(reviewPass / reviewDone * 100).toStringAsFixed(1)}%';

  final sandbox = progress.sandbox.stats;
  // 本周起点（周一 00:00）：浸泡层按「实际播放秒数」独立计量，不进会话轴。
  final weekStart = DateTime(at.year, at.month, at.day)
      .subtract(Duration(days: at.weekday - 1));
  final listenSeconds = progress.listening.secondsSince(weekStart);
  final listenMinutes = (listenSeconds / 60).round();
  final listenCompleted =
      progress.listening.completedSince(weekStart.millisecondsSinceEpoch);
  final listen = progress.listening.stats;
  final listenCollected = listen.collected;
  final listenSixStarted = listen.sixStarted;
  final listenConverted = listen.converted;
  final listenWishes = listen.wishes;
  final listenPromotion = listenCollected == 0
      ? '—'
      : '${(listenConverted / listenCollected * 100).toStringAsFixed(1)}%';
  // 句级轻跟读：只统计 attempt 事件（浸泡层不产资产，不进会话轴）。
  var shadowAttempts = 0, shadowPass = 0;
  // 讲解版（指令 S+ §三）：模式切换 / 讲解段完听与跳过，全部只读事件与计数。
  var modeToExplained = 0, modeToOriginal = 0;
  var explStart = 0, explComplete = 0, explSkip = 0;
  for (final e in progress.analyticsEvents) {
    final n = e['n'];
    if (n == 'listen_shadow_attempt') {
      shadowAttempts++;
      final p = e['p'];
      if (p is Map && p['passed'] == true) shadowPass++;
    } else if (n == 'listen_mode_switch') {
      final p = e['p'];
      if (p is Map && p['mode'] == 'explained') {
        modeToExplained++;
      } else {
        modeToOriginal++;
      }
    } else if (n == 'listen_expl_start') {
      explStart++;
    } else if (n == 'listen_expl_complete') {
      explComplete++;
    } else if (n == 'listen_expl_skip') {
      explSkip++;
    }
  }
  final explCompleteRate = explStart == 0
      ? '—'
      : '${(explComplete / explStart * 100).toStringAsFixed(1)}%';
  final explSkipRate = explStart == 0
      ? '—'
      : '${(explSkip / explStart * 100).toStringAsFixed(1)}%';
  final modeSeconds = progress.listening.modeSeconds;
  final originalSeconds = modeSeconds['o'] ?? 0;
  final explainedSeconds = modeSeconds['x'] ?? 0;
  final modeTotal = originalSeconds + explainedSeconds;
  final explainedShare = modeTotal == 0
      ? '—'
      : '${(explainedSeconds / modeTotal * 100).toStringAsFixed(1)}%';
  final b = StringBuffer()
    ..writeln('ChunkSpoke 学习数据导出')
    ..writeln('生成时间：${_dateTime(at)}')
    ..writeln('版本：$kExportAppVersion')
    ..writeln('说明：仅含聚合计数，不含录音、文本原文或账号信息；是否分享由你决定。')
    ..writeln()
    ..writeln('一、词块资产（资产轴）')
    ..writeln('新学 ${stateCount[ChunkAssetState.learning] ?? 0}'
        ' · 巩固中 ${stateCount[ChunkAssetState.consolidating] ?? 0}'
        ' · 已巩固 ${stateCount[ChunkAssetState.consolidated] ?? 0}'
        ' · 长期 ${stateCount[ChunkAssetState.longTerm] ?? 0}'
        ' · 已掌握 ${stateCount[ChunkAssetState.mastered] ?? 0}'
        ' · 需重修 ${stateCount[ChunkAssetState.relearning] ?? 0}')
    ..writeln('已学完合计：$learned / ${contentIds.length} 块')
    ..writeln()
    ..writeln('二、六步漏斗（累计完成次数）')
    ..writeln('听辨完成：${n(learn, 'assembleCorrect')}')
    ..writeln('影子跟读通过：${n(learn, 'dragCorrect')}')
    ..writeln('定向替换通过：${n(learn, 'accuracyPass')}')
    ..writeln('自由造句通过：${n(learn, 'speakSuccess')}')
    ..writeln('学习阶段跳过并存档：${n(learn, 'scheduleReview')}')
    ..writeln()
    ..writeln('三、复习保持率')
    ..writeln('复习通过：$reviewPass 次')
    ..writeln('复习未通过：$reviewFail 次')
    ..writeln('保持率：$retention（通过 /（通过+未通过））')
    ..writeln('跳过顺延：$reviewSkip 次')
    ..writeln()
    ..writeln('四、节奏')
    ..writeln('连续打卡：${progress.streak} 天')
    ..writeln('今日开口：${progress.todaySpoken} 句')
    ..writeln('平均相似度（最近 50 次开口）：'
        '${progress.firstPracticeDone ? progress.avgScore.round() : '—'}')
    ..writeln()
    ..writeln('五、浸泡（磨耳朵）')
    ..writeln('今日浸泡：${_minutesOf(progress.listening.todaySeconds)} 分钟')
    ..writeln('本周浸泡：$listenMinutes 分钟（实际播放秒数，暂停不计）')
    ..writeln('本周完听：$listenCompleted 篇')
    ..writeln('收词：$listenCollected 块（累计，按块去重）')
    ..writeln('收词后开始六步：$listenSixStarted 块')
    ..writeln('收词后完成六步：$listenConverted 块（推动率 $listenPromotion）')
    ..writeln('候选块想学：$listenWishes 条（文章 + 块文本，按篇去重；不建词块）')
    ..writeln('句级跟读：$shadowAttempts 次尝试 · 判定通过 $shadowPass 次'
        '（只记 attempt，不改词块状态）')
    ..writeln('模式切换：原版→讲解版 $modeToExplained 次 · '
        '讲解版→原版 $modeToOriginal 次（累计）')
    ..writeln('讲解段：开始 $explStart 段 · 完听 $explComplete 段 · '
        '跳过 $explSkip 段（完听率 $explCompleteRate · 跳过率 $explSkipRate）')
    ..writeln('两模式播放：原版 ${_minutesOf(originalSeconds)} 分钟 · '
        '讲解版 ${_minutesOf(explainedSeconds)} 分钟'
        '（讲解占比 $explainedShare，累计实际播放秒数）')
    ..writeln('说明：浸泡本身只计时长与完听，不产出学习资产；'
        '讲解版只换呈现内容（同引擎同音色现场合成），不改块状态；'
        '收词与立即复习是用户主动学习动作，走既有会话轴。')
    ..writeln()
    ..writeln('六、沙盒（自由造句）')
    ..writeln('沙盒访问：${sandbox.visits} 次')
    ..writeln('句子产出：${sandbox.sentences.length} 句（通过校验才入库）')
    ..writeln('串联使用：${sandbox.chainCount} 次（一句含 ≥2 个不同已掌握块）')
    ..writeln('搜索使用：${_rate(sandbox.searchUsed, sandbox.visits)}')
    ..writeln('筛选使用：${_rate(sandbox.filterUsed, sandbox.visits)}')
    ..writeln()
    ..writeln('七、事件总量（校验用）')
    ..writeln('会话事件合计：${all.values.fold<int>(0, (s, v) => s + v)} 条');

  final stamp = '${at.year}'
      '${at.month.toString().padLeft(2, '0')}'
      '${at.day.toString().padLeft(2, '0')}-'
      '${at.hour.toString().padLeft(2, '0')}'
      '${at.minute.toString().padLeft(2, '0')}';
  return LearningExport(
      text: b.toString(), filename: 'chunkspoke_learning_$stamp.txt');
}

Future<File> saveLearningExport(LearningExport export) async {
  final dir = await getApplicationDocumentsDirectory();
  final f = File('${dir.path}/${export.filename}');
  return f.writeAsString(export.text, flush: true);
}

String _rate(int used, int visits) => visits == 0
    ? '—（还没进过沙盒）'
    : '$used / $visits 次访问（${(used / visits * 100).toStringAsFixed(0)}%）';

String _dateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

/// 秒 → 分钟（四舍五入）；浸泡卡与导出共用同一换算口径。
int _minutesOf(num seconds) => (seconds / 60).round();

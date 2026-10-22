import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/content_pack.dart';
import 'chunk_asset.dart';
import 'loaders.dart';

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
  final learned = rows.where((r) => r.assetState != ChunkAssetState.learning).length;

  final all = await progress.chunkStore.sessionOutcomeCounts();
  final learn = await progress.chunkStore.sessionOutcomeCounts(review: false);
  final review = await progress.chunkStore.sessionOutcomeCounts(review: true);

  int n(Map<String, int> m, String k) => m[k] ?? 0;
  final reviewPass = n(review, 'speakSuccess');
  final reviewFail = n(review, 'speakFail');
  final reviewSkip = n(review, 'deferReview');
  final reviewDone = reviewPass + reviewFail;
  final retention =
      reviewDone == 0 ? '—' : '${(reviewPass / reviewDone * 100).toStringAsFixed(1)}%';

  final b = StringBuffer()
    ..writeln('ChunkSpoke 学习数据导出')
    ..writeln('生成时间：${_dateTime(at)}')
    ..writeln('版本：1.5.2')
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
    ..writeln('五、事件总量（校验用）')
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

String _dateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

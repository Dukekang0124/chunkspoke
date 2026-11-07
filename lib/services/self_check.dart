import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'audio_format.dart';
import 'progress_display.dart';
import 'progress_integrity.dart';
import 'update/update_service.dart';
import 'update/version_compare.dart';
import 'user_package.dart';
import 'user_package_store.dart';

/// ASR-203 自检（设置 → 诊断）的判定层。
///
/// 页面只做取数与渲染，所有「红/黄/绿」的判据集中在这里，
/// 这样发版前的全模块扫描与页面上看到的红名单是同一套口径。
enum CheckState { pass, warn, fail }

class CheckRow {
  const CheckRow(this.label, this.value, this.state);
  final String label;
  final String value;
  final CheckState state;

  Map<String, Object?> toJson() =>
      {'label': label, 'value': value, 'state': state.name};
}

class CheckSection {
  const CheckSection(this.title, this.rows);
  final String title;
  final List<CheckRow> rows;

  bool get hasFail => rows.any((r) => r.state == CheckState.fail);
  bool get hasWarn => rows.any((r) => r.state == CheckState.warn);

  Map<String, Object?> toJson() => {
        'title': title,
        'fail': hasFail,
        'warn': hasWarn,
        'rows': [for (final r in rows) r.toJson()],
      };
}

/// 自检总结果：四个区块 + 逐模块审计明细，可整份 JSON 归档。
class SelfCheckReport {
  SelfCheckReport({
    required this.at,
    required this.audits,
    required this.sections,
    required this.localVersion,
    required this.localVersionCode,
    this.orphans,
  });

  final DateTime at;
  final List<ModuleAudit> audits;
  final List<CheckSection> sections;
  final String localVersion;
  final int localVersionCode;

  /// ASR-211 修复 4：孤儿行扫描结果（迁移表裁定的数据源，随导出回传）。
  final OrphanScan? orphans;

  List<ModuleAudit> get reds => ProgressIntegrity.reds(audits);
  int get weakTraceCount => audits.where((a) => a.wrongChunkIds.isNotEmpty).length;

  /// 跳块模块数 / 待通过块总数（案三那类分歧的量化，进导出）。
  int get gapModuleCount => audits.where((a) => a.gapAhead).length;
  int get skippedChunkCount =>
      audits.fold(0, (n, a) => n + a.skippedChunkIds.length);

  /// 提示项 = 全页黄牌条目数（可选包未下载、无音频缓存、某模块留痕待补…）。
  int get hintCount => sections.fold(
      0, (n, s) => n + s.rows.where((r) => r.state == CheckState.warn).length);
  bool get allGreen => reds.isEmpty && weakTraceCount == 0 && !anyFail;
  bool get anyFail => sections.any((s) => s.hasFail);

  /// 「需要处理」的门槛：只有断点红名单或硬失败才算异常。
  /// 留痕待补（错块）与可选包未下载都是提示项，不该把整页判红。
  bool get needsAction => reds.isNotEmpty || anyFail;

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'localVersion': localVersion,
        'localVersionCode': localVersionCode,
        'allGreen': allGreen,
        'needsAction': needsAction,
        'hints': hintCount,
        'gapModules': gapModuleCount,
        'skippedChunks': skippedChunkCount,
        'orphans': orphans?.toJson(),
        'reds': [for (final a in reds) a.toJson()],
        'audits': [for (final a in audits) a.toJson()],
        'sections': [for (final s in sections) s.toJson()],
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class SelfCheck {
  /// 区块①：进度完整性。逐模块给出「台账 / 断点 / 环 / 分数」四项比对。
  ///
  /// 红名单判据：断点与台账不同位（陈旧快照）。
  /// 黄牌判据：已掌握但留痕不合格（错块），或整模块已掌握。
  ///
  /// ASR-211 修复 4：口径从「台账比台账」改成**台账比 UI 渲染值**——
  /// 每行同时打印 [LevelDisplay.anchorLine]（用户真正看到的那句）与台账两个数，
  /// 渲染值里没有台账那个计数就是红；跳块与孤儿行各出一行，进同一份导出。
  static CheckSection progressSection(List<ModuleAudit> audits,
      {OrphanScan? orphans}) {
    final rows = <CheckRow>[];
    if (audits.isEmpty) {
      return CheckSection('进度完整性', [
        const CheckRow('模块', '无已启用模块', CheckState.warn),
        if (orphans != null) ...orphanRows(orphans),
      ]);
    }
    var gapModules = 0;
    var skipped = 0;
    for (final a in audits) {
      final d = LevelDisplay.of(a);
      final resume = a.snapshotIndex < 0
          ? '无断点'
          : '断点第 ${a.snapshotIndex + 1} 块';
      final ring = '${(d.ring * 100).round()}%';
      final score = a.minMasteredScore < 0
          ? '无分数留痕'
          : '最低 ${a.minMasteredScore} / 均值 ${a.avgMasteredScore.toStringAsFixed(1)}';
      // 渲染值必须带上台账的「已掌握 N/M」（完成态文案是 N/N，同样命中）。
      final ledgerCounter = '${a.ledgerMastered}/${a.total}';
      final rendersLedger = d.anchorLine.contains(ledgerCounter) ||
          (a.complete && d.anchorLine.contains('${a.total}/${a.total}'));
      CheckState state;
      if (!a.consistent) {
        state = CheckState.fail;
      } else if (!rendersLedger) {
        state = CheckState.fail;
      } else if (d.gapAhead || a.wrongChunkIds.isNotEmpty) {
        state = CheckState.warn;
      } else {
        state = CheckState.pass;
      }
      if (d.gapAhead) {
        gapModules++;
        skipped += a.skippedChunkIds.length;
      }
      final detail = '${d.ledgerLine} · 渲染「${d.anchorLine}」 · $resume · '
          '环 $ring · $score';
      rows.add(CheckRow(a.theme, detail, state));
    }
    final reds = ProgressIntegrity.reds(audits).length;
    rows.add(CheckRow('汇总',
        '${audits.length} 个模块 · 红名单 $reds · 跳块模块 $gapModules · 待通过块 $skipped',
        reds == 0 ? CheckState.pass : CheckState.fail));
    if (gapModules > 0) {
      rows.add(CheckRow(
          '跳块清单',
          '$gapModules 个模块的缺口 ≠ 连续末端，共 $skipped 块待通过'
          '（UI 已按「第 X 块待通过 · 已掌握 N/M」显示）',
          CheckState.warn));
    }
    if (orphans != null) rows.addAll(orphanRows(orphans));
    return CheckSection('进度完整性', rows);
  }

  /// ASR-211 修复 4：孤儿行（台账有、内容包没有）单独成行。
  /// 迁移表做不做以这里的真机回执数据定夺，所以必须进导出。
  static List<CheckRow> orphanRows(OrphanScan o) => [
        CheckRow(
            '孤儿行',
            o.clean
                ? '台账 ${o.rows} 行 / 内容包 ${o.contentKeys} 块 · 无孤儿'
                : '台账 ${o.rows} 行 · 孤儿 ${o.count}（其中已掌握 ${o.orphanMastered}）'
                    '· 样本 ${o.orphanKeys.take(5).join('、')}',
            o.clean
                ? CheckState.pass
                : (o.orphanMastered > 0 ? CheckState.fail : CheckState.warn)),
      ];

  /// ASR-229 · D4 件 1：自检扩区到「我的模块」（自定义词块包）。
  ///
  /// 三条各管一种半截态，都不许静默过：
  ///  - 坏档案（连坐项：`listPackages` 会跳过它，包会无声消失）；
  ///  - 档案声明的块数 ≠ 台账 `user:` 行数（写入半途/外部改动）；
  ///  - 台账有 `user:` 行但没有档案声明它（删包半途）。
  /// 官方口径不受影响是**默认期望**，所以这里只报 user 区自己的分歧，不去动进度类行。
  static List<CheckRow> userPackageRows(UserPackageInventory inv) {
    final rows = <CheckRow>[
      CheckRow(
          '我的模块',
          inv.packageCount == 0
              ? '未导入任何自定义包（0 个，上限 $kUserPackageMaxPackages）'
              : '${inv.packageCount} 个包 · 档案声明 ${inv.declaredChunks} 块 · 台账 ${inv.userRowCount} 行'
                  '（上限 每包 $kUserPackageMaxChunks 块 / 每台 $kUserPackageMaxPackages 包）',
          inv.consistent ? CheckState.pass : CheckState.warn),
    ];
    if (inv.corruptCount > 0) {
      rows.add(CheckRow('坏档案',
          '${inv.corruptCount} 份档案解析失败，已在列表里跳过——请重新导入这些包',
          CheckState.fail));
    }
    if (inv.missingRows > 0) {
      rows.add(CheckRow('档案有、台账无',
          '档案声明 ${inv.declaredChunks} 块，台账只有 ${inv.userRowCount} 行（差 ${inv.missingRows}）',
          CheckState.fail));
    }
    if (inv.strayRows > 0) {
      rows.add(CheckRow('台账有、档案无',
          '${inv.strayRows} 行 user 块没有任何档案声明（删包半途或外部改动）',
          CheckState.warn));
    }
    return rows;
  }

  /// 区块②之一：识别引擎自检。
  static List<CheckRow> engineRows({
    required bool modelOnDisk,
    required bool engineReady,
    required bool engineFailed,
    String? engineError,
  }) {
    return [
      CheckRow(
          '离线模型',
          modelOnDisk ? '已就位' : '未下载（首次使用时会引导下载）',
          modelOnDisk ? CheckState.pass : CheckState.warn),
      CheckRow(
          '引擎状态',
          engineReady
              ? '已加载'
              : (engineFailed ? '加载失败${engineError == null ? '' : '：$engineError'}' : '尚未加载'),
          engineReady
              ? CheckState.pass
              : (engineFailed ? CheckState.fail : CheckState.warn)),
    ];
  }

  /// 区块②之二：增强包状态（高清发音包 + 增强识别包）。
  static List<CheckRow> packRows({
    required String hdVoiceLabel,
    required bool hdInstalled,
    required bool hdEngineUp,
    String? hdError,
    required bool enhancedPresent,
    required bool enhancedInstalled,
    required bool enhancedEnabled,
  }) {
    return [
      CheckRow(
          '高清发音包',
          hdInstalled
              ? '$hdVoiceLabel 已就绪${hdEngineUp ? ' · 引擎已运行' : ''}'
              : '未下载（可选包）',
          hdInstalled
              ? CheckState.pass
              : (hdError == null ? CheckState.warn : CheckState.fail)),
      CheckRow(
          '增强识别包',
          !enhancedPresent
              ? '清单未提供（跳过）'
              : (enhancedInstalled
                  ? '已就绪${enhancedEnabled ? ' · 已启用' : ' · 未启用'}'
                  : '未下载（可选包）'),
          enhancedInstalled
              ? CheckState.pass
              : (enhancedPresent ? CheckState.warn : CheckState.pass)),
    ];
  }

  /// 区块②之三：音频抽检——扫描缓存里的 WAV，校验字节与时长。
  ///
  /// 空文件/坏头/短于 0.1 秒都算损坏；目录里没有文件不算损坏
  /// （音频按需生成，未听过自然没有缓存）。
  static Future<AudioScan> scanAudioCache(List<String> dirPaths,
      {int maxSample = 24, double minDurationSec = 0.1}) async {
    final files = <File>[];
    for (final path in dirPaths) {
      final d = Directory(path);
      if (!await d.exists()) continue;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.wav')) files.add(e);
      }
    }
    if (files.isEmpty) return AudioScan.empty();

    files.sort((a, b) => a.path.compareTo(b.path));
    final step = files.length <= maxSample
        ? 1
        : (files.length / maxSample).ceil();
    final sampled = <File>[];
    for (var i = 0; i < files.length; i += step) {
      sampled.add(files[i]);
    }

    var zero = 0, badHeader = 0, tooShort = 0;
    final measured = <_WavSample>[];
    for (final f in sampled) {
      final len = await f.length();
      if (len <= 0) {
        zero++;
        continue;
      }
      final bytes = await f.readAsBytes();
      final info = parseWavHeader(
          bytes.length > 4096 ? Uint8List.sublistView(bytes, 0, 4096) : bytes);
      if (info == null || info.dataBytes <= 0) {
        badHeader++;
        continue;
      }
      measured.add(_WavSample(f.uri.pathSegments.last, len, info));
      if (info.durationSec < minDurationSec) tooShort++;
    }
    measured.sort((a, b) => a.seconds.compareTo(b.seconds));
    return AudioScan(
      total: files.length,
      checked: sampled.length,
      zeroBytes: zero,
      badHeaders: badHeader,
      tooShort: tooShort,
      shortestSec: measured.isEmpty ? 0 : measured.first.seconds,
      broken: zero + badHeader,
      shortestDetail:
          [for (final s in measured.take(3)) s.describe()].join(' ; '),
    );
  }

  static List<CheckRow> audioRows(AudioScan s) {
    if (s.total == 0) {
      return [const CheckRow('音频缓存', '暂无已生成的音频（按需生成，跳过抽检）', CheckState.warn)];
    }
    final out = <CheckRow>[
      CheckRow(
          '音频抽检',
          '共 ${s.total} 个 · 抽检 ${s.checked} 个 · '
          '空文件 ${s.zeroBytes} · 坏头 ${s.badHeaders}',
          s.broken == 0 ? CheckState.pass : CheckState.fail),
    ];
    if (s.zeroBytes > 0) {
      out.add(CheckRow('空文件', '${s.zeroBytes} 个 0 字节（需重听一遍重新生成）', CheckState.fail));
    }
    if (s.badHeaders > 0) {
      out.add(CheckRow('损坏音频', '${s.badHeaders} 个 WAV 头无法解析', CheckState.fail));
    }
    if (s.tooShort > 0) {
      // 只算提示不算故障：不同发音引擎/采样率下「短」的判据并不唯一，
      // 真机回执里 22/22 抽检都短但用户没反馈听感异常，先把细节留进归档再定标。
      out.add(CheckRow('时长偏短',
          '${s.tooShort} 个不足 0.1s（最短 ${s.shortestSec.toStringAsFixed(2)}s）· ${s.shortestDetail}',
          CheckState.warn));
    }
    return out;
  }

  /// 区块③：更新链路。逐源拉清单，校验能否解析出版本号。
  static Future<List<CheckRow>> updateRows({
    required int localVersionCode,
    List<String>? urls,
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final list = urls ?? UpdateService.manifestUrls;
    final own = client ?? http.Client();
    final rows = <CheckRow>[];
    var anyOk = false;
    try {
      for (final url in list) {
        final host = Uri.parse(url).host;
        try {
          final r = await own.get(Uri.parse(url)).timeout(timeout);
          if (r.statusCode != 200) {
            rows.add(CheckRow(host, 'HTTP ${r.statusCode}', CheckState.warn));
            continue;
          }
          final decoded = jsonDecode(r.body);
          if (decoded is! Map<String, dynamic>) {
            rows.add(CheckRow(host, '清单不是对象', CheckState.fail));
            continue;
          }
          final v = VersionInfo.fromJson(decoded);
          if (v.versionCode <= 0) {
            rows.add(CheckRow(host, '清单缺少有效 versionCode', CheckState.fail));
            continue;
          }
          anyOk = true;
          // 与更新弹窗同一判据：只认同 ABI 槽位的版本号，否则数字大小没有意义
          // （arm64 4xxx / x64 6xxx 与基础 2xxx 之间比大小会误报「有更新」）。
          final sameSlot = abiSlotOf(v.versionCode) == abiSlotOf(localVersionCode);
          final rel = !sameSlot
              ? '线上 ${v.versionName}/${v.versionCode} · 非本机 ABI 槽位'
              : (v.versionCode > localVersionCode
                  ? '线上 ${v.versionName}/${v.versionCode} · 有更新'
                  : '线上 ${v.versionName}/${v.versionCode} · 已是最新');
          rows.add(CheckRow(host, rel, CheckState.pass));
        } catch (e) {
          rows.add(CheckRow(host, '不可达', CheckState.warn));
        }
      }
    } finally {
      if (client == null) own.close();
    }
    rows.insert(
        0,
        CheckRow(
            '本机版本',
            'versionCode $localVersionCode · '
            '${anyOk ? '至少一个源可解析' : '所有源均未取到清单'}',
            anyOk ? CheckState.pass : CheckState.warn));
    return rows;
  }

  /// 把四个区块拼成一份可归档的结果。
  static SelfCheckReport assemble({
    required DateTime at,
    required List<ModuleAudit> audits,
    required List<CheckRow> engine,
    required List<CheckRow> packs,
    required List<CheckRow> audio,
    required List<CheckRow> update,
    required String localVersion,
    required int localVersionCode,
    OrphanScan? orphans,
    List<CheckRow> user = const [],
  }) {
    return SelfCheckReport(
      at: at,
      audits: audits,
      localVersion: localVersion,
      localVersionCode: localVersionCode,
      orphans: orphans,
      sections: [
        progressSection(audits, orphans: orphans),
        CheckSection('资源完整性', [...engine, ...packs, ...audio]),
        CheckSection('更新链路', update),
        // ASR-229 D4 件 1：自定义包区（无导入时传空 ⇒ 整段不出现，老包自检零变化）。
        if (user.isNotEmpty) CheckSection('我的模块', user),
      ],
    );
  }

  /// 归档文件名（发版前全模块扫描按时间戳留档，不覆盖历史）。
  static String fileName(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'selfcheck-${at.year}${two(at.month)}${two(at.day)}-'
        '${two(at.hour)}${two(at.minute)}${two(at.second)}.json';
  }

  /// 归档落盘：写到 `diagnostics/` 子目录，返回文件路径。
  static Future<File> archive(String dirPath, SelfCheckReport report) async {
    final dir = Directory('$dirPath/diagnostics');
    await dir.create(recursive: true);
    final f = File('${dir.path}/${fileName(report.at)}');
    await f.writeAsString(report.encode());
    return f;
  }
}

class AudioScan {
  const AudioScan({
    required this.total,
    required this.checked,
    required this.zeroBytes,
    required this.badHeaders,
    required this.tooShort,
    required this.shortestSec,
    required this.broken,
    this.shortestDetail = '',
  });

  final int total;
  final int checked;
  final int zeroBytes;
  final int badHeaders;
  final int tooShort;
  final double shortestSec;

  /// 硬故障数（0 字节 + 坏头）；时长偏短只算提示，不计入。
  final int broken;

  /// 最短几个文件的实测细节（名字/字节/采样参数/时长），随归档一起回传。
  final String shortestDetail;

  factory AudioScan.empty() => const AudioScan(
        total: 0,
        checked: 0,
        zeroBytes: 0,
        badHeaders: 0,
        tooShort: 0,
        shortestSec: 0,
        broken: 0,
      );
}

class _WavSample {
  const _WavSample(this.name, this.bytes, this.info);
  final String name;
  final int bytes;
  final WavInfo info;
  double get seconds => info.durationSec;

  String describe() =>
      '$name ${(bytes / 1024).toStringAsFixed(1)}KB ${info.sampleRate}Hz'
      '/${info.channels}ch/${info.bitsPerSample}bit '
      '${info.durationSec.toStringAsFixed(2)}s';
}

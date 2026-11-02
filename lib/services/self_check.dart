import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'audio_format.dart';
import 'progress_integrity.dart';
import 'update/update_service.dart';
import 'update/version_compare.dart';

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
  });

  final DateTime at;
  final List<ModuleAudit> audits;
  final List<CheckSection> sections;
  final String localVersion;
  final int localVersionCode;

  List<ModuleAudit> get reds => ProgressIntegrity.reds(audits);
  int get weakTraceCount => audits.where((a) => a.wrongChunkIds.isNotEmpty).length;
  bool get allGreen => reds.isEmpty && weakTraceCount == 0 && !anyFail;
  bool get anyFail => sections.any((s) => s.hasFail);

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'localVersion': localVersion,
        'localVersionCode': localVersionCode,
        'allGreen': allGreen,
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
  static CheckSection progressSection(List<ModuleAudit> audits) {
    final rows = <CheckRow>[];
    if (audits.isEmpty) {
      return const CheckSection('进度完整性', [
        CheckRow('模块', '无已启用模块', CheckState.warn),
      ]);
    }
    for (final a in audits) {
      final resume = a.snapshotIndex < 0
          ? '无断点'
          : '断点第 ${a.snapshotIndex + 1} 块';
      final ring = '${(a.ringRatio * 100).round()}%';
      final score = a.minMasteredScore < 0
          ? '无分数留痕'
          : '最低 ${a.minMasteredScore} / 均值 ${a.avgMasteredScore.toStringAsFixed(1)}';
      final state = !a.consistent
          ? CheckState.fail
          : (a.wrongChunkIds.isNotEmpty ? CheckState.warn : CheckState.pass);
      final detail =
          '台账 ${a.ledgerMastered}/${a.total} · $resume · 环 $ring · $score';
      rows.add(CheckRow(a.theme, detail, state));
    }
    final reds = ProgressIntegrity.reds(audits).length;
    rows.add(CheckRow(
        '汇总', '${audits.length} 个模块 · 红名单 $reds', reds == 0 ? CheckState.pass : CheckState.fail));
    return CheckSection('进度完整性', rows);
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
    var shortest = double.infinity;
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
      if (info.durationSec < shortest) shortest = info.durationSec;
      if (info.durationSec < minDurationSec) tooShort++;
    }
    return AudioScan(
      total: files.length,
      checked: sampled.length,
      zeroBytes: zero,
      badHeaders: badHeader,
      tooShort: tooShort,
      shortestSec: shortest.isFinite ? shortest : 0,
      broken: zero + badHeader + tooShort,
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
          '最短 ${s.shortestSec.toStringAsFixed(2)}s',
          s.broken == 0 ? CheckState.pass : CheckState.fail),
    ];
    if (s.zeroBytes > 0) {
      out.add(CheckRow('空文件', '${s.zeroBytes} 个 0 字节', CheckState.fail));
    }
    if (s.badHeaders > 0) {
      out.add(CheckRow('损坏音频', '${s.badHeaders} 个 WAV 头无法解析', CheckState.fail));
    }
    if (s.tooShort > 0) {
      out.add(CheckRow('时长异常', '${s.tooShort} 个不足 0.1s', CheckState.fail));
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
  }) {
    return SelfCheckReport(
      at: at,
      audits: audits,
      localVersion: localVersion,
      localVersionCode: localVersionCode,
      sections: [
        progressSection(audits),
        CheckSection('资源完整性', [...engine, ...packs, ...audio]),
        CheckSection('更新链路', update),
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
  });

  final int total;
  final int checked;
  final int zeroBytes;
  final int badHeaders;
  final int tooShort;
  final double shortestSec;
  final int broken;

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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../services/hd_voice.dart';
import '../services/loaders.dart';
import '../services/progress_integrity.dart';
import '../services/self_check.dart';
import '../services/user_package_store.dart';
import '../services/vosk_engine.dart';
import '../services/zipformer_asr.dart';
import '../ui/theme.dart';

/// ASR-203 自检页（设置 → 诊断）。
///
/// 区块：进度完整性（逐模块 台账/断点/环/分数 比对 + 红名单一键修复）、
/// 资源完整性（引擎自检 + 增强包状态 + 音频抽检）、更新链路（清单可达 + 版本解析）、
/// ASR-229 D4 起再加「我的模块」（自定义包的档案↔台账对账，坏档案记红），
/// 以及每次自检都自动归档一份 JSON（发版前全模块扫描留证）。
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  SelfCheckReport? _report;
  bool _running = false;
  bool _healing = false;
  String? _error;
  String? _archivePath;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    final progress = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    // HdVoiceService 在少数入口（E2E 驱动页）可能没挂 Provider；缺了就跳过该子项，
    // 绝不让整页自检因为一个可选服务缺席而崩。
    HdVoiceService? hd;
    try {
      hd = Provider.of<HdVoiceService>(context, listen: false);
    } catch (_) {
      hd = null;
    }
    final enhanced = EnhancedAsrService.instance;
    try {
      final audits = await ProgressIntegrity.auditAll(progress, content);

      var modelOnDisk = false;
      try {
        modelOnDisk = await SpeechEngine.modelOnDisk();
      } catch (_) {}
      final engine = SpeechEngine.instance;
      final engineRows = SelfCheck.engineRows(
        modelOnDisk: modelOnDisk,
        engineReady: engine.isReady,
        engineFailed: engine.failed,
        engineError: engine.failed ? await engine.diagText() : null,
      );

      await enhanced.refresh().catchError((_) {});
      final active = hd?.activeVoice;
      final packRows = SelfCheck.packRows(
        hdVoiceLabel: active?.label ?? '未选择音色',
        hdInstalled: hd?.ready ?? false,
        hdEngineUp: hd?.engineUp ?? false,
        hdError: hd?.engineError,
        enhancedPresent: enhanced.manifest != null,
        enhancedInstalled: enhanced.installed,
        enhancedEnabled: enhanced.enabled,
      );

      var audio = AudioScan.empty();
      String? docsDir;
      try {
        final tmp = await getTemporaryDirectory();
        docsDir = (await getApplicationDocumentsDirectory()).path;
        audio = await SelfCheck.scanAudioCache([
          '${tmp.path}/listening_audio',
          '${tmp.path}/hd_voice',
        ]);
      } catch (_) {}

      PackageInfo? pi;
      try {
        pi = await PackageInfo.fromPlatform();
      } catch (_) {}
      final localCode = int.tryParse(pi?.buildNumber ?? '') ?? 0;
      final updateRows = await SelfCheck.updateRows(localVersionCode: localCode);

      final report = SelfCheck.assemble(
        at: DateTime.now(),
        audits: audits,
        engine: engineRows,
        packs: packRows,
        audio: SelfCheck.audioRows(audio),
        update: updateRows,
        localVersion: pi?.version ?? '—',
        localVersionCode: localCode,
        // ASR-211 修复 4：孤儿行（台账有、内容包没有）随自检归档一起回传，
        // 「要不要做 id 迁移表」看这份真机数据，不靠猜。
        orphans: await ProgressIntegrity.orphans(progress, content),
        // ASR-229 D4 件 1：自定义包扩区（坏档案不许静默跳过）。
        user: SelfCheck.userPackageRows(
            await UserPackageStore(progress.database).inspect()),
      );

      String? path;
      if (docsDir != null) {
        try {
          final f = await SelfCheck.archive(docsDir, report);
          path = f.path;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _report = report;
        _archivePath = path;
        _running = false;
      });
      await progress
          .logEvent('self_check', report.toJson())
          .catchError((_) {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '自检失败：$e';
        _running = false;
      });
    }
  }

  /// 一键修复：把红名单模块的陈旧断点全部按台账归位，再复跑一次自检。
  ///
  /// ASR-211 修复 3：与冷启动/回前台/打开模块共用 `reconcileAll` 这一个入口
  /// （时机④）。它自己重扫台账，不吃页面上可能已过期的报告。
  Future<void> _heal() async {
    final report = _report;
    if (report == null || _healing) return;
    setState(() => _healing = true);
    final progress = Provider.of<ProgressService>(context, listen: false);
    final content = Provider.of<ContentPack>(context, listen: false);
    try {
      final r =
          await ProgressIntegrity.reconcileAll(progress, content, reason: 'heal_button');
      await progress
          .logEvent('self_check_heal', {
        'healed': r.healed,
        'reds': r.reds,
        'remaining': r.remaining,
      }).catchError((_) {});
    } finally {
      if (mounted) setState(() => _healing = false);
    }
    await _run();
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    final reds = r?.reds.length ?? 0;
    return Scaffold(
      key: const Key('diagnostics-screen'),
      appBar: AppBar(title: const Text('诊断')),
      body: RefreshIndicator(
        onRefresh: _run,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _summary(r, reds),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('diag-run'),
                    onPressed: _running ? null : _run,
                    icon: Icon(Icons.refresh, color: kOnPrimary),
                    label: Text(_running ? '自检中…' : '重新自检',
                        style: TextStyle(color: kOnPrimary)),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: kPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('diag-heal'),
                    onPressed: (reds == 0 || _healing) ? null : _heal,
                    icon: Icon(Icons.build,
                        color: reds == 0 ? kTextFaint : kPrimary),
                    label: Text(_healing ? '修复中…' : '一键修复（$reds）',
                        style: TextStyle(
                            color: reds == 0 ? kTextFaint : kPrimary)),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: kError, fontSize: 13)),
            ],
            if (r != null) ...[
              const SizedBox(height: 16),
              for (final s in r.sections) _section(s),
              const SizedBox(height: 16),
              _archiveCard(r),
            ] else if (!_running)
              const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _summary(SelfCheckReport? r, int reds) {
    // 只有「断点红名单」或「硬失败」才判需要处理；错块留痕与可选包未下载算提示项。
    final needAction = r != null && r.needsAction;
    final hints = r?.hintCount ?? 0;
    final accent = needAction ? kError : kSuccess;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent),
      ),
      child: Row(
        children: [
          Icon(needAction
              ? Icons.error_outline
              : (hints > 0 ? Icons.verified_outlined : Icons.check_circle_outline),
              color: needAction
                  ? kError
                  : (hints > 0 ? kWarning : kSuccess),
              size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    r == null
                        ? '正在自检…'
                        : (needAction
                            ? '需要处理'
                            : (hints > 0 ? '自检通过：零红（$hints 项提示）' : '自检通过：零红')),
                    style: TextStyle(
                        color: kText,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                    r == null
                        ? '首次进入自动运行'
                        : '断点红名单 $reds 个 · 留痕待补 ${r.weakTraceCount} 个 · '
                            '${r.localVersion}/${r.localVersionCode}',
                    style: TextStyle(color: kTextMuted, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(CheckSection s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(s.title,
                    style: TextStyle(
                        color: kPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Icon(
                    s.hasFail
                        ? Icons.error_outline
                        : (s.hasWarn ? Icons.warning_amber : Icons.check_circle_outline),
                    color: s.hasFail
                        ? kError
                        : (s.hasWarn ? kWarning : kSuccess),
                    size: 18),
              ],
            ),
            const SizedBox(height: 8),
            for (final row in s.rows) _row(row),
          ],
        ),
      ),
    );
  }

  Widget _row(CheckRow row) {
    final color = switch (row.state) {
      CheckState.pass => kSuccess,
      CheckState.warn => kWarning,
      CheckState.fail => kError,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 108,
            child: Text(row.label,
                style: TextStyle(color: kTextSecondary, fontSize: 13)),
          ),
          Expanded(
            child: Text(row.value,
                style: TextStyle(color: kText, fontSize: 13, height: 1.35)),
          ),
        ],
      ),
    );
  }

  Widget _archiveCard(SelfCheckReport r) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('自检归档',
              style: TextStyle(
                  color: kPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
              _archivePath == null
                  ? '本次未能落盘（无存储权限或首次自检）'
                  : _archivePath!,
              style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: r.encode()));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('自检 JSON 已复制，可直接发给开发者')));
                },
                child: Text('复制自检 JSON', style: TextStyle(color: kPrimary)),
              ),
              const Spacer(),
              Text(
                '${r.at.month}/${r.at.day} ${r.at.hour}:${r.at.minute}',
                style: TextStyle(color: kTextFaint, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

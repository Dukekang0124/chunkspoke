import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../services/data_channel.dart';
import '../services/legacy_gate.dart';
import '../services/license_state.dart';
import '../services/loaders.dart';
import '../ui/copy_morph.dart';
import '../ui/theme.dart';

/// 1.5.10（#209 通道版）· 数据备份页。
///
/// 只做两件事：把本机数据导成一个 JSON 文件；把一份 JSON 合并回来。
/// 不联网、不上传；导入是「合并」，不会删掉本机更新的进度。
class DataBackupScreen extends StatefulWidget {
  const DataBackupScreen({super.key});

  @override
  State<DataBackupScreen> createState() => _DataBackupScreenState();
}

class _DataBackupScreenState extends State<DataBackupScreen> {
  final _ctl = TextEditingController();
  bool _busy = false;
  String? _lastPath;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final p = Provider.of<ProgressService>(context, listen: false);
      final gate = await openLegacyGate();
      final export = await buildChannelExport(db: p.database, gate: gate);
      final file = await saveChannelExport(export);
      if (!mounted) return;
      setState(() => _lastPath = file.path);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCard,
          scrollable: true,
          title: Text('备份已生成', style: TextStyle(color: kText, fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${export.chunkCount} 个词块进度 · ${export.sessionCount} 条学习记录 · '
                  '${export.kvCount} 项设置',
                  style: TextStyle(color: kTextSecondary, fontSize: 13)),
              const SizedBox(height: 8),
              Text('文件位置：', style: TextStyle(color: kTextMuted, fontSize: 12)),
              SelectableText(file.path,
                  style: TextStyle(color: kPrimary, fontSize: 12)),
              const SizedBox(height: 10),
              Text('换机或重装时，用这份 JSON 在「导入备份」里合并回来。\n'
                  '不含录音、不含任何 Key，也不含解锁码与授权状态'
                  '（换机后重输一次自己的码即可，老用户标记照旧带回）。\n'
                  '自定义词块只带走词表档案，块上的学习进度不随备份走；'
                  '合并后按档案补回，记为未开始学习。是否备份由你决定。',
                  style: TextStyle(color: kTextFaint, fontSize: 12)),
            ],
          ),
          actions: [
            CopyMorphButton(
              variant: CopyMorphVariant.text,
              label: '复制 JSON',
              copy: () => Clipboard.setData(ClipboardData(text: export.json)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('完成', style: TextStyle(color: kTextMuted)),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      _toast('剪贴板里没有文字');
      return;
    }
    setState(() => _ctl.text = text);
  }

  Future<void> _import() async {
    final text = _ctl.text.trim();
    if (text.isEmpty) {
      _toast('先把备份 JSON 粘进来');
      return;
    }
    setState(() => _busy = true);
    try {
      final p = Provider.of<ProgressService>(context, listen: false);
      final license = Provider.of<LicenseState>(context, listen: false);
      // ASR-233 付费门：备份本身永久免费；未授权机器不接受件里的词表档案
      // （否则合并一份别人的备份 = 白拿自定义包）。本机已有的包不受影响。
      final allowUserPackages = license.allows(LicenseFeature.customImport);
      final gate = await openLegacyGate();
      final plan = await previewChannelImport(
          db: p.database, text: text, allowUserPackages: allowUserPackages);
      if (!mounted) return;
      if (plan.ignoredUserArchives > 0) {
        p.logEvent('custom_import_archive_ignored',
            {'count': plan.ignoredUserArchives});
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCard,
          scrollable: true,
          title: Text('确认合并', style: TextStyle(color: kText, fontSize: 17)),
          content: Text(
            '新增词块 ${plan.newChunks} 个、更新进度 ${plan.updatedChunks} 个、'
            '保留本机进度 ${plan.keptChunks} 个\n'
            '追加学习记录 ${plan.newSessions} 条（重复 ${plan.dupSessions} 条跳过）\n'
            '补充设置 ${plan.newKv} 项（已有的不覆盖）\n'
            '${plan.adoptedLegacy == 1 ? '\n这份备份带老用户标记，会一并恢复。' : ''}\n'
            '${plan.ignoredLicenseKv > 0 ? '\n件里有 ${plan.ignoredLicenseKv} 项授权信息，已忽略：'
                '解锁码不随备份走，换机请重输一次自己的码。' : ''}\n'
            '${plan.ignoredUserChunks > 0 ? '\n件里有 ${plan.ignoredUserChunks} 条自定义块行，已忽略：'
                '自定义词块只按词表档案补回。' : ''}\n'
            '${plan.ignoredUserArchives > 0 ? '\n件里有 ${plan.ignoredUserArchives} 份自定义词表档案，已忽略：'
                '导入自己的词表需要解锁码。本机已有的包、学习记录和删除都不受影响。' : ''}\n'
            '合并只补不删，本机比备份新的进度会被保留。',
            style: TextStyle(color: kTextSecondary, fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: kTextMuted)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('合并导入', style: TextStyle(color: kPrimary)),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final applied = await applyChannelImport(
          db: p.database,
          gate: gate,
          text: text,
          store: p.chunkStore,
          allowUserPackages: allowUserPackages);
      // 设置可能被补进 kv 缓存，重载一次让页面立刻看到新值。
      await p.init();
      if (!mounted) return;
      setState(() => _ctl.clear());
      final rebuiltNote = applied.rebuiltUserRows > 0
          ? '，自定义词块按档案补回 ${applied.rebuiltUserRows} 行（记为未开始学习）'
          : '';
      final ignoredArchivesNote = applied.ignoredUserArchives > 0
          ? '，已忽略 ${applied.ignoredUserArchives} 份自定义词表档案（需要解锁码）'
          : '';
      _toast(applied.nothingToDo
          ? '没有需要补的数据（已是最新）$ignoredArchivesNote'
          : '已合并：词块 +${applied.newChunks}/更新 ${applied.updatedChunks}，'
              '记录 +${applied.newSessions}$rebuiltNote$ignoredArchivesNote');
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('数据备份'),
        backgroundColor: kBg,
        foregroundColor: kText,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('导出备份',
                    style: TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('把本机学习数据存成一个 JSON 文件：词块进度、学习记录、设置。',
                    style: TextStyle(color: kTextMuted, fontSize: 12)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _export,
                      style: FilledButton.styleFrom(backgroundColor: kPrimary),
                      child: Text(_busy ? '处理中…' : '导出备份',
                          style: TextStyle(color: kOnPrimary)),
                    ),
                    const SizedBox(width: 8),
                    CopyMorphButton(
                      variant: CopyMorphVariant.text,
                      label: '复制路径',
                      copy: () async {
                        if (_lastPath == null) return;
                        await Clipboard.setData(ClipboardData(text: _lastPath!));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('导入备份（合并）',
                    style: TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('把备份 JSON 粘贴到下面。只补不删：本机比备份新的进度会保留。',
                    style: TextStyle(color: kTextMuted, fontSize: 12)),
                const SizedBox(height: 10),
                TextField(
                  controller: _ctl,
                  maxLines: 6,
                  minLines: 4,
                  style: TextStyle(color: kText, fontSize: 12),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: kBg,
                    hintText: '{"schema_version":1, ...}',
                    hintStyle: TextStyle(color: kBorderStrong, fontSize: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : _paste,
                      child: Text('从剪贴板粘贴',
                          style: TextStyle(color: kPrimary, fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy ? null : _import,
                      style: FilledButton.styleFrom(backgroundColor: kPrimary),
                      child: Text(_busy ? '处理中…' : '检查并合并',
                          style: TextStyle(color: kOnPrimary)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '备份只在本机生成，不联网、不上传。它不会带录音，也不含任何 API Key 明文。',
            style: TextStyle(color: kTextFaint, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }
}

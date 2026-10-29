import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../services/data_channel.dart';
import '../services/legacy_gate.dart';
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
          title: const Text('备份已生成', style: TextStyle(color: kText, fontSize: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${export.chunkCount} 个词块进度 · ${export.sessionCount} 条学习记录 · '
                  '${export.kvCount} 项设置',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              const Text('文件位置：', style: TextStyle(color: Colors.white54, fontSize: 12)),
              SelectableText(file.path,
                  style: const TextStyle(color: kPrimary, fontSize: 12)),
              const SizedBox(height: 10),
              const Text('换机或重装时，用这份 JSON 在「导入备份」里合并回来。\n'
                  '不含录音、不含任何 Key；是否备份由你决定。',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
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
              child: const Text('完成', style: TextStyle(color: Colors.white54)),
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
      final gate = await openLegacyGate();
      final plan = await previewChannelImport(db: p.database, text: text);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCard,
          title: const Text('确认合并', style: TextStyle(color: kText, fontSize: 17)),
          content: Text(
            '新增词块 ${plan.newChunks} 个、更新进度 ${plan.updatedChunks} 个、'
            '保留本机进度 ${plan.keptChunks} 个\n'
            '追加学习记录 ${plan.newSessions} 条（重复 ${plan.dupSessions} 条跳过）\n'
            '补充设置 ${plan.newKv} 项（已有的不覆盖）\n'
            '${plan.adoptedLegacy == 1 ? '\n这份备份带老用户标记，会一并恢复。' : ''}\n'
            '合并只补不删，本机比备份新的进度会被保留。',
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消', style: TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('合并导入', style: TextStyle(color: kPrimary)),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final applied = await applyChannelImport(
          db: p.database, gate: gate, text: text);
      // 设置可能被补进 kv 缓存，重载一次让页面立刻看到新值。
      await p.init();
      if (!mounted) return;
      setState(() => _ctl.clear());
      _toast(applied.nothingToDo
          ? '没有需要补的数据（已是最新）'
          : '已合并：词块 +${applied.newChunks}/更新 ${applied.updatedChunks}，'
              '记录 +${applied.newSessions}');
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
                const Text('导出备份',
                    style: TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('把本机学习数据存成一个 JSON 文件：词块进度、学习记录、设置。',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _export,
                      style: FilledButton.styleFrom(backgroundColor: kPrimary),
                      child: Text(_busy ? '处理中…' : '导出备份',
                          style: const TextStyle(color: Colors.black87)),
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
                const Text('导入备份（合并）',
                    style: TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('把备份 JSON 粘贴到下面。只补不删：本机比备份新的进度会保留。',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 10),
                TextField(
                  controller: _ctl,
                  maxLines: 6,
                  minLines: 4,
                  style: const TextStyle(color: kText, fontSize: 12),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: kBg,
                    hintText: '{"schema_version":1, ...}',
                    hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
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
                      child: const Text('从剪贴板粘贴',
                          style: TextStyle(color: kPrimary, fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy ? null : _import,
                      style: FilledButton.styleFrom(backgroundColor: kPrimary),
                      child: Text(_busy ? '处理中…' : '检查并合并',
                          style: const TextStyle(color: Colors.black87)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '备份只在本机生成，不联网、不上传。它不会带录音，也不含任何 API Key 明文。',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }
}

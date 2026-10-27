import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/merge.dart';
import '../data/protocol.dart';
import '../platform/file_io.dart';
import '../ui/theme.dart';

class DataScreen extends StatefulWidget {
  const DataScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  bool _busy = false;
  String? _notice;
  bool _noticeIsError = false;

  AppSession get _session => widget.session;

  bool get _ready => _session.storageReady && _session.content != null;

  void _report(String text, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _notice = text;
      _noticeIsError = isError;
    });
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final pkg = _session.buildExportPackage();
      final now = DateTime.now();
      final stamp = '${now.year}'
          '-${now.month.toString().padLeft(2, '0')}'
          '-${now.day.toString().padLeft(2, '0')}';
      final name = 'chunkspoke-web-$stamp-${_session.deviceTag}.json';
      await saveTextFile(name, pkg.encode());
      _report('已导出 $name（${pkg.chunks.length} 块 / ${pkg.events.length} 条复习事件）');
    } catch (e) {
      _report('导出失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final raw = await pickTextFile();
      if (raw == null) {
        _report('已取消选择文件');
        return;
      }
      final DataPackage pkg;
      try {
        pkg = DataPackage.parse(raw);
      } on ProtocolException catch (e) {
        _report('整包拒收：${e.message}', isError: true);
        return;
      }
      final MergeReport preview;
      try {
        preview = _session.previewImport(pkg);
      } catch (e) {
        _report('无法预演合并：$e', isError: true);
        return;
      }
      if (!mounted) return;
      final confirmed = await _showImportPreview(pkg, preview);
      if (confirmed != true) {
        _report('已取消导入，本机数据未改动');
        return;
      }
      final report = await _session.importPackage(pkg);
      _report('导入完成：$report');
    } catch (e) {
      _report('导入失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final first = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('清空本机学习数据？'),
        content: const Text(
          '将删除本机的词块进度、复习事件与统计。导入快照与设置不受影响。\n\n'
          '建议先导出备份：清空后无法撤销。',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;

    final second = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('再次确认'),
        content: Text(
          '确认清空 ${_session.chunks.length} 块学习进度、${_session.events.length} 条复习事件？此操作不可撤销。',
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('不清空')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kError, foregroundColor: Colors.black87),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (second != true) {
      _report('已取消清空');
      return;
    }

    setState(() => _busy = true);
    try {
      await _session.clearLearningData();
      _report('本机学习数据已清空');
    } catch (e) {
      _report('清空失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _showImportPreview(DataPackage pkg, MergeReport preview) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('导入预览'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PreviewLine('来源', '${pkg.origin} ${pkg.originVersion}'),
                _PreviewLine('导出时间', pkg.exportedAt.isEmpty ? '未标注' : pkg.exportedAt),
                _PreviewLine('设备标签', pkg.deviceTag.isEmpty ? '未标注' : pkg.deviceTag),
                _PreviewLine('文件内', '${pkg.chunks.length} 块 / ${pkg.events.length} 条事件'),
                const SizedBox(height: 8),
                const Divider(color: kLocked),
                const SizedBox(height: 8),
                _PreviewLine('预计新增', '${preview.added} 块'),
                _PreviewLine('预计更新', '${preview.updated} 块（按 updated_at 新者胜）'),
                _PreviewLine('保持不变', '${preview.skipped} 块'),
                _PreviewLine('孤儿块', '${preview.orphan} 块（内容包里没有，原样保留）'),
                _PreviewLine('内容包版本', preview.packsMismatch ? '与本机不一致（仅提示，不阻断）' : '一致'),
                if (preview.warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '解析提示',
                    style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  for (final w in preview.warnings.take(6))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '· $w',
                        style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                const Text(
                  '合并规则：按 updated_at 新者胜；已掌握或档位走完会补齐通过语义；连续通过只增不减。',
                  style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('合并导入'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _session.revision,
      builder: (context, _, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '数据',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 8),
          const Text(
            '学习数据存本机浏览器（IndexedDB），文件不出浏览器。',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<String?>(
            valueListenable: _session.storageError,
            builder: (context, error, _) => Text(
              error == null
                  ? '本机存储探测中…'
                  : (error.isEmpty ? '本机存储：IndexedDB 可用' : '本机存储不可用：$error'),
              style: TextStyle(
                color: error == null || error.isEmpty ? Colors.white54 : kError,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '本机进度：${_session.chunks.length} 块 / ${_session.events.length} 条复习事件'
            '${_session.content == null ? '' : ' · 内容包 ${_session.packs['content_pack'] ?? ''}'}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          if (_notice != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _noticeIsError ? kError : kUnlocked),
              ),
              child: Text(
                _notice!,
                style: TextStyle(
                  color: _noticeIsError ? kError : Colors.white70,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          _ActionTile(
            title: '导出备份',
            body: '导出为 JSON 交换文件（schema_version=1），用于本机备份或迁移。',
            enabled: _ready && !_busy,
            busy: _busy,
            actionLabel: '导出',
            onPressed: _export,
          ),
          const SizedBox(height: 12),
          _ActionTile(
            title: '导入',
            body: '先预览再合并：按 updated_at 新者胜，不做整包覆盖。当前只支持网页版自己导出的文件。',
            enabled: _ready && !_busy,
            busy: _busy,
            actionLabel: '选择文件',
            onPressed: _import,
          ),
          const SizedBox(height: 12),
          _ActionTile(
            title: '清空本机学习数据',
            body: '只清除词块进度、统计与事件，不动导入快照与设置。需二次确认。',
            enabled: _ready && !_busy,
            busy: _busy,
            actionLabel: '清空',
            onPressed: _clear,
            danger: true,
          ),
          const SizedBox(height: 20),
          const Text(
            'App 的 JSON 导出将在 1.5.10 提供；互通上线前，网页版与 App 数据各自独立。',
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5)),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.title,
    required this.body,
    required this.enabled,
    required this.busy,
    required this.actionLabel,
    required this.onPressed,
    this.danger = false,
  });

  final String title;
  final String body;
  final bool enabled;
  final bool busy;
  final String actionLabel;
  final Future<void> Function() onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final accent = danger ? kError : kPrimary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLocked),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton(
            onPressed: enabled ? onPressed : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side: BorderSide(color: enabled ? accent : kLocked),
            ),
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
                  )
                : Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

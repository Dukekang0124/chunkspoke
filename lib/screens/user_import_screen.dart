import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../services/loaders.dart';
import '../services/progress_integrity.dart';
import '../services/user_package.dart';
import '../services/user_package_files.dart';
import '../services/user_package_store.dart';
import '../ui/theme.dart';
import 'user_preview_screen.dart';

/// ASR-228 · D3 落库件 1：自定义词块包导入器（文件 / 粘贴 / 模板 三入口）。
///
/// 与 `UserPreviewScreen`（只预览、结构上零写入）的分工：
///  - 那一页是「看解析长什么样」，永远不写；
///  - 这一页是**确认步**：主体复用同一个 [UserPreviewBody]，
///    只有按下「确认导入（将写入本机）」才落库，落库只写 `user:` 命名空间。
///
/// 文案红线：不承诺没实装的能力（六步/复习对 user 块何时可用属 D4 之后的事）。
class UserImportScreen extends StatefulWidget {
  const UserImportScreen({super.key, this.files});

  /// 注入用（测试给临时目录）；生产默认走应用 documents 目录。
  final UserPackageFiles? files;

  @override
  State<UserImportScreen> createState() => _UserImportScreenState();
}

class _UserImportScreenState extends State<UserImportScreen> {
  late final UserPackageFiles _files = widget.files ?? UserPackageFiles();
  final TextEditingController _input = TextEditingController();

  UserPackageValidation? _result;
  UserImportResult? _imported;
  List<UserPackageFile> _found = const [];
  String _dirNote = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _scanFiles();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _scanFiles() async {
    try {
      final dir = await _files.resolveDir();
      final list = await _files.list();
      if (!mounted) return;
      setState(() {
        _found = list;
        _dirNote = dir;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _dirNote = '目录读不到：$e');
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      _toast('剪贴板里没有文字');
      return;
    }
    setState(() {
      _input.text = text;
      _result = null;
      _imported = null;
    });
  }

  void _fill(String text) {
    setState(() {
      _input.text = text;
      _result = null;
      _imported = null;
    });
  }

  Future<void> _loadFile(UserPackageFile f) async {
    try {
      final text = await _files.read(f);
      _fill(text);
      _toast('已读入「${f.name}」${f.sizeText}');
    } catch (e) {
      _toast('这个文件读不了：$e');
    }
  }

  Future<void> _writeTemplate({required bool json}) async {
    try {
      final p = await _files.writeTemplate(json: json);
      _fill(json ? userPackageJsonTemplate() : userPackageCsvTemplate());
      _toast('模板已写成本机文件，改完放回这个目录再点「重新扫描」：\n$p');
    } catch (e) {
      _toast('模板写入失败：$e');
    }
  }

  void _parse() {
    setState(() {
      _result = parseAndValidateUserPackage(_input.text);
      _imported = null;
    });
  }

  /// 落库件 2 + 件 3：一次事务写 `user:` 行与包档案，写完立刻跑全模块对账。
  Future<void> _confirmImport() async {
    final v = _result;
    if (v == null || !v.ok || _busy) return;
    setState(() => _busy = true);
    try {
      final progress = Provider.of<ProgressService>(context, listen: false);
      final content = Provider.of<ContentPack>(context, listen: false);
      final store = UserPackageStore(progress.database);
      final res = await store.importValidation(v);
      if (!res.ok) {
        if (!mounted) return;
        setState(() => _imported = res);
        _toast(res.note);
        return;
      }
      // 件 3：导入是新的台账写入点 → 同帧跑 reconcileAll，
      // 让「断点按台账归位」这条自愈链立刻覆盖这次写入（不等到下次冷启动）。
      final healed = await ProgressIntegrity.reconcileAll(
        progress,
        content,
        reason: 'user_import',
      );
      if (!mounted) return;
      setState(() => _imported = res);
      _toast('${res.note} · 官方进度未变'
          '${(healed.healed > 0) ? ' · 顺带归位 ${healed.healed} 处断点' : ''}');
      await _scanFiles();
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelConfirmation() async {
    setState(() => _imported = null);
    _toast('没写入任何东西——预览留在屏幕上，你随时可以改完再导。');
  }

  @override
  Widget build(BuildContext context) {
    final v = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('我的模块 · 导入')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '未点「确认导入（将写入本机）」之前，不写入任何东西。\n'
            '确认后也只写进「我的模块」，官方模块、复习排期与已掌握计数都不受影响。',
            style: TextStyle(color: kPrimary, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          Text('三个入口任选一个', style: TextStyle(color: kText, fontSize: 15)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                  onPressed: _pasteFromClipboard,
                  child: Text('从剪贴板粘贴', style: TextStyle(color: kText))),
              OutlinedButton(
                  onPressed: () => _writeTemplate(json: false),
                  child: Text('生成 CSV 模板文件', style: TextStyle(color: kText))),
              OutlinedButton(
                  onPressed: () => _writeTemplate(json: true),
                  child: Text('生成 JSON 模板文件', style: TextStyle(color: kText))),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                  onPressed: () => _fill(userPackageCsvTemplate()),
                  child: Text('或直接填进下面输入框（CSV 模板）',
                      style: TextStyle(color: kPrimary))),
              TextButton(
                  onPressed: () => _fill(userPackageJsonTemplate()),
                  child: Text('（JSON 模板）', style: TextStyle(color: kPrimary))),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _input,
            maxLines: 8,
            style: TextStyle(color: kText, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'front,back,module_name…',
              hintStyle: TextStyle(color: kTextFaint),
              filled: true,
              fillColor: kCard,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: (_) => setState(() => _result = null),
          ),
          const SizedBox(height: 10),
          FilledButton(
              onPressed: _input.text.trim().isEmpty ? null : _parse,
              child: Text('解析并预览', style: TextStyle(color: kOnPrimary))),
          const SizedBox(height: 18),
          _fileSection(),
          if (v != null) ...[
            const Divider(),
            const SizedBox(height: 8),
            Text('确认步（和预览页同一套主体）',
                style: TextStyle(color: kText, fontSize: 15)),
            const SizedBox(height: 8),
            UserPreviewBody(result: v, previewOnly: false),
            const SizedBox(height: 12),
            if (v.ok)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                        onPressed: _busy ? null : _cancelConfirmation,
                        child: Text('取消（不写入）',
                            style: TextStyle(color: kTextMuted))),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                        onPressed: _busy ? null : _confirmImport,
                        child: Text('确认导入（将写入本机）',
                            style: TextStyle(color: kOnPrimary))),
                  ),
                ],
              )
            else
              Text('这一份没过闸：一行都不会写入。按上面的行号改完再解析。',
                  style: TextStyle(color: kTextSecondary, fontSize: 12)),
          ],
          if (_imported != null) _importedBanner(_imported!),
          const SizedBox(height: 18),
          TextButton(
              onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const UserPreviewScreen()),
                  ),
              child: Text('只想看「只预览不落库」那一页',
                  style: TextStyle(color: kPrimary))),
          TextButton(
              onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const UserImportFeedbackScreen()),
                  ),
              child: Text('六项体验清单（填完复制给开发者）',
                  style: TextStyle(color: kPrimary))),
        ],
      ),
    );
  }

  Widget _fileSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: kCard, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('本机文件',
                    style: TextStyle(
                        color: kText,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
              ),
              TextButton(
                  onPressed: _busy ? null : _scanFiles,
                  child: Text('重新扫描', style: TextStyle(color: kPrimary))),
            ],
          ),
          Text(_dirNote.isEmpty ? '目录准备中…' : '目录：$_dirNote',
              style: TextStyle(color: kTextFaint, fontSize: 11)),
          const SizedBox(height: 6),
          if (_found.isEmpty)
            Text('这个目录里还没有 .csv / .json。'
                '用上面的「生成模板文件」拿一份，改完放回这里再扫描。',
                style: TextStyle(color: kTextMuted, fontSize: 12))
          else
            for (final f in _found.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(f.name,
                    style: TextStyle(color: kText, fontSize: 13)),
                subtitle: Text('${f.sizeText} · ${f.modified}',
                    style: TextStyle(color: kTextFaint, fontSize: 11)),
                trailing: TextButton(
                    onPressed: () => _loadFile(f),
                    child: Text('读入', style: TextStyle(color: kPrimary))),
              ),
        ],
      ),
    );
  }

  Widget _importedBanner(UserImportResult r) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: r.ok ? kSuccess.withValues(alpha: 0.14) : kCard,
          borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.ok ? '已写入本机' : '没写入',
              style: TextStyle(
                  color: r.ok ? kSuccess : kTextSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(r.note, style: TextStyle(color: kText, fontSize: 12)),
          if (r.ok) ...[
            const SizedBox(height: 4),
            Text('当前共 ${r.packagesAfter} 个包（上限 $kUserPackageMaxPackages）。'
                '官方模块的已掌握/复习计数没有变化。',
                style: TextStyle(color: kTextMuted, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

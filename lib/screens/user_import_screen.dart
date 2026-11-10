import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:provider/provider.dart';

import '../models/content_pack.dart';
import '../services/license_state.dart';
import '../services/loaders.dart';
import '../services/progress_integrity.dart';
import '../services/user_package.dart';
import '../services/user_package_files.dart';
import '../services/user_package_store.dart';
import '../services/user_text_parser.dart';
import '../ui/theme.dart';
import 'license_activate.dart';
import 'user_package_detail_screen.dart';
import 'user_preview_screen.dart';

/// 「添加我的英文本」（1.9.2）。
///
/// 设计目标只有一个：**不懂技术的人也能把自己的英文变成能学的句子**。
/// 所以这一页的主路径是「粘贴 → 整理 → 保存并开始学」，不是填表：
///  - 粘一句、一段、一段对话都行，[parsePastedUserText] 只认结构，不翻译；
///  - 有中文就顺手当意思，没有也能学（六步里只是不显示翻译行）；
///  - 保存后直接进六步练习，不用再回详情页点一次；
///  - 表格 / 文件 / 模板收进「我以前存过表格或文件」，默认折叠。
///
/// 红线不变：整理与预览永久免费，只有「保存」要解锁码；只写 `user:` 命名空间，
/// 官方内容与学习记录不受影响。
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
  final TextEditingController _name =
      TextEditingController(text: kUserDefaultModuleName);

  UserPackageValidation? _result;
  UserImportResult? _imported;
  List<String> _notes = const [];
  String _kindLabel = '';
  List<UserPackageFile> _found = const [];
  List<String> _existingNames = const [];
  String _dirNote = '';

  bool _busy = false;
  bool _saved = false;
  bool _nameTouched = false;
  bool _namesLoaded = false;
  // 整理结果出现/消失会重排长列表；展开状态自己记着，别让「我以前存过表格或文件」
  // 在用户刚点完示例后突然收起来。
  bool _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    _scanFiles();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_namesLoaded) return;
    _namesLoaded = true;
    _loadExistingNames(autoPick: true);
  }

  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  String get _currentName {
    final t = _name.text.trim();
    return t.isEmpty ? kUserDefaultModuleName : t;
  }

  /// 默认名被占用时自动换成「我的英语本 2」——避免用户没注意就替换掉旧本子。
  String _nextName(List<String> existing) {
    if (!existing.contains(kUserDefaultModuleName)) {
      return kUserDefaultModuleName;
    }
    for (var i = 2; i <= kUserPackageMaxPackages + 1; i++) {
      final n = '$kUserDefaultModuleName $i';
      if (!existing.contains(n)) return n;
    }
    return kUserDefaultModuleName;
  }

  Future<void> _loadExistingNames({bool autoPick = false}) async {
    try {
      final progress = Provider.of<ProgressService>(context, listen: false);
      final recs = await UserPackageStore(progress.database).listPackages();
      if (!mounted) return;
      final names = [for (final r in recs) r.moduleName];
      setState(() {
        _existingNames = names;
        if (autoPick && !_nameTouched) {
          _name.text = _nextName(names);
        }
      });
    } catch (_) {
      // 名单读不到不影响添加；保存时库层还会再判一次名额。
    }
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
      setState(() => _dirNote = '文件读不到：$e');
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) {
      _toast('剪贴板里没有文字。先复制一段英文，再回来点这里。');
      return;
    }
    _input.text = text;
    _parse();
  }

  /// 把粘贴的东西整理成一句一句。表格/JSON 自动走原来的表格校验，不硬切句。
  void _parse() {
    final raw = _input.text;
    if (raw.trim().isEmpty) {
      setState(() {
        _result = null;
        _imported = null;
        _saved = false;
        _kindLabel = '';
        _notes = const [];
      });
      return;
    }
    final plan = parsePastedUserText(raw, moduleName: _currentName);
    setState(() {
      _imported = null;
      _saved = false;
      if (plan != null) {
        _result = plan.validation;
        _kindLabel = plan.kindLabel;
        // 第一条是「认出了X，整理成N句」，标题里已经有了，不重复。
        _notes = plan.notes.length > 1 ? plan.notes.sublist(1) : const [];
      } else {
        _result = parseAndValidateUserPackage(raw);
        _kindLabel = '一份表格';
        _notes = const ['看起来是一份表格，我按表格的规矩检查了一遍。'];
      }
    });
  }

  void _onNameChanged(String _) {
    _nameTouched = true;
    if (_result == null) return;
    // 改了本子名，已经整理好的句子要跟着换个归属，直接重整理一遍。
    _parse();
  }

  void _clearResult() {
    setState(() {
      _result = null;
      _imported = null;
      _saved = false;
      _kindLabel = '';
      _notes = const [];
    });
    _toast('没有保存，内容还在上面，改完再点一次「整理成句子」就行。');
  }

  void _startAnother() {
    _nameTouched = false;
    setState(() {
      _input.clear();
      _name.text = _nextName(_existingNames);
      _result = null;
      _imported = null;
      _saved = false;
      _kindLabel = '';
      _notes = const [];
    });
    _toast('换一本新的，接着粘下一批。');
  }

  Future<void> _loadFile(UserPackageFile f) async {
    try {
      final text = await _files.read(f);
      _input.text = text;
      _parse();
      _toast('已读入「${f.name}」');
    } catch (e) {
      _toast('这个文件读不了：$e');
    }
  }

  Future<void> _writeTemplate({required bool json}) async {
    try {
      final p = await _files.writeTemplate(json: json);
      _input.text =
          json ? userPackageJsonTemplate() : userPackageCsvTemplate();
      _parse();
      _toast('示例已经存到手机里：$p');
      await _scanFiles();
    } catch (e) {
      _toast('示例写入失败：$e');
    }
  }

  /// 保存：先过付费门，再用库层唯一写入口落盘，最后直接进练习。
  ///
  /// ASR-233 的口径原样保留：整理和预览免费，墙只在「保存」这一刻。
  /// 未授权 ⇒ 出墙 sheet 后直接 return——不写库、不改 `_saved`、不置 `_busy`。
  Future<void> _save() async {
    final v = _result;
    if (v == null || !v.ok || _busy) return;
    final license = Provider.of<LicenseState>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    final allowed = license.allows(LicenseFeature.customImport);
    if (!allowed) {
      progress.logEvent('custom_import_wall_shown');
      await showLicenseWallSheet(
        context,
        title: '保存到我的英语本需要解锁码',
        detail: '整理和预览一直免费。保存到本机会用一枚解锁码，以前买过的不用再买。'
            '手机上最多 $kUserPackageMaxPackages 个英语本、每本 $kUserPackageMaxChunks 句；'
            '官方内容、学习记录和删除都不受影响。',
      );
      if (!mounted) return;
      if (license.allows(LicenseFeature.customImport)) {
        progress.logEvent('custom_import_wall_to_activate');
        _toast('已经解锁了。再点一次「保存并开始学」就会存进去。');
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final content = Provider.of<ContentPack>(context, listen: false);
      final store = UserPackageStore(progress.database);
      final res = await store.importValidation(v, allowed: allowed);
      if (!res.ok) {
        if (res.gated) progress.logEvent('custom_import_blocked_store');
        if (!mounted) return;
        setState(() => _imported = res);
        _toast(res.note);
        return;
      }
      // 导入是新的台账写入点 → 同帧对账，让断点自愈立刻覆盖这次写入。
      final healed = await ProgressIntegrity.reconcileAll(
        progress,
        content,
        reason: 'user_import',
      );
      if (!mounted) return;
      setState(() {
        _imported = res;
        _saved = true;
      });
      final savedName =
          res.moduleNames.isNotEmpty ? res.moduleNames.first : _currentName;
      await _loadExistingNames();
      if (!mounted) return;
      _toast('存好了：${res.writtenChunks} 句'
          '${healed.healed > 0 ? ' · 顺手归位 ${healed.healed} 处学习记录' : ''}');
      // 顺畅进学习：保存完直接开六步，用户不用再找入口。
      await _openPractice(savedName);
    } catch (e) {
      _toast('没存上：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPractice(String name) async {
    if (!mounted) return;
    final progress = Provider.of<ProgressService>(context, listen: false);
    final rec =
        await UserPackageStore(progress.database).packageOf(userModuleKey(name));
    if (!mounted || rec == null || rec.entries.isEmpty) return;
    await UserPackageDetailScreen.openPractice(context, rec);
  }

  @override
  Widget build(BuildContext context) {
    final v = _result;
    final canParse = _input.text.trim().isNotEmpty && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('添加我的英文本')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          _introCard(),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('userpkg_paste'),
            onPressed: _busy ? null : _pasteFromClipboard,
            icon: Icon(Icons.content_paste_go, color: kOnPrimary, size: 18),
            label: Text('从剪贴板粘贴',
                style: TextStyle(color: kOnPrimary, fontSize: 15)),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('userpkg_input'),
            controller: _input,
            maxLines: 8,
            style: TextStyle(color: kText, fontSize: 14, height: 1.5),
            decoration: InputDecoration(
              hintText: '例如：\n'
                  "A: How's it going?\n"
                  'B: Pretty good, thanks.\n\n'
                  '也可以直接粘一整段英文，或者一行英文一行中文。',
              hintStyle: TextStyle(color: kTextFaint, fontSize: 13, height: 1.5),
              filled: true,
              fillColor: kCard,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onChanged: (_) => setState(() {
              _result = null;
              _imported = null;
              _saved = false;
            }),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('userpkg_name'),
            controller: _name,
            maxLength: kUserFieldMaxModule,
            style: TextStyle(color: kText, fontSize: 14),
            decoration: InputDecoration(
              labelText: '这本叫什么',
              labelStyle: TextStyle(color: kTextMuted, fontSize: 13),
              helperText: '可以不改。同一个名字再存一次，会替换掉之前那一本。',
              helperStyle: TextStyle(color: kTextFaint, fontSize: 11),
              filled: true,
              fillColor: kCard,
              counterStyle: TextStyle(color: kTextFaint, fontSize: 10),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onChanged: _onNameChanged,
          ),
          Text('一本最多 $kUserPackageMaxChunks 句，手机上最多 '
              '$kUserPackageMaxPackages 本；存不下的先学完再删。',
              style: TextStyle(color: kTextFaint, fontSize: 11, height: 1.4)),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('userpkg_parse'),
            onPressed: canParse ? _parse : null,
            child: Text('整理成句子',
                style: TextStyle(color: kOnPrimary, fontSize: 15)),
          ),
          if (v != null) ...[
            const SizedBox(height: 18),
            _resultHeader(v),
            const SizedBox(height: 8),
            UserPreviewBody(result: v, previewOnly: false),
            if (_notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final n in _notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('· $n',
                      style: TextStyle(
                          color: kTextMuted, fontSize: 12, height: 1.45)),
                ),
            ],
            const SizedBox(height: 12),
            if (v.ok && !_saved)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                        onPressed: _busy ? null : _clearResult,
                        child: Text('先不存',
                            style: TextStyle(color: kTextMuted))),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                        key: const Key('userpkg_save'),
                        onPressed: _busy ? null : _save,
                        icon: Icon(Icons.play_arrow_rounded,
                            color: kOnPrimary, size: 20),
                        label: Text('保存并开始学',
                            style: TextStyle(color: kOnPrimary, fontSize: 15))),
                  ),
                ],
              ),
            if (!v.ok)
              Text('按上面的行号改一下，改好之前一句都不会存。',
                  style: TextStyle(
                      color: kTextSecondary, fontSize: 12, height: 1.45)),
          ],
          if (_imported != null) _savedBanner(_imported!),
          const SizedBox(height: 18),
          _advancedSection(),
          const SizedBox(height: 6),
          TextButton(
              onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        // 已经粘过的原文带过去：预览页直接排好，不用让人再粘一次。
                        builder: (_) =>
                            UserPreviewScreen(initialText: _input.text)),
                  ),
              child: Text('只想先看看整理结果（不会保存）',
                  style: TextStyle(color: kPrimary, fontSize: 13))),
          TextButton(
              onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const UserImportFeedbackScreen()),
                  ),
              child: Text('六项体验清单（填完给开发者）',
                  style: TextStyle(color: kPrimary, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _introCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kPrimary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('把想学的英文粘进来',
              style: TextStyle(
                  color: kText, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            '一句、一段、一段对话都行。我按句子帮你排好，'
            '你有中文就一起带上；没有中文也能学，只是练习时不显示翻译。\n'
            '整理和预览不要钱，存进本子时才需要解锁码（以前买过的不用再买）。',
            style:
                TextStyle(color: kTextSecondary, fontSize: 12.5, height: 1.55),
          ),
        ],
      ),
    );
  }

  Widget _resultHeader(UserPackageValidation v) {
    final ok = v.ok;
    return Row(
      children: [
        Icon(ok ? Icons.check_circle : Icons.error_outline,
            size: 16, color: ok ? kPrimary : Colors.redAccent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ok
                ? '整理好了${_kindLabel.isEmpty ? '' : ' · $_kindLabel'}'
                : '有地方要看看${_kindLabel.isEmpty ? '' : ' · $_kindLabel'}',
            style: TextStyle(
                color: ok ? kText : Colors.redAccent,
                fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _savedBanner(UserImportResult r) {
    final name = r.moduleNames.isNotEmpty ? r.moduleNames.first : _currentName;
    if (!r.ok) {
      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: kCard, borderRadius: BorderRadius.circular(12)),
        child: Text('没存上：${r.note}',
            style: TextStyle(color: kTextSecondary, fontSize: 12.5)),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kSuccess.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('已经存进「$name」',
              style: TextStyle(
                  color: kSuccess, fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              '共 ${r.writtenChunks} 句，手机上现在有 ${r.packagesAfter}/'
              '$kUserPackageMaxPackages 个英语本。官方内容和学习记录没有变。',
              style:
                  TextStyle(color: kTextSecondary, fontSize: 12, height: 1.45)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: _startAnother,
                    child: Text('再添一批',
                        style: TextStyle(color: kTextMuted, fontSize: 13))),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                    onPressed: _busy ? null : () => _openPractice(name),
                    icon: Icon(Icons.play_arrow_rounded,
                        color: kOnPrimary, size: 20),
                    label: Text('继续练习',
                        style: TextStyle(color: kOnPrimary, fontSize: 14))),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 表格 / 文件 / 模板：给「已经从电脑上存好文件」的人留的后门，默认收起。
  Widget _advancedSection() {
    // 用 Material 而不是带底色的 Container：ListTile 的点击水波要画在 Material 上，
    // 夹一层 DecoratedBox 会被 Flutter 断言拦下。
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const Key('userpkg_advanced'),
        initiallyExpanded: _advancedOpen,
        onExpansionChanged: (v) => _advancedOpen = v,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        iconColor: kTextMuted,
        collapsedIconColor: kTextMuted,
        title: Text('我以前存过表格或文件',
            style: TextStyle(color: kTextSecondary, fontSize: 13)),
        subtitle: Text('一般用不到，直接粘贴最省事',
            style: TextStyle(color: kTextFaint, fontSize: 11)),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                  onPressed: () => _writeTemplate(json: false),
                  child: Text('下载示例表格（CSV）',
                      style: TextStyle(color: kText, fontSize: 12))),
              OutlinedButton(
                  onPressed: () => _writeTemplate(json: true),
                  child: Text('下载示例文件（JSON）',
                      style: TextStyle(color: kText, fontSize: 12))),
            ],
          ),
          const SizedBox(height: 8),
          Text('示例可以用 Excel 或 WPS 打开，照着填几行，再放回手机的这个文件夹。',
              style:
                  TextStyle(color: kTextMuted, fontSize: 11.5, height: 1.45)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('手机里的文件',
                    style: TextStyle(
                        color: kTextSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
              TextButton(
                  onPressed: _busy ? null : _scanFiles,
                  child: Text('刷新', style: TextStyle(color: kPrimary))),
            ],
          ),
          Text(_dirNote.isEmpty ? '文件夹准备中…' : '文件夹：$_dirNote',
              style: TextStyle(color: kTextFaint, fontSize: 10)),
          if (_found.isEmpty)
            Text('还没有现成的文件。也可以不下载，直接在上面粘贴文字。',
                style: TextStyle(color: kTextMuted, fontSize: 11.5))
          else
            for (final f in _found.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(f.name,
                    style: TextStyle(color: kText, fontSize: 12.5)),
                subtitle: Text('${f.sizeText} · ${f.modified}',
                    style: TextStyle(color: kTextFaint, fontSize: 10.5)),
                trailing: TextButton(
                    onPressed: () => _loadFile(f),
                    child: Text('用这份', style: TextStyle(color: kPrimary))),
              ),
        ],
      ),
    );
  }
}

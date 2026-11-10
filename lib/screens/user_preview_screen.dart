import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/user_package.dart';
import '../services/user_text_parser.dart';
import '../ui/theme.dart';

/// 「先看看整理结果」（1.9.2）。
///
/// 四红线（结构性，不靠自觉）：
///  1. **零 DB 写入** —— 本文件不 import 任何 store/db/provider，只吃字符串与纯函数；
///  2. **零进度触碰** —— 同上，页面里没有任何能改状态的通路；
///  3. 不合 main、不动 version.json（发版侧约束，见分支 dev/1.9.0-userpack）；
///  4. 「只是看看，不会保存」字样在 UI 上，且有钉测（说人话，不用「落库」这类词）。
///
/// 预览主体 [UserPreviewBody] 就是添加页的「确认步」：同一组件、同一套校验，
/// 两边只有底部说明不同（这里永远不写，添加页写 `user:` 命名空间）。
class UserPreviewScreen extends StatefulWidget {
  const UserPreviewScreen({super.key, this.initialText = ''});

  /// 从添加页带过来的原文：用户已经粘过一次，不该让他再粘第二次。
  final String initialText;

  @override
  State<UserPreviewScreen> createState() => _UserPreviewScreenState();
}

class _UserPreviewScreenState extends State<UserPreviewScreen> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initialText);
  UserPackageValidation? _result;

  @override
  void initState() {
    super.initState();
    // 带原文进来就直接排好，用户点开就能看到自己那几句。
    if (widget.initialText.trim().isNotEmpty) _parse();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _parse() {
    final raw = _input.text;
    final plan = parsePastedUserText(raw);
    setState(() => _result = plan?.validation ?? parseAndValidateUserPackage(raw));
  }

  void _fill(String text) {
    _input.text = text;
    _parse();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('先看看整理结果')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 红线 4：这句必须在屏上，被 widget 测试钉住。说人话，不用「落库」。
          Text('这一页只是看看，不会保存 —— 不动你的学习记录，也不影响官方内容。',
              style: TextStyle(color: Colors.orange.shade300, fontSize: 13, height: 1.5)),
          const SizedBox(height: 16),
          Text(
              widget.initialText.trim().isEmpty
                  ? '把英文粘进来，看看我会怎么分句'
                  : '这就是你刚粘进来的内容，我按句子排好了',
              style: TextStyle(color: kText, fontSize: 15)),
          const SizedBox(height: 8),
          TextField(
            controller: _input,
            maxLines: 8,
            style: TextStyle(color: kText, fontSize: 14, height: 1.5),
            decoration: InputDecoration(
              hintText: '一句、一段、一段对话，或者中英文对照都行。',
              hintStyle: TextStyle(color: kTextFaint, fontSize: 13),
              filled: true,
              fillColor: kCard,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                  onPressed: () => _fill(userPackageCsvTemplate()),
                  child: Text('看看示例表格',
                      style: TextStyle(color: kText, fontSize: 12))),
              OutlinedButton(
                  onPressed: () => _fill(userPackageJsonTemplate()),
                  child: Text('看看示例文件',
                      style: TextStyle(color: kText, fontSize: 12))),
              FilledButton(
                  onPressed: _parse,
                  child: Text('整理一下',
                      style: TextStyle(color: kOnPrimary, fontSize: 13))),
            ],
          ),
          const SizedBox(height: 18),
          if (_result != null) UserPreviewBody(result: _result!),
          const SizedBox(height: 18),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const UserImportFeedbackScreen()),
            ),
            child: Text('六项体验清单（填完给开发者）',
                style: TextStyle(color: kPrimary, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// 预览主体 = 添加页确认步的同一组件。
///
/// [previewOnly] 决定名额那一行怎么说：
///  - true（预览页）：这一版确实不存，也就不占地方；
///  - false（添加页）：保存后就要占名额了，不能再写「不占」。
class UserPreviewBody extends StatelessWidget {
  final UserPackageValidation result;
  final bool previewOnly;
  const UserPreviewBody(
      {super.key, required this.result, this.previewOnly = true});

  @override
  Widget build(BuildContext context) {
    final entries = result.entries;
    final modules = <String>{for (final e in entries) e.moduleName};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: kCard, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.ok
                    ? '可以了：${entries.length} 句'
                    : '还有 ${result.issues.length} 处要看看，改好之前一句都不会保存',
                style: TextStyle(
                    color: result.ok ? kPrimary : Colors.redAccent,
                    fontSize: 14,
                    height: 1.4),
              ),
              if (modules.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('放进「${modules.join('、')}」',
                    style: TextStyle(color: kTextSecondary, fontSize: 12)),
              ],
              const SizedBox(height: 4),
              Text(
                  previewOnly
                      ? '一本最多 $kUserPackageMaxChunks 句，手机上最多 '
                          '$kUserPackageMaxPackages 本。这一页只看不存，不占地方。'
                      : '一本最多 $kUserPackageMaxChunks 句，手机上最多 '
                          '$kUserPackageMaxPackages 本；同名再存一次会替换之前那一本。',
                  style: TextStyle(color: kTextFaint, fontSize: 11, height: 1.45)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (!result.ok)
          for (final issue in result.issues.take(20))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('· ${describeIssueForLearner(issue)}',
                  style: TextStyle(color: kTextSecondary, fontSize: 12, height: 1.4)),
            ),
        if (!result.ok && result.issues.length > 20)
          Text('…另有 ${result.issues.length - 20} 处',
              style: TextStyle(color: kTextFaint, fontSize: 12)),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('大概会这样排', style: TextStyle(color: kText, fontSize: 14)),
          const SizedBox(height: 6),
          for (final e in entries.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                  e.back.trim().isEmpty
                      ? '${e.front}  ·  还没有中文意思'
                      : '${e.front}  ·  ${e.back}',
                  style: TextStyle(color: kTextSecondary, fontSize: 12, height: 1.4)),
            ),
        ],
      ],
    );
  }
}

/// 六项体验清单：填完一键复制，作为自定义导入的可用性反馈入档。
class UserImportFeedbackScreen extends StatefulWidget {
  const UserImportFeedbackScreen({super.key});

  /// 六项体验清单的题目（可用性输入的固定口径，测试钉条数）。
  static const List<String> questions = [
    '1. 粘贴顺手吗？（从微信/文档复制过来，能不能直接用）',
    '2. 分句合不合心意？（有没有被切错、漏掉）',
    '3. 中文意思对不对？（你自己带的中文有没有放对位置）',
    '4. 没中文的句子，练起来会不会别扭？',
    '5. 保存后直接开始学，这个顺序顺不顺？',
    '6. 还愿不愿意把自己的句子里存进来？为什么？',
  ];

  @override
  State<UserImportFeedbackScreen> createState() =>
      _UserImportFeedbackScreenState();
}

class _UserImportFeedbackScreenState extends State<UserImportFeedbackScreen> {
  List<String> get questions => UserImportFeedbackScreen.questions;
  final List<TextEditingController> _answers =
      List.generate(UserImportFeedbackScreen.questions.length,
          (_) => TextEditingController());

  @override
  void dispose() {
    for (final c in _answers) {
      c.dispose();
    }
    super.dispose();
  }

  String compose() {
    final lines = <String>['自定义导入 · 六项体验回执'];
    for (var i = 0; i < questions.length; i++) {
      lines.add('${questions[i]}：${_answers[i].text.trim()}');
    }
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('六项体验清单')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('这一页只是收集你的意见：不会保存任何句子，也不动学习记录。填完复制给开发者就行。',
              style: TextStyle(color: kTextFaint, fontSize: 12, height: 1.45)),
          const SizedBox(height: 14),
          for (var i = 0; i < questions.length; i++) ...[
            Text(questions[i], style: TextStyle(color: kText, fontSize: 14)),
            const SizedBox(height: 6),
            TextField(
              controller: _answers[i],
              maxLines: 2,
              style: TextStyle(color: kText, fontSize: 13),
              decoration: InputDecoration(
                  filled: true,
                  fillColor: kCard,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10))),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: compose()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('六项回执已复制，直接粘贴给开发者')));
            },
            child: const Text('复制六项回执'),
          ),
        ],
      ),
    );
  }
}

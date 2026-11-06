import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/user_package.dart';
import '../ui/theme.dart';

/// ASR-215 小片 · 自定义词块包「只预览，不落库」。
///
/// 四红线（结构性，不靠自觉）：
///  1. **零 DB 写入** —— 本文件不 import 任何 store/db/provider，只吃字符串与纯函数；
///  2. **零进度触碰** —— 同上，页面里没有任何能改状态的通路；
///  3. 不合 main、不动 version.json（发版侧约束，见分支 dev/1.9.0-userpack）；
///  4. 「只预览，不落库」字样在 UI 上，且有钉测。
///
/// 预览主体 [UserPreviewBody] 就是 D3 的「导入确认步」：同一组件，D3 时只把底部
/// 说明换成「确认导入（将写入本机）」并接 store，不重写第二份。
class UserPreviewScreen extends StatefulWidget {
  const UserPreviewScreen({super.key});

  @override
  State<UserPreviewScreen> createState() => _UserPreviewScreenState();
}

class _UserPreviewScreenState extends State<UserPreviewScreen> {
  final TextEditingController _input = TextEditingController();
  UserPackageValidation? _result;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _parse() {
    setState(() => _result = parseAndValidateUserPackage(_input.text));
  }

  void _fill(String text) {
    setState(() {
      _input.text = text;
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的模块 · 导入预览')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 红线 4：这句必须在屏上，被 widget 测试钉住。
          Text('只预览，不落库 —— 这一步不写入任何进度，也不影响官方模块。',
              style: TextStyle(color: Colors.orange.shade300, fontSize: 13)),
          const SizedBox(height: 16),
          Text('把 CSV 或 JSON 的内容粘贴进来',
              style: TextStyle(color: kText, fontSize: 15)),
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
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                  onPressed: () => _fill(userPackageCsvTemplate()),
                  child: Text('填入 CSV 模板', style: TextStyle(color: kText))),
              OutlinedButton(
                  onPressed: () => _fill(userPackageJsonTemplate()),
                  child: Text('填入 JSON 模板', style: TextStyle(color: kText))),
              FilledButton(
                  onPressed: _parse,
                  child:
                      Text('解析并预览', style: TextStyle(color: kOnPrimary))),
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
            child: Text('六项体验清单（填完复制给开发者）',
                style: TextStyle(color: kPrimary)),
          ),
        ],
      ),
    );
  }
}

/// 预览主体 = D3 导入确认步的同一组件。
class UserPreviewBody extends StatelessWidget {
  final UserPackageValidation result;
  const UserPreviewBody({super.key, required this.result});

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
                    ? '校验通过：${entries.length} 块 · ${modules.length} 个模块'
                    : '未过闸：${result.issues.length} 处问题，本包一行都不会写入',
                style: TextStyle(
                    color: result.ok ? kPrimary : Colors.redAccent,
                    fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text('模块：${modules.join('、')}',
                  style: TextStyle(color: kTextSecondary, fontSize: 12)),
              const SizedBox(height: 4),
              Text(
                  '上限：每包 $kUserPackageMaxChunks 块 · 每台设备 '
                  '$kUserPackageMaxPackages 包（本版只预览，不占名额）',
                  style: TextStyle(color: kTextFaint, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (!result.ok)
          for (final issue in result.issues.take(20))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('· $issue',
                  style: TextStyle(color: kTextSecondary, fontSize: 12)),
            ),
        if (!result.ok && result.issues.length > 20)
          Text('…另有 ${result.issues.length - 20} 处',
              style: TextStyle(color: kTextFaint, fontSize: 12)),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('前 ${entries.length < 5 ? entries.length : 5} 行示例',
              style: TextStyle(color: kText, fontSize: 14)),
          const SizedBox(height: 6),
          for (final e in entries.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                  '${e.front}  →  ${e.back}'
                  '${e.cefr == null ? '' : '  ·  ${e.cefr}'}'
                  '${e.hasSentenceForSpeakingSteps ? '' : '  ·  无整句，跟读类步骤将置灰'}',
                  style: TextStyle(color: kTextSecondary, fontSize: 12)),
            ),
        ],
      ],
    );
  }
}

/// 六项体验清单：填完一键复制，作为 D3 可用性输入入档。
class UserImportFeedbackScreen extends StatefulWidget {
  const UserImportFeedbackScreen({super.key});

  /// 六项体验清单的题目（D3 可用性输入的固定口径，测试钉条数）。
  static const List<String> questions = [
    '1. 模板下载顺手度（能不能一眼拿到、字段看得懂吗）',
    '2. 粘贴摩擦（从 Excel/WPS 复制过来要改几处）',
    '3. 报错可懂度（第 N 行·字段·原因，够不够定位）',
    '4. 字段够不够（front/back/module_name/phonetic/example/cefr/tags 缺哪个）',
    '5. 200 块上限提示（超限时是否明白为什么、下一步做什么）',
    '6. 想不想用（愿意导入自己的词表吗，为什么）',
  ];

  @override
  State<UserImportFeedbackScreen> createState() =>
      _UserImportFeedbackScreenState();
}

class _UserImportFeedbackScreenState extends State<UserImportFeedbackScreen> {

  List<String> get questions => UserImportFeedbackScreen.questions;
  final List<TextEditingController> _answers =
      List.generate(questions.length, (_) => TextEditingController());

  @override
  void dispose() {
    for (final c in _answers) {
      c.dispose();
    }
    super.dispose();
  }

  String compose() {
    final lines = <String>['自定义导入小片 · 六项体验回执（只预览不落库版）'];
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
          Text('这一版只做预览：不写库、不碰进度。反馈是给 D3 落库版的可用性输入。',
              style: TextStyle(color: kTextFaint, fontSize: 12)),
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

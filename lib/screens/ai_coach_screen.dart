import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chunkspoke_flutter/services/loaders.dart';
import 'package:chunkspoke_flutter/services/ai_coach.dart';
import 'package:chunkspoke_flutter/services/llm_provider.dart';
import 'package:chunkspoke_flutter/models/content_pack.dart';
import 'package:chunkspoke_flutter/ui/theme.dart';

class AiCoachScreen extends StatefulWidget {
  const AiCoachScreen({super.key});
  @override
  State<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState extends State<AiCoachScreen> {
  late final AiCoach _coach;
  bool _busy = false;
  String? _weekly;
  List<DayPlan>? _plan;
  Map<String, String>? _variant;
  List<String> _vOrder = [];
  bool? _vOk;
  String? _variantMsg;

  @override
  void initState() {
    super.initState();
    _coach = AiCoach(Provider.of<ProgressService>(context, listen: false));
  }

  /// 当前生效服务来源横幅（常驻可用态；降级时给予中性提示，不阻塞）。
  Widget _statusBanner(ProgressService p) {
    final provider = LlmProvider(p);
    final String text;
    final Color color;
    if (provider.customEnabled) {
      text = 'AI 服务：${p.customLlmModel ?? '自定义模型'}';
      color = kUnlocked;
    } else {
      text = '本地统计模式（未配置 AI，可在设置高级中填 GLM Key）';
      color = Colors.white54;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Provider.of<ProgressService>(context);
    final content = Provider.of<ContentPack>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('AI 助手')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusBanner(p),
          const SizedBox(height: 14),
          _card('智能周报', '汇总开口句数 / 平均分 / 卡壳词块 / 薄弱场景，生成诊断与建议',
              _weekly == null
                  ? const Text('尚未生成', style: TextStyle(color: Colors.white54))
                  : Text(_weekly!, style: const TextStyle(color: kText)),
              _busy
                  ? const CircularProgressIndicator(color: kPrimary)
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                      onPressed: () => _genWeekly(p, content),
                      child: const Text('生成周报',
                          style: TextStyle(color: Colors.black87)),
                    )),
          const SizedBox(height: 14),
          _card('7 天学习计划', '依据到期复习与新学词块，生成本周每日安排（新学每日 ≤5）',
              _plan == null
                  ? const Text('尚未生成', style: TextStyle(color: Colors.white54))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final d in _plan!)
                          Text(
                            '${_wd(d.day.weekday)} ${d.day.month}/${d.day.day}：复习 ${d.reviewCount} · 新学 ${d.newCount}',
                            style: const TextStyle(color: kText),
                          ),
                      ],
                    ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: () => _genPlan(p, content),
                child: const Text('查看计划',
                    style: TextStyle(color: Colors.black87)),
              )),
          const SizedBox(height: 14),
          _variantCard(p, content),
        ],
      ),
    );
  }

  Widget _card(String title, String sub, Widget body, Widget action) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: kPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(sub, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 10),
            body,
            const SizedBox(height: 10),
            action,
          ],
        ),
      );

  Widget _variantCard(ProgressService p, ContentPack c) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('变式造句', style: TextStyle(color: kPrimary, fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('从已掌握词块取 2 个，AI 给新场景提示，拖词块重组作答（判定复用 L2 逻辑）',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 10),
            if (_variant == null)
              _variantMsg != null
                  ? Text(_variantMsg!, style: const TextStyle(color: kError))
                  : _busy
                      ? const CircularProgressIndicator(color: kPrimary)
                      : ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                          onPressed: () => _genVariant(p, c),
                          child: const Text('来一道',
                              style: TextStyle(color: Colors.black87)),
                        )
            else ...[
              Text(_variant!['cn_prompt'] ?? '',
                  style: const TextStyle(color: kText, fontSize: 15)),
              const SizedBox(height: 10),
              const Text('点击下方词块，按顺序组成句子：',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!_vOrder.contains(_variant!['a']!))
                    _chip(_variant!['a']!, () => _push(_variant!['a']!)),
                  if (!_vOrder.contains(_variant!['b']!))
                    _chip(_variant!['b']!, () => _push(_variant!['b']!)),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: _vOrder
                    .map((w) => _chip(w, () => _pop(w), on: true))
                    .toList(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                    onPressed: _vOrder.length == 2 ? _checkVariant : null,
                    child: const Text('提交',
                        style: TextStyle(color: Colors.black87)),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: () => setState(() {
                      _variant = null;
                      _vOrder = [];
                      _vOk = null;
                    }),
                    child: const Text('换一题', style: TextStyle(color: kPrimary)),
                  ),
                  if (_vOk != null) ...[
                    const SizedBox(width: 10),
                    Text(_vOk! ? '✓ 正确' : '✗ 顺序不对',
                        style: TextStyle(
                            color: _vOk! ? kUnlocked : kError)),
                  ],
                ],
              ),
            ],
          ],
        ),
      );

  Widget _chip(String label, VoidCallback onTap, {bool on = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: on ? kPrimary : kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kPrimary.withValues(alpha: 0.5)),
          ),
          child: Text(label,
              style: TextStyle(color: on ? Colors.black87 : kText)),
        ),
      );

  void _push(String w) => setState(() => _vOrder.add(w));
  void _pop(String w) => setState(() => _vOrder.remove(w));

  void _checkVariant() {
    final a = _variant!['a']!, b = _variant!['b']!;
    final t = (_variant!['target'] ?? '').toLowerCase();
    final aFirst = t.indexOf(a.toLowerCase()) <= t.indexOf(b.toLowerCase());
    final expect = aFirst ? [a, b] : [b, a];
    setState(() => _vOk = _vOrder.join(' ') == expect.join(' '));
  }

  String _wd(int d) =>
      ['一', '二', '三', '四', '五', '六', '日'][(d - 1) % 7];

  Future<void> _genWeekly(ProgressService p, ContentPack c) async {
    setState(() => _busy = true);
    final r = await _coach.weeklyReport(p, c);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _weekly = r ?? 'AI 暂时不可用（已静默降级，不影响主流程）。';
    });
  }

  Future<void> _genPlan(ProgressService p, ContentPack c) async {
    final plan = await _coach.studyPlan(p, c);
    if (!mounted) return;
    setState(() => _plan = plan);
  }

  Future<void> _genVariant(ProgressService p, ContentPack c) async {
    setState(() => _busy = true);
    final v = await _coach.variantTask(p, c);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _variant = v;
      _vOrder = [];
      _vOk = null;
      _variantMsg = v == null
          ? 'AI 暂时不可用（已静默降级，不影响主流程）。'
          : null;
    });
  }
}

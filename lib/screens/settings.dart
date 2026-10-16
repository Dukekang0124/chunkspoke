import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/loaders.dart';
import '../services/update_service.dart';
import '../services/update/update_flow.dart';
import '../services/llm_provider.dart';
import '../services/builtin_llm.dart';
import '../services/vosk_engine.dart';
import '../ui/theme.dart';
import 'ai_coach_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _key;
  late final TextEditingController _region;
  // 自定义 LLM 层
  late final TextEditingController _customUrl;
  late final TextEditingController _customModel;
  late final TextEditingController _customKey;
  bool _customOn = false;
  bool _testing = false;
  String? _testMsg;
  bool? _testOk;
  String _ver = '1.0.0';
  EngineState _engineState = EngineState.unknown;

  @override
  void initState() {
    super.initState();
    final p = Provider.of<ProgressService>(context, listen: false);
    _key = TextEditingController(text: p.azureKey ?? '');
    _region = TextEditingController(text: p.azureRegion ?? '');
    _customOn = p.customLlmEnabled;
    _customUrl = TextEditingController(text: p.customLlmUrl ?? '');
    _customModel = TextEditingController(text: p.customLlmModel ?? '');
    _customKey = TextEditingController(text: p.customLlmKey ?? '');
    // 异步初始化全部兜底：失败不阻塞设置页渲染，更不允许未捕获异常（P0 加固）。
    UpdateService().local().then((v) {
      if (mounted) setState(() => _ver = v.version);
    }).catchError((_) {
      // 本地版本读取失败 → 保持默认显示，不阻塞。
    });
    // 设置页零资产读取：仅用内存标志 + 磁盘目录存在性推断引擎状态，
    // 绝不触发 41MB 模型加载（避免低端机内存尖峰退桌面，P0 根因设计移除）。
    SpeechEngine.modelOnDisk().then((onDisk) {
      if (!mounted) return;
      setState(() => _engineState = SpeechEngine.instance.isLoaded
          ? EngineState.ready
          : onDisk
              ? EngineState.ready
              : EngineState.unknown);
    }).catchError((_) {
      // 目录检查失败 → 退回未知，不阻塞设置页。
      if (mounted) setState(() => _engineState = EngineState.unknown);
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _region.dispose();
    _customUrl.dispose();
    _customModel.dispose();
    _customKey.dispose();
    super.dispose();
  }

  void _save() {
    final p = Provider.of<ProgressService>(context, listen: false);
    final k = _key.text.trim();
    final r = _region.text.trim();
    p.setAzureKey(k.isEmpty ? null : k);
    p.setAzureRegion(r.isEmpty ? null : r);
    // 自定义 LLM 层
    p.setCustomLlmEnabled(_customOn);
    p.setCustomLlmUrl(_customUrl.text.trim().isEmpty ? null : _customUrl.text.trim());
    p.setCustomLlmModel(_customModel.text.trim().isEmpty ? null : _customModel.text.trim());
    p.setCustomLlmKey(_customKey.text.trim().isEmpty ? null : _customKey.text.trim());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _testConnection() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    // 先落地当前自定义字段，再测试（不弹保存提示，仅验证连通性）。
    p.setCustomLlmEnabled(true);
    p.setCustomLlmUrl(_customUrl.text.trim().isEmpty ? null : _customUrl.text.trim());
    p.setCustomLlmModel(_customModel.text.trim().isEmpty ? null : _customModel.text.trim());
    p.setCustomLlmKey(_customKey.text.trim().isEmpty ? null : _customKey.text.trim());
    setState(() {
      _testing = true;
      _testMsg = null;
      _testOk = null;
    });
    final r = await LlmProvider(p).testCustom();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = r.ok;
      _testMsg = r.ok ? '已连接：${r.reason}' : r.reason;
    });
  }

  Future<void> _clearCustom() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    await p.clearCustomLlm();
    _customUrl.clear();
    _customModel.clear();
    _customKey.clear();
    setState(() {
      _customOn = false;
      _testMsg = null;
      _testOk = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清除自定义配置，回落内置服务'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _checkUpdate() async {
    // 统一走更新全流程：弹窗 → 下载 → SHA-256 校验 → 安装 / 权限引导。
    await runUpdateFlow(context);
  }

  /// AI 助手入口：常驻显示，依据当前生效服务展示状态（不再因无 Key 隐藏）。
  Widget _aiCoachEntry(BuildContext context) {
    final p = Provider.of<ProgressService>(context, listen: false);
    final provider = LlmProvider(p);
    final String status;
    final Color statusColor;
    if (provider.builtinUnavailable) {
      status = '内置 AI 服务暂不可用（已降级本地）';
      statusColor = kError;
    } else if (provider.customEnabled) {
      status = '已开启（自定义：${p.customLlmModel ?? '未命名模型'}）';
      statusColor = kUnlocked;
    } else if (hasBuiltin()) {
      status = '已开启（内置服务）';
      statusColor = kUnlocked;
    } else {
      status = '本地降级（无内置密钥，可在高级中配置自定义模型）';
      statusColor = Colors.white54;
    }
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPrimary.withOpacity(0.4)),
      ),
      // Material(transparency)：DecoratedBox 背景色与 ListTile 之间的 Material 锚点
      // （tileColor 不足以消除「水波纹不可见」断言）。
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: const Icon(Icons.auto_awesome, color: kPrimary),
          title: const Text('AI 助手', style: TextStyle(color: kText)),
          subtitle: Text(status,
              style: TextStyle(color: statusColor, fontSize: 12)),
          trailing: const Icon(Icons.arrow_forward_ios,
              size: 16, color: Colors.white38),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AiCoachScreen()),
          ),
        ),
      ),
    );
  }

  /// 识别引擎状态可见：就绪 / 首次开口自动加载（轻量，零资产）/ 初始化失败。
  Widget _engineRow() {
    final (text, color) = switch (_engineState) {
      EngineState.ready => ('识别引擎：离线引擎已就绪（Vosk）', kUnlocked),
      EngineState.failed => ('识别引擎初始化失败，重启应用或反馈', kError),
      EngineState.loading => ('识别引擎：准备中…', Colors.white54),
      EngineState.unknown =>
        ('识别引擎：首次开口自动加载（离线）', Colors.white54),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(
            _engineState == EngineState.ready
                ? Icons.graphic_eq
                : _engineState == EngineState.failed
                    ? Icons.error_outline
                    : Icons.hourglass_empty,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) =>
      Text(t, style: const TextStyle(color: Colors.white70, fontSize: 14));

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: const Color(0xFF1A1A2E),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label('Azure 语音密钥'),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: _dec('粘贴密钥（可选）'),
            ),
            const SizedBox(height: 12),
            _label('Azure 区域'),
            const SizedBox(height: 8),
            TextField(
              controller: _region,
              style: const TextStyle(color: Colors.white),
              decoration: _dec('例如 eastasia（可选）'),
            ),
            const SizedBox(height: 16),
            _engineRow(),
            const SizedBox(height: 20),

            // —— AI 助手：常驻入口 ——
            _aiCoachEntry(context),
            const SizedBox(height: 14),
            _advancedCard(context),
            const SizedBox(height: 20),

            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
                onPressed: _save,
                child: const Text('保存', style: TextStyle(color: Colors.white)),
              ),
            ),
            const SizedBox(height: 20),
            const Divider(color: Colors.white12),
            _label('应用更新'),
            const SizedBox(height: 6),
            const Text('更新源已内置，无需配置。',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _checkUpdate,
                child: const Text('检查更新', style: TextStyle(color: Colors.white70)),
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: Text('ChunkSpoke v$_ver',
                  style: const TextStyle(color: Colors.white38)),
            ),
          ],
        ),
      ),
    );
  }

  /// 「高级」折叠区：自定义模型开关 + 三输入框 + 测试连接 + 清除配置。
  Widget _advancedCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      // Material(transparency)：在背景 DecoratedBox 与 ExpansionTile 内部 ListTile
      // 之间提供 Material 锚点，消除「水波纹不可见」断言（对 debug/测试有效）。
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: _customOn,
          title: const Text('高级', style: TextStyle(color: kText, fontSize: 15)),
          subtitle: const Text('自定义 AI 模型（OpenAI 兼容，默认关）',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          childrenPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用自定义模型', style: TextStyle(color: kText)),
              subtitle: const Text('开启后优先级高于内置服务；关闭即回落内置',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: _customOn,
              activeColor: kPrimary,
              onChanged: (v) => setState(() => _customOn = v),
            ),
            if (_customOn) ...[
              _label('接口地址'),
              const SizedBox(height: 6),
              TextField(
                controller: _customUrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: _dec('https://open.bigmodel.cn/api/paas/v4'),
              ),
              const SizedBox(height: 10),
              _label('模型名'),
              const SizedBox(height: 6),
              TextField(
                controller: _customModel,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: _dec('例如 glm-4-flash'),
              ),
              const SizedBox(height: 10),
              _label('API Key'),
              const SizedBox(height: 6),
              TextField(
                controller: _customKey,
                obscureText: true,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: _dec('粘贴自定义服务 Key'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton(
                    style:
                        ElevatedButton.styleFrom(backgroundColor: kPrimary),
                    onPressed: _testing ? null : _testConnection,
                    child: _testing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black87),
                          )
                        : const Text('测试连接',
                            style: TextStyle(color: Colors.black87)),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _clearCustom,
                    child: const Text('清除自定义配置',
                        style: TextStyle(color: kPrimary)),
                  ),
                ],
              ),
              if (_testMsg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_testMsg!,
                      style: TextStyle(
                          color: _testOk == true ? kUnlocked : kError,
                          fontSize: 13)),
                ),
              const SizedBox(height: 8),
              const Text(
                '自定义 Key / 模型名永不写入日志；清除后回落内置服务。',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ],
        ),
        ),
      ),
    );
  }
}

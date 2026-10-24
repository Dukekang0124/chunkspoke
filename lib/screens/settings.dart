import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/loaders.dart';
import '../services/update/update_service.dart';
import '../services/update/update_flow.dart';
import '../services/llm_provider.dart';
import '../services/builtin_llm.dart';
import '../services/hd_voice.dart';
import '../services/vosk_engine.dart';
import '../services/vosk_model.dart';
import '../services/tts_voice.dart';
import '../services/notification_service.dart';
import '../services/recording.dart';
import '../services/review_notify.dart';
import '../ui/sheet.dart';
import '../ui/permission_preprompt.dart';
import '../ui/theme.dart';
import '../ui/feedback.dart';
import 'ai_coach_screen.dart';
import 'legal_screen.dart';
import 'listening_debug.dart';
import 'tts_guide.dart';

const bool _kListeningPreview = bool.fromEnvironment('LISTENING_PREVIEW');

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
  bool _notifOn = false;
  bool _reviewNotifOn = false;
  int _notifHour = 20;
  int _notifMinute = 0;
  bool _soundOn = true; // B7：音效开关（震动跟随系统，无独立开关）
  bool _aiNetOn = true; // 隐私：AI 联网点评开关（关闭后自由造句只用本机规则引擎）
  TtsStatus _ttsStatus = TtsStatus.unknown; // 语音朗读检测状态（可从这里再次修复）
  bool _hdPreviewing = false;

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
    _notifOn = p.notifEnabled;
    _reviewNotifOn = p.reviewNotifEnabled;
    _notifHour = p.notifHour;
    _notifMinute = p.notifMinute;
    _soundOn = p.soundOn;
    _aiNetOn = p.aiNetOn;
    final tts = Provider.of<TtsService>(context, listen: false);
    _ttsStatus = tts.status;
    if (_ttsStatus == TtsStatus.unknown) {
      tts.init().then((_) {
        if (mounted) setState(() => _ttsStatus = tts.status);
      }).catchError((_) {});
    }
    // 异步初始化全部兜底：失败不阻塞设置页渲染，更不允许未捕获异常（P0 加固）。
    UpdateService().local().then((v) {
      if (mounted) setState(() => _ver = v.versionName);
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
    p.setCustomLlmUrl(
        _customUrl.text.trim().isEmpty ? null : _customUrl.text.trim());
    p.setCustomLlmModel(
        _customModel.text.trim().isEmpty ? null : _customModel.text.trim());
    p.setCustomLlmKey(
        _customKey.text.trim().isEmpty ? null : _customKey.text.trim());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _testConnection() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    // 记录测试前的配置，失败时回滚，避免把自定义层留在「已启用但不可用」状态（S11）。
    final prevEnabled = p.customLlmEnabled;
    final prevUrl = p.customLlmUrl;
    final prevModel = p.customLlmModel;
    final prevKey = p.customLlmKey;
    final newUrl =
        _customUrl.text.trim().isEmpty ? null : _customUrl.text.trim();
    final newModel =
        _customModel.text.trim().isEmpty ? null : _customModel.text.trim();
    final newKey =
        _customKey.text.trim().isEmpty ? null : _customKey.text.trim();
    // 先落地当前自定义字段，再测试（不弹保存提示，仅验证连通性）。
    await p.setCustomLlmEnabled(true);
    await p.setCustomLlmUrl(newUrl);
    await p.setCustomLlmModel(newModel);
    await p.setCustomLlmKey(newKey);
    setState(() {
      _testing = true;
      _testMsg = null;
      _testOk = null;
    });
    final r = await LlmProvider(p).testCustom();
    if (!r.ok) {
      await p.setCustomLlmEnabled(prevEnabled);
      await p.setCustomLlmUrl(prevUrl);
      await p.setCustomLlmModel(prevModel);
      await p.setCustomLlmKey(prevKey);
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = r.ok;
      _testMsg = r.ok ? '已连接：${r.reason}' : r.reason;
      _customOn = prevEnabled;
    });
  }

  Future<void> _clearCustom() async {
    final p = Provider.of<ProgressService>(context, listen: false);
    await p.clearCustomLlm();
    if (!mounted) return;
    _customUrl.clear();
    _customModel.clear();
    _customKey.clear();
    setState(() {
      _customOn = false;
      _testMsg = null;
      _testOk = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('已清除自定义配置，回落内置服务'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _checkUpdate() async {
    // 统一走更新全流程：弹窗 → 下载 → SHA-256 校验 → 安装 / 权限引导。
    await runUpdateFlow(context);
  }

  Future<void> _toggleNotif(bool v) async {
    final p = Provider.of<ProgressService>(context, listen: false);
    if (v) {
      final ok = await ensureNotificationsWithPreprompt(context);
      if (!ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('通知权限被拒绝，请在系统设置中开启'),
              duration: Duration(seconds: 2)),
        );
      }
      await NotificationService.instance
          .scheduleDaily(_notifHour, _notifMinute);
    } else {
      await NotificationService.instance.cancelDaily();
    }
    await p.setNotifEnabled(v);
    if (!mounted) return;
    setState(() => _notifOn = v);
  }

  /// 到期复习提醒：独立开关，按资产引擎的最早到期重排/取消。
  Future<void> _toggleReviewNotif(bool v) async {
    final p = Provider.of<ProgressService>(context, listen: false);
    if (v) {
      final ok = await ensureNotificationsWithPreprompt(context);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('通知权限被拒绝，请在系统设置中开启'),
              duration: Duration(seconds: 2)),
        );
      }
    }
    await p.setReviewNotifEnabled(v);
    await syncReviewReminder(p);
    if (!mounted) return;
    setState(() => _reviewNotifOn = v);
  }

  Future<void> _pickNotifTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _notifHour, minute: _notifMinute),
    );
    if (picked == null) return;
    if (!mounted) return;
    final p = Provider.of<ProgressService>(context, listen: false);
    await p.setNotifTime(picked.hour, picked.minute);
    if (_notifOn) {
      await NotificationService.instance
          .scheduleDaily(picked.hour, picked.minute);
    }
    if (!mounted) return;
    setState(() {
      _notifHour = picked.hour;
      _notifMinute = picked.minute;
    });
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
        border: Border.all(color: kPrimary.withValues(alpha: 0.4)),
      ),
      // Material(transparency)：DecoratedBox 背景色与 ListTile 之间的 Material 锚点
      // （tileColor 不足以消除「水波纹不可见」断言）。
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: const Icon(Icons.auto_awesome, color: kPrimary),
          title: const Text('AI 助手', style: TextStyle(color: kText)),
          subtitle:
              Text(status, style: TextStyle(color: statusColor, fontSize: 12)),
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
      EngineState.downloading => ('识别引擎：正在下载离线模型…', Colors.white54),
      EngineState.extracting => ('识别引擎：正在解压离线模型…', Colors.white54),
      EngineState.loading => ('识别引擎：准备中…', Colors.white54),
      EngineState.unknown => ('识别引擎：首次使用需下载离线模型', Colors.white54),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
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

  /// 语音朗读状态 + 修复入口：跳过后仍可从这里重新检测/打开引导。
  Widget _ttsRow(BuildContext context) {
    final tts = Provider.of<TtsService>(context, listen: false);
    final (text, color) = tts.hdActive
        ? ('语音朗读：高清发音包（离线）', kUnlocked)
        : switch (_ttsStatus) {
            TtsStatus.ready => ('语音朗读：正常（${tts.language ?? "英文"}）', kUnlocked),
            TtsStatus.noEngine => ('语音朗读：未检测到语音引擎，点此修复', kError),
            TtsStatus.noEnglish => ('语音朗读：缺少英文语音数据，点此修复', kError),
            TtsStatus.error => ('语音朗读：检测异常，点此重试', kError),
            TtsStatus.unknown => ('语音朗读：检测中…', Colors.white54),
          };
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: Icon(Icons.record_voice_over, color: color, size: 20),
          title: const Text('语音朗读（TTS）',
              style: TextStyle(color: kText, fontSize: 14)),
          subtitle: Text(text, style: TextStyle(color: color, fontSize: 12)),
          trailing: _ttsStatus == TtsStatus.ready || tts.hdActive
              ? null
              : const Icon(Icons.arrow_forward_ios,
                  size: 16, color: Colors.white38),
          onTap: () async {
            if (tts.hdActive && tts.status != TtsStatus.ready) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('语音朗读正常：高清发音包（全离线合成）'),
                duration: Duration(seconds: 2),
              ));
              return;
            }
            if (tts.status == TtsStatus.ready) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content:
                    Text('语音朗读正常：${tts.language ?? "英文"}（${tts.activeEngine}）'),
                duration: const Duration(seconds: 2),
              ));
              return;
            }
            final s = tts.status == TtsStatus.unknown
                ? await tts.recheck()
                : tts.status;
            if (!context.mounted) return;
            setState(() => _ttsStatus = s);
            if (s == TtsStatus.ready) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('已检测到可用的英文语音'),
                duration: Duration(seconds: 2),
              ));
              return;
            }
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TtsGuideScreen(
                  status: s,
                  diagnostic: tts.diagnostic,
                  engine: tts.activeEngine,
                  onRecheck: () async {
                    final r = await tts.recheck();
                    if (mounted) setState(() => _ttsStatus = r);
                    return r;
                  },
                  onContinue: () async => Navigator.of(context).pop(),
                  popOnReady: true,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 高清发音包：按需下载（约 60MB），下载完成后自动启用；可随时切回系统引擎。
  Widget _hdVoiceCard(BuildContext context) {
    final hd = Provider.of<HdVoiceService>(context);
    final tts = Provider.of<TtsService>(context, listen: false);
    final p = hd.progress;
    final busy = hd.downloading || hd.deleting;
    final extracting = p?.phase == ModelPhase.extracting;
    final percent = p != null && p.total > 0
        ? (p.received / p.total * 100).clamp(0.0, 100.0)
        : 0.0;
    // 系统只提供英式等非美式英文时，明确导流到真人质感美式高清包。
    final sel = tts.selectedVoice;
    final upsell = sel != null &&
        sel.isEnglish &&
        !sel.isUsEnglish &&
        !tts.hdActive;

    String subtitle;
    Widget? trailing;
    if (hd.ready) {
      subtitle = hd.enabled ? '已启用 · 真人质感美音 · 全离线合成' : '已下载 · 当前使用系统发音';
      trailing = Switch(
        value: hd.enabled,
        activeThumbColor: kPrimary,
        onChanged: busy ? null : (v) => hd.setEnabled(v),
      );
    } else if (hd.downloading) {
      subtitle = extracting ? '正在解压高清发音包…' : '正在下载高清发音包…';
      trailing = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (hd.error != null) {
      subtitle = hd.error!;
      trailing = TextButton(
        onPressed: busy ? null : () => hd.download(retry: true),
        child: const Text('重试', style: TextStyle(color: kPrimary)),
      );
    } else {
      subtitle = '真人质感美音 · 约 60MB · 建议 Wi-Fi（移动网络也可）';
      trailing = TextButton(
        onPressed: busy ? null : () => _confirmHdDownload(hd),
        child: const Text('下载', style: TextStyle(color: kPrimary)),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: upsell ? kPrimary : Colors.white12,
          width: upsell ? 1.2 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.record_voice_over,
                  color: kPrimary, size: 20),
              title: const Text('高清发音包（离线 · 美式）',
                  style: TextStyle(color: kText, fontSize: 14)),
              subtitle: Text(subtitle,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              trailing: trailing,
            ),
            if (upsell)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('当前选用英式系统发音；想要真人质感美音可下载高清美式包。',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onPressed: busy
                            ? null
                            : () async {
                                if (hd.ready) {
                                  await hd.setEnabled(true);
                                } else {
                                  await _confirmHdDownload(hd);
                                }
                              },
                        icon: const Icon(Icons.graphic_eq, size: 18),
                        label: Text(
                            hd.ready ? '启用高清美音包（美式）' : '下载高清美音包（美式）'),
                      ),
                    ),
                  ],
                ),
              ),
            if (hd.downloading)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (p?.message != null) ...[
                      Text(p!.message!,
                          style:
                              const TextStyle(color: kPrimary, fontSize: 12)),
                      const SizedBox(height: 8),
                    ],
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: extracting
                            ? null
                            : (p != null && p.total > 0
                                ? p.received / p.total
                                : 0.0),
                        minHeight: 6,
                        backgroundColor: Colors.white12,
                        color: kPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!extracting)
                      Text(
                        '${percent.toStringAsFixed(1)}%  ·  '
                        '${_fmtHdBytes(p?.received ?? 0)} / ${_fmtHdBytes(p?.total ?? 0)}  ·  '
                        '${_fmtHdSpeed(p?.bytesPerSecond ?? 0)}  ·  剩余 ${_fmtHdEta(p?.remaining)}',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                  ],
                ),
              ),
            if (hd.error != null && !hd.downloading)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 8, 4),
                  child: TextButton(
                    onPressed: busy ? null : () => _confirmHdDelete(hd),
                    child: const Text('删除未完成下载',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                ),
              ),
            if (hd.engineError != null && hd.ready)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(hd.engineError!,
                    style: const TextStyle(color: kError, fontSize: 12)),
              ),
            if (hd.ready)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: busy || _hdPreviewing
                          ? null
                          : () => _previewHdVoice(hd),
                      icon: _hdPreviewing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.volume_up, size: 18),
                      label: Text(_hdPreviewing ? '加载中…' : '试听'),
                      style: TextButton.styleFrom(foregroundColor: kPrimary),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: busy ? null : () => _confirmHdDelete(hd),
                      style:
                          TextButton.styleFrom(foregroundColor: Colors.white54),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmHdDownload(HdVoiceService hd) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('下载高清发音包', style: TextStyle(color: kText)),
        content: const Text(
          '约 60MB，建议在 Wi-Fi 下下载（移动网络也可）。\n'
          '下载完成后自动启用，可随时切回系统发音；删除后需重新下载。',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('下载', style: TextStyle(color: kPrimary)),
          ),
        ],
      ),
    );
    if (ok == true) await hd.download();
  }

  Future<void> _confirmHdDelete(HdVoiceService hd) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('删除高清发音包？', style: TextStyle(color: kText)),
        content: const Text(
          '删除后立即切回系统发音，需要时可重新下载（约 60MB）。',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (ok == true) await hd.delete();
  }

  Future<void> _previewHdVoice(HdVoiceService hd) async {
    final tts = Provider.of<TtsService>(context, listen: false);
    setState(() => _hdPreviewing = true);
    final ok = await tts.speak(HdVoiceService.kAuditionText);
    if (!mounted) return;
    setState(() => _hdPreviewing = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('高清发音暂不可用，请删除后重新下载'),
        duration: Duration(seconds: 3),
      ));
    }
  }

  static String _fmtHdBytes(int b) {
    if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }

  static String _fmtHdSpeed(double bps) {
    if (bps <= 0) return '--';
    if (bps >= 1024 * 1024) {
      return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${(bps / 1024).toStringAsFixed(0)} KB/s';
  }

  static String _fmtHdEta(Duration? d) {
    if (d == null) return '--';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return m > 0 ? '约 $m 分 $s 秒' : '约 $s 秒';
  }

  /// 发音音色：自动优选 / 逐个试听。仅语音朗读就绪时展示。
  Widget _voiceCard(BuildContext context) {
    final tts = Provider.of<TtsService>(context, listen: false);
    final sel = tts.selectedVoice;
    final isAuto = tts.preferredVoiceKey == null;
    final subtitle =
        sel == null ? '系统默认声音（点此选择）' : '${isAuto ? "自动优选 · " : ""}${sel.label}';
    final hdNote = tts.hdActive ? '当前优先高清发音，此处为系统备用音色' : null;
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: const Icon(Icons.graphic_eq, color: kPrimary, size: 20),
          title:
              const Text('发音音色', style: TextStyle(color: kText, fontSize: 14)),
          subtitle: Text(hdNote == null ? subtitle : '$subtitle\n$hdNote',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          trailing: const Icon(Icons.arrow_forward_ios,
              size: 16, color: Colors.white38),
          onTap: _openVoicePicker,
        ),
      ),
    );
  }

  /// 音色分布埋点（指令 H）：只记配置维度，不含任何文本内容。
  void _logVoiceChoice(ProgressService progress, TtsService tts, bool auto) {
    final v = tts.selectedVoice;
    progress.logEvent('voice_selected', {
      'auto': auto,
      'locale': v?.locale ?? '',
      'accent': v?.accentLabel ?? '',
      'quality': v?.quality ?? '',
      'net': v?.networkRequired ?? false,
      'hd': tts.hdActive,
    });
  }

  Future<void> _openVoicePicker() async {
    final tts = Provider.of<TtsService>(context, listen: false);
    final progress = Provider.of<ProgressService>(context, listen: false);
    final voices = await tts.listVoices();
    if (!mounted) return;
    if (voices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('当前语音引擎未提供可选音色，继续使用系统默认声音'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    final picked = await showAppSheet<_VoiceChoice>(
      context: context,
      backgroundColor: kBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('发音音色',
                        style: TextStyle(
                            color: kText,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('点右侧喇叭试听并选用；默认自动优选质量最高的英文声音',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        leading:
                            const Icon(Icons.auto_awesome, color: kPrimary),
                        title: const Text('自动优选（推荐）',
                            style: TextStyle(color: kText)),
                        subtitle: Text(
                          tts.autoVoice == null
                              ? '按质量与引擎优先级自动选择'
                              : '当前：${tts.autoVoice!.label}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                        trailing: tts.preferredVoiceKey == null
                            ? const Icon(Icons.check, color: kPrimary)
                            : null,
                        onTap: () =>
                            Navigator.pop(sheetCtx, const _VoiceChoice(null)),
                      ),
                      const Divider(color: Colors.white12, height: 1),
                      for (final v in voices)
                        ListTile(
                          title: Text(
                            '${v.locale} · ${v.name.split("#").last}',
                            style: const TextStyle(color: kText, fontSize: 14),
                          ),
                          subtitle: Text(v.label,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.volume_up,
                                    color: kPrimary, size: 20),
                                tooltip: '试听',
                                onPressed: () async {
                                  final ok = await tts.auditionVoice(v);
                                  if (!ok) {
                                    if (sheetCtx.mounted) {
                                      ScaffoldMessenger.of(sheetCtx)
                                          .showSnackBar(const SnackBar(
                                        content: Text('该音色暂不可用'),
                                        duration: Duration(seconds: 2),
                                      ));
                                    }
                                    return;
                                  }
                                  await progress.setTtsVoiceKey(v.key);
                                  _logVoiceChoice(progress, tts, false);
                                  if (!sheetCtx.mounted || !mounted) return;
                                  setSheetState(() {});
                                  setState(() => _ttsStatus = tts.status);
                                },
                              ),
                              if (tts.preferredVoiceKey == v.key)
                                const Icon(Icons.check, color: kPrimary)
                              else
                                const SizedBox(width: 24),
                            ],
                          ),
                          onTap: () => Navigator.pop(sheetCtx, _VoiceChoice(v)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final ok = await tts.selectVoice(picked.voice);
    await progress.setTtsVoiceKey(ok ? picked.voice?.key : null);
    _logVoiceChoice(progress, tts, picked.voice == null);
    if (!mounted) return;
    setState(() => _ttsStatus = tts.status);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (picked.voice == null
              ? '已恢复自动优选：${tts.selectedVoice?.label ?? "系统默认"}'
              : '已切换发音音色：${tts.selectedVoice?.label ?? picked.voice!.label}')
          : '该音色暂不可用，已回落到系统默认声音'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 浸泡层预览入口（仅 Debug）：首页常驻入口在 Q-3/Q-4 接入。
  Widget _listeningDebugEntry(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kPrimary.withValues(alpha: 0.35)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: const Icon(Icons.headphones, color: kPrimary),
          title: const Text('磨耳朵（预览）', style: TextStyle(color: kText)),
          subtitle: const Text('浸泡层播放器 · 1.5.4 预览',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ListeningDebugScreen()),
          ),
        ),
      ),
    );
  }

  /// 留存通知卡片：开关 + 提醒时间选择。
  Widget _notificationCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('每日练习提醒', style: TextStyle(color: kText)),
              subtitle: const Text('每天固定时间提醒开口练习（本地通知）',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: _notifOn,
              activeThumbColor: kPrimary,
              onChanged: _toggleNotif,
            ),
            if (_notifOn)
              ListTile(
                leading: const Icon(Icons.schedule, color: kPrimary),
                title: const Text('提醒时间', style: TextStyle(color: kText)),
                trailing: Text(
                  '${_notifHour.toString().padLeft(2, '0')}:${_notifMinute.toString().padLeft(2, '0')}',
                  style: const TextStyle(
                      color: kPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                ),
                onTap: _pickNotifTime,
              ),
            const Divider(height: 1, color: Colors.white12),
            SwitchListTile(
              title: const Text('到期复习提醒', style: TextStyle(color: kText)),
              subtitle: const Text('有词块到复习时间时提醒一次（本地通知）',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: _reviewNotifOn,
              activeThumbColor: kPrimary,
              onChanged: _toggleReviewNotif,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleSound(bool v) async {
    final p = Provider.of<ProgressService>(context, listen: false);
    await p.setSoundOn(v);
    if (mounted) setState(() => _soundOn = v);
  }

  /// B7：音效开关（震动跟随系统，不提供独立开关）。
  Widget _soundCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SwitchListTile(
          title: const Text('音效', style: TextStyle(color: kText)),
          subtitle: const Text('答对提示音（关闭后仅保留视觉反馈）',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          value: _soundOn,
          activeThumbColor: kPrimary,
          onChanged: _toggleSound,
        ),
      ),
    );
  }

  Future<void> _toggleAiNet(bool v) async {
    final p = Provider.of<ProgressService>(context, listen: false);
    await p.setAiNetOn(v);
    if (mounted) setState(() => _aiNetOn = v);
  }

  /// 隐私开关：关闭后「自由造句」不再向云端发送识别文本，改由本机规则引擎判定。
  Widget _aiNetCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SwitchListTile(
          title: const Text('AI 联网点评', style: TextStyle(color: kText)),
          subtitle: Text(
            _aiNetOn
                ? '开启：自由造句会把识别出的句子文本发送到开发者代理生成点评（不含录音与设备信息）'
                : '已关闭：自由造句仅用本机规则判定，不发送任何数据',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          value: _aiNetOn,
          activeThumbColor: kPrimary,
          onChanged: _toggleAiNet,
        ),
      ),
    );
  }

  /// A7：反馈入口（发邮件 / 复制邮箱）。
  Widget _feedbackEntry(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: const Icon(Icons.feedback_outlined, color: kPrimary),
          title: const Text('反馈与建议', style: TextStyle(color: kText)),
          subtitle: const Text('发邮件或复制邮箱',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          trailing: const Icon(Icons.arrow_forward_ios,
              size: 16, color: Colors.white38),
          onTap: () => showFeedbackSheet(context),
        ),
      ),
    );
  }

  /// GPLv3 合规入口：全文许可证 + 书面源码要约随 APK 分发并可见。
  Widget _legalEntry(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          leading: const Icon(Icons.gavel, color: kPrimary),
          title: const Text('开源许可与源码', style: TextStyle(color: kText)),
          subtitle: const Text('eSpeak NG（GPLv3）全文与对应源码获取方式',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          trailing: const Icon(Icons.arrow_forward_ios,
              size: 16, color: Colors.white38),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LegalScreen()),
          ),
        ),
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
            const SizedBox(height: 12),
            _ttsRow(context),
            const SizedBox(height: 12),
            _hdVoiceCard(context),
            if (_ttsStatus == TtsStatus.ready) ...[
              const SizedBox(height: 12),
              _voiceCard(context),
            ],
            if (kDebugMode || _kListeningPreview) ...[
              const SizedBox(height: 12),
              _listeningDebugEntry(context),
            ],
            const SizedBox(height: 16),
            _notificationCard(context),
            const SizedBox(height: 12),
            _soundCard(context),
            const SizedBox(height: 12),
            _feedbackEntry(context),
            const SizedBox(height: 20),

            // —— AI 助手：常驻入口 ——
            _aiCoachEntry(context),
            const SizedBox(height: 12),
            _aiNetCard(context),
            const SizedBox(height: 14),
            _advancedCard(context),
            const SizedBox(height: 12),
            _legalEntry(context),
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
                child:
                    const Text('检查更新', style: TextStyle(color: Colors.white70)),
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
            title:
                const Text('高级', style: TextStyle(color: kText, fontSize: 15)),
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
                activeThumbColor: kPrimary,
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
              const Divider(color: Colors.white12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('保存最近一次录音（排障）',
                    style: TextStyle(color: kText)),
                subtitle: const Text(
                    '默认关；开启后停止录音时复制到应用文档 asr_debug/last.wav',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: RecordingService.keepLastWavForDebug,
                activeThumbColor: kPrimary,
                onChanged: (v) =>
                    setState(() => RecordingService.keepLastWavForDebug = v),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 音色选择结果包装：null voice 表示「自动优选」，与取消弹窗区分。
class _VoiceChoice {
  final TtsVoice? voice;
  const _VoiceChoice(this.voice);
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../services/loaders.dart';
import '../services/vosk_engine.dart';
import '../services/vosk_model.dart';
import '../ui/theme.dart';

/// 模型门（三.3）：确保离线语音模型就绪前，不进入任何界面（新老用户统一拦截）。
/// 首启/升级缺失 → 分块下载（0.5% 节流进度 + 速度 + 剩余时间）→ SHA-256 → 解压 → 放行；
/// 失败可重试（分块失败自动切整包兜底源，由 ModelManager 内部处理）。
class ModelGate extends StatefulWidget {
  final Widget child;
  const ModelGate({super.key, required this.child});

  @override
  State<ModelGate> createState() => _ModelGateState();
}

class _ModelGateState extends State<ModelGate> {
  EngineState _state = EngineState.unknown;
  ModelProgress? _progress;
  String? _error;
  StreamSubscription<ModelProgress>? _sub;

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _ensure({bool retry = false}) async {
    // 首启下载完成率（指令 H 观测口径）：一次尝试 + 一个结果，失败也记。
    // context 必须在任何 await 之前取，避免跨异步间隙使用。
    ProgressService? analytics;
    try {
      analytics = Provider.of<ProgressService>(context, listen: false);
      analytics.logEvent('model_gate_try', {'retry': retry});
    } catch (_) {}
    await _sub?.cancel();
    try {
      final stream = await SpeechEngine.instance.ensureProgressStream();
      _sub = stream.listen((p) {
        if (mounted) setState(() => _progress = p);
      });
    } catch (_) {
      // 进度流订阅失败不阻断初始化。
    }
    if (mounted) setState(() => _state = EngineState.loading);
    SpeechEngine.instance.init().then((ok) {
      analytics?.logEvent('model_gate_result',
          {'ok': ok, 'err': SpeechEngine.instance.lastError});
      if (!mounted) return;
      setState(() {
        _state = ok ? EngineState.ready : EngineState.failed;
        _error = SpeechEngine.instance.lastError;
      });
    });
  }

  Future<void> _retry() async {
    setState(() {
      _state = EngineState.loading;
      _progress = null;
      _error = null;
    });
    // 手动重试必须先清掉全部不完整分块与拼接临时文件，避免坏块继续续传。
    await SpeechEngine.instance.prepareRetry();
    if (!mounted) return;
    await _ensure(retry: true);
  }

  /// 失败页「复制诊断信息」：把各源尝试记录/HTTP 码/字节数/网络类型拷到剪贴板。
  /// 纯本地读取，不上传；由用户自己决定贴给谁。
  Future<void> _copyDiag() async {
    final text = await SpeechEngine.instance.diagText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('诊断信息已复制，可直接粘贴到群里'),
        duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    if (_state == EngineState.ready) return widget.child;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.graphic_eq, color: kPrimary, size: 48),
                const SizedBox(height: 16),
                Text('正在准备离线语音引擎',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: kText)),
                const SizedBox(height: 8),
                Text('首次使用需下载约 39MB 离线模型（仅此一次）',
                    style: TextStyle(fontSize: 13, color: kTextMuted)),
                const SizedBox(height: 28),
                _buildBody(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_state == EngineState.failed) {
      return Column(
        children: [
          Text(_error ?? '模型下载失败',
              textAlign: TextAlign.center,
              style: TextStyle(color: kError, fontSize: 13)),
          const SizedBox(height: 14),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: _retry,
            child: Text('重试', style: TextStyle(color: kOnPrimary)),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: _copyDiag,
            icon: Icon(Icons.copy, size: 15, color: kTextMuted),
            label: Text('复制诊断信息',
                style: TextStyle(color: kTextMuted, fontSize: 12)),
          ),
          Text('反馈时贴给开发者，能直接看出是哪一步失败',
              style: TextStyle(color: kTextFaint, fontSize: 11)),
        ],
      );
    }

    final p = _progress;
    final extracting = _state == EngineState.extracting ||
        (p != null && p.phase == ModelPhase.extracting);
    if (extracting) {
      return Column(
        children: [
          const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(height: 12),
          Text('正在解压模型…', style: TextStyle(color: kTextSecondary)),
        ],
      );
    }

    final total = p?.total ?? 0;
    final received = p?.received ?? 0;
    final percent = total > 0 ? (received / total * 100).clamp(0.0, 100.0) : 0.0;
    return Column(
      children: [
        if (p?.message != null) ...[
          Text(p!.message!,
              textAlign: TextAlign.center,
              style: TextStyle(color: kPrimary, fontSize: 13)),
          const SizedBox(height: 12),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: total > 0 ? received / total : null,
            minHeight: 8,
            backgroundColor: kBorder,
            color: kPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Text('${percent.toStringAsFixed(1)}%  ·  ${_fmtBytes(received)} / ${_fmtBytes(total)}',
            style: TextStyle(color: kTextSecondary, fontSize: 13)),
        const SizedBox(height: 4),
        Text('${_fmtSpeed(p?.bytesPerSecond ?? 0)}  ·  剩余 ${_fmtEta(p?.remaining)}',
            style: TextStyle(color: kTextMuted, fontSize: 12)),
        // ASR-215 P3-2：按返回直接退出 App 会让人以为下载失败（实测进度其实没丢）。
        const SizedBox(height: 10),
        Text('现在离开也没关系：下载会继续，回来接着传。',
            style: TextStyle(color: kTextMuted, fontSize: 12),
            textAlign: TextAlign.center),
        Text('进度可在「设置 → 诊断」里看。',
            style: TextStyle(color: kTextMuted, fontSize: 12),
            textAlign: TextAlign.center),
      ],
    );
  }
}

String _fmtBytes(int b) {
  if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '$b B';
}

String _fmtSpeed(double bps) {
  if (bps <= 0) return '--';
  if (bps >= 1024 * 1024) return '${(bps / 1024 / 1024).toStringAsFixed(1)} MB/s';
  return '${(bps / 1024).toStringAsFixed(0)} KB/s';
}

String _fmtEta(Duration? d) {
  if (d == null) return '--';
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return m > 0 ? '约 $m 分 $s 秒' : '约 $s 秒';
}

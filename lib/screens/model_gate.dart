import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  Future<void> _ensure() async {
    try {
      final stream = await SpeechEngine.instance.ensureProgressStream();
      stream.listen((p) {
        if (mounted) setState(() => _progress = p);
      });
    } catch (_) {
      // 进度流订阅失败不阻断初始化。
    }
    if (mounted) setState(() => _state = EngineState.loading);
    SpeechEngine.instance.init().then((ok) {
      if (!mounted) return;
      setState(() {
        _state = ok ? EngineState.ready : EngineState.failed;
        _error = SpeechEngine.instance.lastError;
      });
    });
  }

  void _retry() {
    setState(() {
      _state = EngineState.unknown;
      _progress = null;
      _error = null;
    });
    _ensure();
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
                const Icon(Icons.graphic_eq, color: kPrimary, size: 48),
                const SizedBox(height: 16),
                const Text('正在准备离线语音引擎',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 8),
                const Text('首次使用需下载约 39MB 离线模型（仅此一次）',
                    style: TextStyle(fontSize: 13, color: Colors.white54)),
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
              style: const TextStyle(color: kError, fontSize: 13)),
          const SizedBox(height: 14),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: _retry,
            child: const Text('重试', style: TextStyle(color: Colors.white)),
          ),
        ],
      );
    }

    final p = _progress;
    final extracting = _state == EngineState.extracting ||
        (p != null && p.phase == ModelPhase.extracting);
    if (extracting) {
      return const Column(
        children: [
          SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(height: 12),
          Text('正在解压模型…', style: TextStyle(color: Colors.white70)),
        ],
      );
    }

    final total = p?.total ?? 0;
    final received = p?.received ?? 0;
    final percent = total > 0 ? (received / total * 100).clamp(0.0, 100.0) : 0.0;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: total > 0 ? received / total : null,
            minHeight: 8,
            backgroundColor: Colors.white12,
            color: kPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Text('${percent.toStringAsFixed(1)}%  ·  ${_fmtBytes(received)} / ${_fmtBytes(total)}',
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 4),
        Text('${_fmtSpeed(p?.bytesPerSecond ?? 0)}  ·  剩余 ${_fmtEta(p?.remaining)}',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
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

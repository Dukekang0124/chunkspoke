import 'package:flutter/material.dart';

import '../services/loaders.dart';
import '../ui/theme.dart';
import '../ui/tts_dialogs.dart';

/// TTS 修复引导页（启动预检命中 noEngine / noEnglish / error 时展示）。
/// 目标：在朗读失败之前解释原因，并给出一键系统设置 / 引擎下载 / 重新检测。
class TtsGuideScreen extends StatefulWidget {
  final TtsStatus status;
  final String diagnostic;
  final String engine;
  final Future<TtsStatus> Function() onRecheck;
  final Future<void> Function() onContinue;

  /// 从设置页以路由方式打开时，检测通过后自动返回。
  final bool popOnReady;

  const TtsGuideScreen({
    super.key,
    required this.status,
    required this.diagnostic,
    required this.engine,
    required this.onRecheck,
    required this.onContinue,
    this.popOnReady = false,
  });

  @override
  State<TtsGuideScreen> createState() => _TtsGuideScreenState();
}

class _TtsGuideScreenState extends State<TtsGuideScreen> {
  late TtsStatus _status = widget.status;
  bool _checking = false;

  bool get _noEngine => _status == TtsStatus.noEngine;
  bool get _isError => _status == TtsStatus.error;

  String get _cardTitle {
    if (_noEngine) return '未检测到 TTS 引擎';
    if (_isError) return '语音服务检测异常';
    return '缺少英文语音数据';
  }

  String get _cardSub {
    if (_noEngine) return '设备上没有任何语音合成引擎';
    if (_isError) return '可打开系统设置检查首选引擎，或稍后重新检测';
    return '当前引擎：$_engineLabel';
  }

  String get _title {
    switch (_status) {
      case TtsStatus.noEngine:
        return '先装一个语音引擎，再开始朗读';
      case TtsStatus.noEnglish:
        return '给语音引擎补上英文语音';
      case TtsStatus.error:
        return '语音服务暂时没有响应';
      case TtsStatus.unknown:
      case TtsStatus.ready:
        return '正在检查语音朗读';
    }
  }

  String get _subtitle {
    switch (_status) {
      case TtsStatus.noEngine:
        return 'ChunkSpoke 用系统 TTS 朗读示范。当前设备没有可用的语音引擎，安装后朗读即可恢复。';
      case TtsStatus.noEnglish:
        return '已检测到语音引擎，但其中没有英文语音数据。补装英文语音包后朗读即可恢复。';
      case TtsStatus.error:
        return '检测系统语音服务时出错。可以打开系统设置检查首选引擎，或稍后重新检测。';
      case TtsStatus.unknown:
      case TtsStatus.ready:
        return '';
    }
  }

  String get _engineLabel {
    if (widget.engine.isEmpty) return '无';
    if (widget.engine.contains('google')) return 'Google 语音合成';
    if (widget.engine.contains('iflytek')) return '讯飞语音引擎';
    if (widget.engine.contains('xiaomi')) return '小米语音引擎';
    if (widget.engine.contains('huawei')) return '华为智慧语音';
    return widget.engine;
  }

  List<(String, String)> get _steps {
    if (_noEngine) {
      return const [
        ('安装一个语音引擎', '点下方「去下载语音引擎」，安装「讯飞语记」或「Google 语音合成」（二选一）。'),
        ('设为系统首选引擎', '安装后点「打开系统语音设置」，把「首选引擎」切换为刚安装的引擎。'),
        ('回到这里重新检测', '点「重新检测」，检测到英文语音后即可正常朗读。'),
      ];
    }
    if (_status == TtsStatus.noEnglish) {
      return const [
        ('打开系统语音设置', '点下方「打开系统语音设置」，进入「首选引擎」当前引擎的设置页。'),
        ('安装英文语音数据', '选择「安装语音数据」或「下载语音」，勾选 English / 英语后等待下载完成。'),
        ('回到这里重新检测', '点「重新检测」，状态变为正常后朗读即恢复。'),
      ];
    }
    return const [
      ('检查首选引擎', '点下方「打开系统语音设置」，确认「首选引擎」已选择且未被停用。'),
      ('必要时重装引擎', '若引擎被卸载或停用，安装「讯飞语记」或「Google 语音合成」后重试。'),
      ('回到这里重新检测', '点「重新检测」，仍失败可先继续使用，稍后从设置页再次检测。'),
    ];
  }

  Future<void> _recheck() async {
    setState(() => _checking = true);
    final s = await widget.onRecheck();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _status = s;
    });
    if (s == TtsStatus.ready) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已检测到可用的英文语音'),
        duration: Duration(seconds: 2),
      ));
      if (widget.popOnReady && mounted) Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('仍未检测到可用的英文语音，请按步骤检查后重试'),
        duration: Duration(seconds: 3),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 4),
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: Color(0x1AFFB84D),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.record_voice_over_rounded,
                      color: kPrimary, size: 32),
                ),
              ),
              const SizedBox(height: 12),
              Text(_title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(_subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 13, height: 1.45)),
              const SizedBox(height: 14),

              // 检测结果卡：让用户知道「app 检查到了什么」。
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _noEngine
                          ? Icons.apps_rounded
                          : _isError
                              ? Icons.error_outline_rounded
                              : Icons.translate_rounded,
                      color: kPrimary,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _cardTitle,
                            style: const TextStyle(
                                color: kText,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _cardSub,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '诊断码：${widget.diagnostic}',
                            style: const TextStyle(
                                color: Colors.white30, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text('按下面步骤修复',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              for (var i = 0; i < _steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _StepRow(
                    index: i + 1,
                    title: _steps[i].$1,
                    body: _steps[i].$2,
                  ),
                ),
              const SizedBox(height: 6),

              // 主操作按状态分流：无引擎时下载优先，有引擎时系统设置优先。
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _noEngine
                          ? () => showTtsStoreSheet(context)
                          : () => openTtsSettings(context),
                      icon: Icon(
                        _noEngine
                            ? Icons.download_rounded
                            : Icons.settings_outlined,
                        color: Colors.black87,
                        size: 20,
                      ),
                      label: Text(
                        _noEngine ? '去下载语音引擎' : '打开系统语音设置',
                        style: const TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _noEngine
                          ? () => openTtsSettings(context)
                          : () => showTtsStoreSheet(context),
                      icon: Icon(
                        _noEngine
                            ? Icons.settings_outlined
                            : Icons.download_rounded,
                        color: kPrimary,
                        size: 19,
                      ),
                      label: Text(
                        _noEngine ? '打开系统语音设置' : '安装其他语音引擎',
                        style: const TextStyle(color: kPrimary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _checking ? null : _recheck,
                      child: _checking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: kPrimary))
                          : const Text('重新检测',
                              style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '语音问题不影响听辨、跟读和录音判定，修复后自动恢复。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () async {
                  await widget.onContinue();
                },
                child: const Text('先继续使用',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final int index;
  final String title;
  final String body;
  const _StepRow(
      {required this.index, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
                color: Color(0x1AFFB84D), shape: BoxShape.circle),
            child: Text('$index',
                style: const TextStyle(
                    color: kPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: kText,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(body,
                    style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
